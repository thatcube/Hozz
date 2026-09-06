#!/usr/bin/env python3
"""A complete Hozz receiver in one file, with no dependencies.

Accepts batches over HTTP, or watches a folder that Hozz writes into, and keeps
a SQLite database you can query with anything.

    # Listen for a REST destination
    python3 hozz_receiver.py serve --port 8765 --token my-secret

    # Or watch a synced folder (iCloud Drive, Dropbox, OneDrive, ...)
    python3 hozz_receiver.py watch ~/Dropbox/Health

    # Then ask it things
    python3 hozz_receiver.py stats

Why this is safe to retry against: canonical IDs and monotonic versions make
replays update the same row without replacing newer state, and every batch
carries an Idempotency-Key. Deletions remain as tombstones, so an older replay
cannot resurrect something removed from Health.
"""

import argparse
import hashlib
import hmac
import io
import ipaddress
import json
import math
import os
import re
import sqlite3
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zipfile
from contextlib import contextmanager
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from pathlib import Path

SOURCE_STORE = "apple.healthkit"
RUN_KINDS = {
    "manifest", "completion", "typeSummary", "typeError", "typeCoverage",
    "resume", "hozzConnectionTest",
}
PARENTED_SERIES_KINDS = {
    "electrocardiogramEnd",
    "electrocardiogramVoltages",
    "quantitySeriesEnd",
    "quantitySeriesReadings",
    "workoutRouteEnd",
    "workoutRouteLocations",
}
SYNTHETIC_IDENTITY_KINDS = PARENTED_SERIES_KINDS | {
    "sampleEncodingError",
    "clinicalRecord",
}
SERIES_END_KINDS = {
    "electrocardiogramEnd",
    "quantitySeriesEnd",
    "workoutRouteEnd",
}
MAX_ZIP_ENTRIES = 1_024
MAX_ZIP_DIRECTORY_BYTES = 16 * 1_024 * 1_024
MAX_ZIP64_END_RECORD_BYTES = 1 * 1_024 * 1_024
MAX_INFLATED_BYTES = 64 * 1_024 * 1_024 * 1_024
MAX_RECORD_LINES = 50_000_000
MAX_RECORD_BYTES = 16 * 1_024 * 1_024
MAX_PENDING_BATCH_BYTES = 64 * 1_024 * 1_024
MAX_SNAPSHOT_MEMORY_BYTES = 256 * 1_024
MAX_NETWORK_BODY_BYTES = 8 * 1_024 * 1_024
MAX_ENVELOPE_BYTES = 1 * 1_024 * 1_024
MAX_RUN_OCCURRENCE_KEYS = 100_000
MAX_MANIFEST_BYTES = 256 * 1_024
DEFAULT_TLS_TIMEOUT = 10.0
DEFAULT_HEADER_TIMEOUT = 10.0
DEFAULT_BODY_TIMEOUT = 30.0
DEFAULT_MAX_CONNECTIONS = 16
MAX_ENTRY_COMPRESSION_RATIO = 200
MAX_GLOBAL_COMPRESSION_RATIO = 100
ENTRY_RATIO_SLACK_BYTES = 8 * 1_024 * 1_024
GLOBAL_RATIO_SLACK_BYTES = 32 * 1_024 * 1_024
RFC3339 = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"
    r"(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"
)
COMPATIBLE_TIMESTAMP = re.compile(
    r"^(?P<date>\d{4}-\d{2}-\d{2})[T ]"
    r"(?P<time>\d{2}:\d{2}:\d{2})"
    r"(?P<fraction>\.\d+)? ?"
    r"(?P<zone>Z|[+-]\d{2}:?\d{2})$"
)
SOURCE_NAMESPACE = re.compile(r"^[A-Za-z0-9._-]+$")
SUPPORTED_ZIP_METHODS = {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}
ZIP_ENCRYPTION_FLAGS = (1 << 0) | (1 << 6) | (1 << 13)

SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
    canonical_id TEXT PRIMARY KEY,
    source_id    TEXT NOT NULL,
    parent_canonical_id TEXT,
    resolution_canonical_id TEXT,
    record_version INTEGER NOT NULL,
    tombstone    INTEGER NOT NULL DEFAULT 0,
    type        TEXT NOT NULL,
    kind        TEXT,
    start_date  TEXT,
    end_date    TEXT,
    value       REAL,
    unit        TEXT,
    minimum     REAL,
    maximum     REAL,
    text_value  TEXT,
    duration_seconds REAL,
    source      TEXT,
    raw         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS samples_type_start ON samples(type, start_date);
CREATE INDEX IF NOT EXISTS samples_parent ON samples(parent_canonical_id);

CREATE TABLE IF NOT EXISTS batches (
    key         TEXT PRIMARY KEY,
    received_at REAL NOT NULL,
    records     INTEGER NOT NULL,
    deletions   INTEGER NOT NULL DEFAULT -1
);

CREATE TABLE IF NOT EXISTS ingested_files (
    name        TEXT PRIMARY KEY,
    ingested_at REAL NOT NULL,
    device      INTEGER,
    inode       INTEGER,
    size        INTEGER,
    mtime_ns    INTEGER,
    ctime_ns    INTEGER,
    digest      TEXT
);

CREATE TABLE IF NOT EXISTS archive_run_records (
    fingerprint TEXT NOT NULL,
    occurrence INTEGER NOT NULL,
    kind        TEXT NOT NULL,
    raw         TEXT NOT NULL,
    PRIMARY KEY (fingerprint, occurrence)
);
CREATE TABLE IF NOT EXISTS compatible_alias_retirement (
    type        TEXT NOT NULL,
    start_instant TEXT NOT NULL,
    end_instant TEXT,
    value       REAL,
    unit        TEXT,
    source      TEXT,
    kind        TEXT,
    stable_id   TEXT NOT NULL,
    PRIMARY KEY (type, start_instant, stable_id)
);
CREATE INDEX IF NOT EXISTS compatible_alias_retirement_stable
    ON compatible_alias_retirement (stable_id);
CREATE TABLE IF NOT EXISTS compatible_unresolved_deletion (
    stable_id   TEXT PRIMARY KEY,
    type        TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS compatible_resolved_deletion (
    stable_id   TEXT PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS compatible_alias_identity (
    stable_id   TEXT NOT NULL,
    legacy_id   TEXT NOT NULL,
    PRIMARY KEY (stable_id, legacy_id)
);
CREATE INDEX IF NOT EXISTS compatible_alias_identity_legacy
    ON compatible_alias_identity (legacy_id);
CREATE TABLE IF NOT EXISTS receiver_migrations (
    version     INTEGER PRIMARY KEY,
    applied_at  REAL NOT NULL
);
"""

DATA_MIGRATION_ENCODING_RECONCILIATION = 1
DATA_MIGRATION_COMPATIBLE_ALIAS_BACKFILL = 2
DATA_MIGRATION_COMPATIBLE_IDENTITY_SAFETY = 3
DURABLE_RECEIVER_TABLES = (
    "samples",
    "batches",
    "ingested_files",
    "archive_run_records",
    "compatible_alias_retirement",
    "compatible_unresolved_deletion",
    "compatible_resolved_deletion",
    "compatible_alias_identity",
    "receiver_migrations",
)
DURABLE_MUTATION_TRACKER = "receiver_durable_mutation_tracker"


def connect(path):
    db = sqlite3.connect(path, check_same_thread=False)
    try:
        db.execute("BEGIN IMMEDIATE")
        columns = {
            row[1] for row in db.execute("PRAGMA table_info(samples)").fetchall()
        }
        legacy_exists = db.execute(
            "SELECT 1 FROM sqlite_master "
            "WHERE type = 'table' AND name = 'samples_legacy'"
        ).fetchone() is not None
        needs_migration = columns and "canonical_id" not in columns
        if needs_migration or legacy_exists:
            if needs_migration:
                if legacy_exists:
                    raise RuntimeError(
                        "both legacy receiver tables exist; migration is ambiguous"
                    )
                db.execute("ALTER TABLE samples RENAME TO samples_legacy")
            create_schema(db)
            migrate_legacy_rows(db)
            db.execute("DROP TABLE samples_legacy")
        else:
            create_schema(db)
        ensure_current_columns(db)
        alias_schema_rebuilt = ensure_compatible_alias_retirement_schema(db)
        if alias_schema_rebuilt:
            db.execute(
                "DELETE FROM receiver_migrations WHERE version IN (?, ?)",
                (
                    DATA_MIGRATION_COMPATIBLE_ALIAS_BACKFILL,
                    DATA_MIGRATION_COMPATIBLE_IDENTITY_SAFETY,
                ),
            )
        run_data_migrations(db)
        db.commit()
        return db
    except Exception:
        db.rollback()
        db.close()
        raise


def create_schema(db):
    for statement in SCHEMA.split(";"):
        if statement.strip():
            db.execute(statement)


def ensure_compatible_alias_retirement_schema(db):
    columns = db.execute(
        "PRAGMA table_info(compatible_alias_retirement)"
    ).fetchall()
    primary_key = [
        row[1] for row in sorted(columns, key=lambda row: row[5]) if row[5]
    ]
    column_names = {row[1] for row in columns}
    expected_columns = {
        "type", "start_instant", "end_instant", "value",
        "unit", "source", "kind", "stable_id",
    }
    if (
        primary_key == ["type", "start_instant", "stable_id"]
        and expected_columns.issubset(column_names)
    ):
        db.execute(
            """
            CREATE INDEX IF NOT EXISTS compatible_alias_retirement_signature
            ON compatible_alias_retirement
               (type, start_instant, end_instant, value, unit, source, kind)
            """
        )
        return False
    db.execute(
        """
        DELETE FROM compatible_resolved_deletion
        WHERE stable_id IN (
            SELECT canonical_id FROM samples
            WHERE tombstone = 1
              AND canonical_id LIKE 'healthAutoExport:%'
        )
        """
    )
    db.execute(
        "ALTER TABLE compatible_alias_retirement "
        "RENAME TO compatible_alias_retirement_old"
    )
    db.execute(
        """
        INSERT OR REPLACE INTO compatible_unresolved_deletion
            (stable_id, type)
        SELECT old.stable_id, old.type
        FROM compatible_alias_retirement_old AS old
        JOIN samples AS tombstone
          ON tombstone.canonical_id = old.stable_id
         AND tombstone.tombstone = 1
        """
    )
    # Mappings made against millisecond timestamps cannot prove which
    # submillisecond record they identified.
    db.execute("DELETE FROM compatible_alias_identity")
    db.execute(
        """
        CREATE TABLE compatible_alias_retirement (
            type        TEXT NOT NULL,
            start_instant TEXT NOT NULL,
            end_instant TEXT,
            value       REAL,
            unit        TEXT,
            source      TEXT,
            kind        TEXT,
            stable_id   TEXT NOT NULL,
            PRIMARY KEY (type, start_instant, stable_id)
        )
        """
    )
    db.execute("DROP TABLE compatible_alias_retirement_old")
    db.execute(
        """
        CREATE INDEX IF NOT EXISTS compatible_alias_retirement_stable
        ON compatible_alias_retirement (stable_id)
        """
    )
    db.execute(
        """
        CREATE INDEX IF NOT EXISTS compatible_alias_retirement_signature
        ON compatible_alias_retirement
           (type, start_instant, end_instant, value, unit, source, kind)
        """
    )
    return True


def run_data_migrations(db):
    migrations = (
        (
            DATA_MIGRATION_ENCODING_RECONCILIATION,
            migrate_encoding_reconciliation,
        ),
        (
            DATA_MIGRATION_COMPATIBLE_ALIAS_BACKFILL,
            migrate_compatible_alias_state,
        ),
        (
            DATA_MIGRATION_COMPATIBLE_IDENTITY_SAFETY,
            migrate_compatible_identity_safety,
        ),
    )
    applied = {
        row[0] for row in db.execute(
            "SELECT version FROM receiver_migrations"
        )
    }
    for version, migration in migrations:
        if version in applied:
            continue
        migration(db)
        db.execute(
            """
            INSERT INTO receiver_migrations (version, applied_at)
            VALUES (?, ?)
            """,
            (version, time.time()),
        )


def migrate_encoding_reconciliation(db):
    restore_continuation_errors(db)
    reconcile_parent_tombstones(db)
    reconcile_encoding_errors(db)


def migrate_compatible_alias_state(db):
    backfill_compatible_alias_signatures(db)
    backfill_compatible_deletion_state(db)


def migrate_compatible_identity_safety(db):
    db.execute(
        """
        DELETE FROM compatible_unresolved_deletion
        WHERE stable_id IN (
            SELECT stable_id FROM compatible_resolved_deletion
        )
        """
    )
    db.execute(
        """
        INSERT OR REPLACE INTO compatible_unresolved_deletion
            (stable_id, type)
        SELECT tombstone.canonical_id, tombstone.type
        FROM samples AS tombstone
        WHERE tombstone.tombstone = 1
          AND tombstone.canonical_id LIKE 'healthAutoExport:%'
          AND NOT EXISTS (
              SELECT 1 FROM compatible_resolved_deletion AS resolved
              WHERE resolved.stable_id = tombstone.canonical_id
          )
        """
    )
    db.execute(
        """
        DELETE FROM compatible_alias_identity
        WHERE legacy_id IN (
            SELECT legacy_id
            FROM compatible_alias_identity
            GROUP BY legacy_id
            HAVING COUNT(*) > 1
        )
        """
    )
    db.execute("DROP INDEX IF EXISTS compatible_alias_identity_legacy")
    db.execute(
        """
        CREATE UNIQUE INDEX compatible_alias_identity_legacy
        ON compatible_alias_identity (legacy_id)
        """
    )


def backfill_compatible_alias_signatures(db):
    rows = db.execute(
        """
        SELECT canonical_id, type, kind, start_date, end_date,
               value, unit, source
        FROM samples
        WHERE tombstone = 0
          AND canonical_id LIKE 'healthAutoExport:%'
          AND start_date IS NOT NULL
        """
    )
    for (
        stable_id,
        record_type,
        kind,
        start_date,
        end_date,
        value,
        unit,
        source,
    ) in rows:
        try:
            start_instant = compatible_normalized_timestamp(start_date)
            end_instant = compatible_normalized_timestamp(
                end_date if isinstance(end_date, str) else start_date
            )
        except PartialBatch:
            continue
        db.execute(
            """
            INSERT OR IGNORE INTO compatible_alias_retirement
                (type, start_instant, end_instant, value, unit,
                 source, kind, stable_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                record_type, start_instant, end_instant, value,
                unit, source, kind, stable_id,
            ),
        )
        db.execute(
            """
            INSERT OR IGNORE INTO compatible_resolved_deletion (stable_id)
            VALUES (?)
            """,
            (stable_id,),
        )


def backfill_compatible_deletion_state(db):
    rows = db.execute(
        """
        SELECT canonical_id, raw FROM samples
        WHERE tombstone = 1
          AND canonical_id LIKE 'healthAutoExport:%'
        """
    )
    for canonical_id, raw in rows:
        try:
            record = parse_json(raw)
        except (TypeError, ValueError):
            continue
        compatibility = record.get("compatibilityRaw")
        if not isinstance(compatibility, dict):
            continue
        name = compatibility.get("name")
        date = compatibility.get("date")
        if not isinstance(name, str) or not name:
            continue
        if isinstance(date, str) and date:
            resolved = db.execute(
                """
                SELECT 1 FROM compatible_resolved_deletion
                WHERE stable_id = ?
                """,
                (canonical_id,),
            ).fetchone()
            if not resolved:
                db.execute(
                    """
                    INSERT OR REPLACE INTO compatible_unresolved_deletion
                        (stable_id, type)
                    VALUES (?, ?)
                    """,
                    (canonical_id, name),
                )
            continue
        resolved = db.execute(
            """
            SELECT 1 FROM compatible_resolved_deletion
            WHERE stable_id = ?
            """,
            (canonical_id,),
        ).fetchone()
        if not resolved:
            db.execute(
                """
                INSERT OR REPLACE INTO compatible_unresolved_deletion
                    (stable_id, type)
                VALUES (?, ?)
                """,
                (canonical_id, name),
            )


def ensure_current_columns(db):
    columns = {
        row[1] for row in db.execute("PRAGMA table_info(samples)")
    }
    if "resolution_canonical_id" not in columns:
        db.execute(
            "ALTER TABLE samples ADD COLUMN resolution_canonical_id TEXT"
        )
    for name, declaration in (
        ("minimum", "REAL"),
        ("maximum", "REAL"),
        ("text_value", "TEXT"),
        ("duration_seconds", "REAL"),
    ):
        if name not in columns:
            db.execute(f"ALTER TABLE samples ADD COLUMN {name} {declaration}")
    batch_columns = {
        row[1] for row in db.execute("PRAGMA table_info(batches)")
    }
    if "deletions" not in batch_columns:
        db.execute(
            "ALTER TABLE batches ADD COLUMN deletions INTEGER NOT NULL DEFAULT -1"
        )
    file_columns = {
        row[1] for row in db.execute("PRAGMA table_info(ingested_files)")
    }
    for name in ("device", "inode", "size", "mtime_ns", "ctime_ns"):
        if name not in file_columns:
            db.execute(f"ALTER TABLE ingested_files ADD COLUMN {name} INTEGER")
    if "digest" not in file_columns:
        db.execute("ALTER TABLE ingested_files ADD COLUMN digest TEXT")
    db.execute(
        """
        CREATE INDEX IF NOT EXISTS samples_parent_kind
        ON samples(parent_canonical_id, kind, tombstone)
        """
    )
    db.execute(
        """
        CREATE INDEX IF NOT EXISTS samples_resolution_kind
        ON samples(resolution_canonical_id, kind, tombstone)
        """
    )
    db.execute(
        """
        CREATE INDEX IF NOT EXISTS samples_kind_tombstone
        ON samples(kind, tombstone)
        """
    )


def migrate_legacy_rows(db):
    rows = db.execute(
        """
        SELECT id, type, kind, start_date, end_date, value, unit, source, raw
        FROM samples_legacy
        """
    )
    for (
        source_id, record_type, kind, start_date, end_date, value, unit,
        source, raw,
    ) in rows:
        try:
            record = parse_json(raw)
        except (json.JSONDecodeError, TypeError, ValueError):
            record = {}
        if not isinstance(record, dict):
            record = {}
        identity = record_identity(record, validate_binding=False)
        if identity is None:
            canonical_id = legacy_canonical_id(source_id, raw)
            migrated_source_id = source_id
            parent_id = None
            version = 1
        else:
            canonical_id, migrated_source_id, parent_id, version = identity
        migrated_kind = record.get("kind") or kind
        tombstone = (
            migrated_kind == "deletion" or record.get("deleted") is True
        )
        quantity = record.get("quantity")
        if not isinstance(quantity, dict):
            quantity = {}
        source_object = record.get("source")
        if not isinstance(source_object, dict):
            source_object = {}
        db.execute(
            """
            INSERT OR IGNORE INTO samples
                (canonical_id, source_id, parent_canonical_id,
                 resolution_canonical_id, record_version,
                 tombstone, type, kind, start_date, end_date, value, unit,
                 minimum, maximum, text_value, duration_seconds, source, raw)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL,
                    NULL, ?, ?)
            """,
            (
                canonical_id,
                migrated_source_id,
                parent_id,
                nonempty_text(record.get("resolutionCanonicalId")),
                version,
                1 if tombstone else 0,
                record.get("type") or record_type,
                migrated_kind,
                record.get("startDate") or start_date,
                record.get("endDate") or end_date,
                quantity.get("value", record.get("value", value)),
                quantity.get("unit", unit),
                source_object.get("name", source),
                raw,
            ),
        )


def parse_json(value):
    def reject_constant(constant):
        raise ValueError(f"{constant} is not valid JSON")

    return json.loads(value, parse_constant=reject_constant)


def legacy_canonical_id(source_id, raw):
    try:
        record = parse_json(raw)
    except (ValueError, TypeError):
        record = {}
    if isinstance(record, dict):
        canonical_id = record.get("canonicalId")
        if isinstance(canonical_id, str) and canonical_id:
            return canonical_id
        source_record = record.get("sourceRecord")
        if not isinstance(source_record, dict):
            source_record = {}
        source_store = source_record.get("store") or SOURCE_STORE
        record_id = record.get("id") or source_id
        return f"{source_store}:{record_id}"
    return f"{SOURCE_STORE}:{source_id}"


class PartialBatch(Exception):
    """Raised when a batch cannot be stored in full.

    Acknowledging a partial batch is the one thing a receiver must never do:
    Hozz would advance its cursor past records that were dropped, and they
    would never be sent again.
    """


class TransientFileError(OSError):
    """A filesystem condition that may clear without changing the file."""


def encoding_failure_id(source_id, type_identifier):
    try:
        source_bytes = uuid.UUID(source_id).bytes
    except (ValueError, AttributeError):
        digest = hashlib.sha256(
            f"{type_identifier}\0{source_id}".encode()
        ).hexdigest()
        return f"encoding-error:{digest}"
    digest = bytearray(hashlib.sha256(
        b"HozzEncodingFailure\0" + type_identifier.encode() + source_bytes
    ).digest()[:16])
    digest[6] = (digest[6] & 0x0F) | 0x50
    digest[8] = (digest[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(digest)))


def validate_synthetic_identity(
    record,
    kind,
    top_level_id,
    source_id,
    type_identifier,
):
    if kind not in SYNTHETIC_IDENTITY_KINDS:
        return
    try:
        canonical_source_id = str(uuid.UUID(source_id))
    except (ValueError, AttributeError) as error:
        raise PartialBatch(
            "synthetic identity requires a UUID source id"
        ) from error
    if source_id != canonical_source_id:
        raise PartialBatch(
            "synthetic identity requires canonical lowercase UUID text"
        )
    if kind == "sampleEncodingError":
        expected = encoding_failure_id(source_id, type_identifier)
    elif kind in SERIES_END_KINDS:
        expected = series_end_id(source_id, type_identifier)
    elif kind in {
        "electrocardiogramVoltages",
        "quantitySeriesReadings",
        "workoutRouteLocations",
    }:
        sequence = record.get("sequence")
        if (
            isinstance(sequence, bool)
            or not isinstance(sequence, int)
            or sequence < 0
        ):
            raise PartialBatch("series page has an invalid sequence")
        key = {
            "electrocardiogramVoltages": "voltages",
            "quantitySeriesReadings": "readings",
            "workoutRouteLocations": "locations",
        }[kind]
        expected = series_record_id(
            source_id,
            type_identifier,
            f"{key}-{sequence}",
        )
    elif kind == "clinicalRecord":
        expected = clinical_record_id(record, source_id)
    else:
        return
    if top_level_id != expected:
        raise PartialBatch(
            "synthetic record id does not match its deterministic derivation"
        )


def clinical_record_id(record, source_id):
    if record.get("identityIsStable") is not True:
        return source_id
    source = record.get("source")
    fhir = record.get("fhir")
    if not isinstance(source, dict) or not isinstance(fhir, dict):
        raise PartialBatch("stable clinical identity is missing source or FHIR facts")
    source_bundle = require_text(source, "bundleIdentifier", "clinical record")
    resource_type = require_text(fhir, "resourceType", "clinical record")
    identifier = require_text(fhir, "identifier", "clinical record")
    digest = bytearray(
        hashlib.sha256(
            b"HKClinicalRecord"
            + source_bundle.encode()
            + b"\0"
            + resource_type.encode()
            + b"\0"
            + identifier.encode()
        ).digest()[:16]
    )
    digest[6] = (digest[6] & 0x0F) | 0x50
    digest[8] = (digest[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(digest)))


def record_identity(record, validate_binding=True):
    kind = record.get("kind")
    source_record = record.get("sourceRecord")
    if not isinstance(source_record, dict):
        source_record = {}
    source_id = (
        nonempty_text(source_record.get("id"))
        or nonempty_text(record.get("sample"))
        or nonempty_text(record.get("healthKitUUID"))
        or nonempty_text(record.get("id"))
    )
    if not source_id and kind == "characteristics":
        source_id = "characteristics"
    if not source_id:
        return None
    source_store = nonempty_text(source_record.get("store")) or SOURCE_STORE
    if validate_binding and SOURCE_NAMESPACE.fullmatch(source_store) is None:
        raise PartialBatch("sourceRecord.store is not a valid namespace")
    top_level_id = nonempty_text(record.get("id"))
    if (
        validate_binding
        and kind in SYNTHETIC_IDENTITY_KINDS
        and top_level_id is None
    ):
        raise PartialBatch("synthetic canonical record has no top-level id")
    if validate_binding and top_level_id is not None:
        validate_synthetic_identity(
            record,
            kind,
            top_level_id,
            source_id,
            nonempty_text(record.get("type")) or "",
        )
    canonical_id = nonempty_text(record.get("canonicalId"))
    if not canonical_id:
        record_id = nonempty_text(record.get("id")) or source_id
        if kind == "sampleEncodingError":
            record_id = encoding_failure_id(
                source_id,
                nonempty_text(record.get("type")) or "",
            )
        canonical_id = f"{source_store}:{record_id}"
    elif validate_binding:
        top_level_id = nonempty_text(record.get("id"))
        if top_level_id is None:
            raise PartialBatch("a canonical record has no top-level id")
        expected = canonical_id_for(source_store, top_level_id)
        if canonical_id != expected:
            raise PartialBatch(
                f"canonicalId {canonical_id} does not match {expected}"
            )
    parent_id = nonempty_text(record.get("parentCanonicalId"))
    if (
        validate_binding
        and kind not in SYNTHETIC_IDENTITY_KINDS
        and top_level_id is not None
        and top_level_id != source_id
    ):
        raise PartialBatch("top-level id does not match sourceRecord.id")
    if not parent_id and kind == "sampleEncodingError":
        parent_id = f"{source_store}:{source_id}"
    if not parent_id and kind in PARENTED_SERIES_KINDS:
        parent_id = canonical_id_for(source_store, source_id)
    sample_id = nonempty_text(record.get("sample"))
    if (
        validate_binding
        and kind in PARENTED_SERIES_KINDS
        and sample_id is not None
        and sample_id != source_id
    ):
        raise PartialBatch("sample does not match sourceRecord.id")
    if (
        validate_binding
        and kind in PARENTED_SERIES_KINDS
        and not series_kind_matches_type(
            kind,
            nonempty_text(record.get("type")) or "",
        )
    ):
        raise PartialBatch("series kind does not match source type")
    if (
        validate_binding
        and parent_id is not None
        and (kind in PARENTED_SERIES_KINDS or kind == "sampleEncodingError")
        and parent_id != canonical_id_for(source_store, source_id)
    ):
        raise PartialBatch("parentCanonicalId does not match source record")
    resolution_id = nonempty_text(record.get("resolutionCanonicalId"))
    if (
        validate_binding
        and resolution_id is not None
        and resolution_id != canonical_id_for(
            source_store,
            series_end_id(source_id, nonempty_text(record.get("type")) or ""),
        )
    ):
        raise PartialBatch(
            "resolutionCanonicalId is not the deterministic series end marker"
        )
    version = record.get("recordVersion")
    if not isinstance(version, int) or isinstance(version, bool):
        if kind == "deletion" or record.get("deleted") is True:
            version = 2
        elif kind == "characteristics":
            version = max(epoch_milliseconds(record.get("readAt")), 1)
        else:
            version = 1
    return canonical_id, source_id, parent_id, version


def nonempty_text(value):
    return value if isinstance(value, str) and value else None


def epoch_milliseconds(value):
    if not isinstance(value, str):
        return 0
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return 0
    if parsed.tzinfo is None:
        return 0
    return int(parsed.timestamp() * 1_000)


def series_end_id(source_id, type_identifier):
    return series_record_id(source_id, type_identifier, "end")


def series_record_id(source_id, type_identifier, suffix):
    try:
        source_bytes = uuid.UUID(source_id).bytes
    except (ValueError, AttributeError) as error:
        raise PartialBatch(
            "a series completion identity requires a UUID source id"
        ) from error
    digest = bytearray(
        hashlib.sha256(
            type_identifier.encode() + source_bytes + suffix.encode()
        ).digest()[:16]
    )
    digest[6] = (digest[6] & 0x0F) | 0x50
    digest[8] = (digest[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(digest)))


def series_end_kind(type_identifier):
    if type_identifier == "HKWorkoutRouteTypeIdentifier":
        return "workoutRouteEnd"
    if type_identifier == "HKDataTypeIdentifierElectrocardiogram":
        return "electrocardiogramEnd"
    return "quantitySeriesEnd"


def series_kind_matches_type(kind, type_identifier):
    if type_identifier == "HKWorkoutRouteTypeIdentifier":
        return kind in {"workoutRouteEnd", "workoutRouteLocations"}
    if type_identifier == "HKDataTypeIdentifierElectrocardiogram":
        return kind in {"electrocardiogramEnd", "electrocardiogramVoltages"}
    return kind in {"quantitySeriesEnd", "quantitySeriesReadings"}


def validate_strict_v1(record, line_number):
    prefix = f"line {line_number}"
    kind = require_text(record, "kind", prefix)
    version = record.get("schemaVersion")
    if isinstance(version, bool) or version != 1:
        raise PartialBatch(f"{prefix} has an unsupported schemaVersion")
    if kind in RUN_KINDS:
        validate_run_record(record, kind, prefix)
        return

    canonical_id = require_text(record, "canonicalId", prefix)
    require_text(record, "canonicalType", prefix)
    record_version = record.get("recordVersion")
    if (
        isinstance(record_version, bool)
        or not isinstance(record_version, int)
        or record_version < 1
    ):
        raise PartialBatch(f"{prefix} has an invalid recordVersion")
    source_type = require_text(record, "type", prefix)
    top_level_id = require_text(record, "id", prefix)
    if "parentCanonicalId" in record:
        require_text(record, "parentCanonicalId", prefix)
    if "resolutionCanonicalId" in record:
        require_text(record, "resolutionCanonicalId", prefix)
    if "deleted" in record and not isinstance(record["deleted"], bool):
        raise PartialBatch(f"{prefix} has an invalid deleted value")
    for field in ("source", "device", "metadata"):
        if field in record and not isinstance(record[field], dict):
            raise PartialBatch(f"{prefix} has an invalid {field} object")
    source_record = record.get("sourceRecord")
    if not isinstance(source_record, dict):
        raise PartialBatch(f"{prefix} has no sourceRecord")
    source_store = require_text(source_record, "store", prefix)
    if SOURCE_NAMESPACE.fullmatch(source_store) is None:
        raise PartialBatch(f"{prefix} has an invalid source namespace")
    source_id = require_text(source_record, "id", prefix)
    validate_synthetic_identity(
        record,
        kind,
        top_level_id,
        source_id,
        source_type,
    )
    expected_canonical_id = canonical_id_for(source_store, top_level_id)
    if canonical_id != expected_canonical_id:
        raise PartialBatch(
            f"{prefix} canonicalId does not match {expected_canonical_id}"
        )
    if require_text(source_record, "type", prefix) != source_type:
        raise PartialBatch(f"{prefix} sourceRecord.type disagrees with type")
    if (
        kind not in SYNTHETIC_IDENTITY_KINDS
        and top_level_id != source_id
    ):
        raise PartialBatch(f"{prefix} id disagrees with sourceRecord.id")
    source_version = source_record.get("version")
    if source_version is not None and (
        isinstance(source_version, bool)
        or not isinstance(source_version, int)
        or source_version < 1
    ):
        raise PartialBatch(f"{prefix} has an invalid sourceRecord.version")
    lineage = record.get("lineage")
    if not isinstance(lineage, list) or not lineage:
        raise PartialBatch(f"{prefix} has no lineage")
    for item in lineage:
        if not isinstance(item, dict):
            raise PartialBatch(f"{prefix} has a non-object lineage entry")
        lineage_store = require_text(item, "store", prefix)
        if SOURCE_NAMESPACE.fullmatch(lineage_store) is None:
            raise PartialBatch(f"{prefix} has an invalid lineage namespace")
        for field in ("package", "recordId"):
            if field in item:
                require_text(item, field, prefix)
    if not any(
        isinstance(item, dict)
        and item.get("store") == source_store
        and item.get("recordId") == source_id
        for item in lineage
    ):
        raise PartialBatch(
            f"{prefix} lineage omits source record {canonical_id}"
        )
    if kind in PARENTED_SERIES_KINDS or kind == "sampleEncodingError":
        expected_parent = canonical_id_for(source_store, source_id)
        if record.get("parentCanonicalId") != expected_parent:
            raise PartialBatch(f"{prefix} has an invalid parentCanonicalId")
    sample_id = record.get("sample")
    if (
        kind in PARENTED_SERIES_KINDS
        and sample_id is not None
        and sample_id != source_id
    ):
        raise PartialBatch(f"{prefix} sample disagrees with sourceRecord.id")
    if (
        kind in PARENTED_SERIES_KINDS
        and not series_kind_matches_type(kind, source_type)
    ):
        raise PartialBatch(f"{prefix} series kind disagrees with source type")
    resolution = record.get("resolutionCanonicalId")
    if resolution is not None and resolution != canonical_id_for(
        source_store,
        series_end_id(source_id, source_type),
    ):
        raise PartialBatch(
            f"{prefix} has an invalid series completion identity"
        )
    validate_kind_fields(record, kind, prefix)


def validate_run_record(record, kind, prefix):
    if kind == "manifest":
        require_text(record, "run", prefix)
        require_instant(record, "createdAt", prefix)
    elif kind == "resume":
        require_text(record, "run", prefix)
        require_instant(record, "resumedAt", prefix)
    elif kind == "typeSummary":
        require_text(record, "type", prefix)
        require_text(record, "state", prefix)
    elif kind == "typeError":
        require_text(record, "type", prefix)
        require_text(record, "message", prefix)
    elif kind == "typeCoverage":
        require_text(record, "type", prefix)
        require_text(record, "state", prefix)
        if not isinstance(record.get("complete"), bool):
            raise PartialBatch(f"{prefix} has an invalid complete value")
        require_instant(record, "observedAt", prefix)
        delivered = record.get("deliveredCount")
        if delivered is not None and (
            isinstance(delivered, bool)
            or not isinstance(delivered, int)
            or delivered < 0
        ):
            raise PartialBatch(f"{prefix} has an invalid deliveredCount")
        for field in ("primedFrom", "primedThrough"):
            if field in record:
                require_instant(record, field, prefix)
    elif kind == "completion":
        require_text(record, "run", prefix)
        require_instant(record, "completedAt", prefix)
        count = record.get("records")
        if (
            isinstance(count, bool)
            or not isinstance(count, int)
            or count < 0
        ):
            raise PartialBatch(f"{prefix} has an invalid records count")
    elif kind == "hozzConnectionTest":
        raise PartialBatch(f"{prefix} is a transport probe, not an archive record")


def validate_kind_fields(record, kind, prefix):
    if kind == "deletion":
        return
    if kind == "characteristics":
        require_instant(record, "readAt", prefix)
        if not isinstance(record.get("characteristics"), dict):
            raise PartialBatch(f"{prefix} has no characteristics object")
        return
    if kind == "sampleEncodingError":
        require_text(record, "message", prefix)
        require_text(record, "parentCanonicalId", prefix)
        return
    require_instant(record, "startDate", prefix)
    require_instant(record, "endDate", prefix)
    if kind == "quantity":
        quantity = record.get("quantity")
        if not isinstance(quantity, dict):
            raise PartialBatch(f"{prefix} has no quantity object")
        require_text(quantity, "unit", prefix)
        value = quantity.get("value")
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
        ):
            raise PartialBatch(f"{prefix} has an invalid quantity.value")
        canonical = quantity.get("canonical")
        if canonical is not None:
            if not isinstance(canonical, dict):
                raise PartialBatch(
                    f"{prefix} has an invalid quantity.canonical object"
                )
            require_text(canonical, "unit", prefix)
            require_number(canonical, "value", prefix)
        original = quantity.get("original")
        if original is not None:
            if not isinstance(original, dict):
                raise PartialBatch(
                    f"{prefix} has an invalid quantity.original object"
                )
            if "unit" in original:
                require_text(original, "unit", prefix)
            if "value" in original:
                require_number(original, "value", prefix)
    elif kind == "category":
        require_integer(record, "value", prefix)
    elif kind == "workout":
        require_integer(record, "activityType", prefix)
    elif kind in {
        "electrocardiogramEnd",
        "electrocardiogramVoltages",
        "quantitySeriesEnd",
        "quantitySeriesReadings",
        "workoutRouteEnd",
        "workoutRouteLocations",
    }:
        require_text(record, "parentCanonicalId", prefix)


def require_text(record, field, prefix):
    value = record.get(field)
    if not isinstance(value, str) or not value:
        raise PartialBatch(f"{prefix} has no {field}")
    return value


def canonical_id_for(store, record_id):
    return f"{store}:{record_id}"


def require_integer(record, field, prefix):
    value = record.get(field)
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value < -2_147_483_648
        or value > 2_147_483_647
    ):
        raise PartialBatch(f"{prefix} has an invalid {field}")
    return value


def require_number(record, field, prefix):
    value = record.get(field)
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
    ):
        raise PartialBatch(f"{prefix} has an invalid {field}")
    return value


def require_instant(record, field, prefix):
    value = require_text(record, field, prefix)
    if RFC3339.fullmatch(value) is None:
        raise PartialBatch(f"{prefix} has an invalid {field}")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise PartialBatch(f"{prefix} has an invalid {field}") from error
    if "T" not in value or parsed.tzinfo is None:
        raise PartialBatch(f"{prefix} has an invalid {field}")
    return value


def ingest_lines(db, lines, batch_key=None):
    """Store one batch. Returns (stored, deleted, skipped_duplicate_batch)."""
    try:
        stored, deleted, duplicate, _ = _ingest_lines(
            db, lines, batch_key
        )
        db.commit()
        return stored, deleted, duplicate
    except Exception:
        db.rollback()
        raise


def _ingest_lines(
    db,
    lines,
    batch_key=None,
    strict_v1=False,
    run_scope_key=None,
    replay_run_occurrences=False,
):
    legacy_receipt = False
    if batch_key:
        seen = db.execute(
            "SELECT records, deletions FROM batches WHERE key = ?", (batch_key,)
        ).fetchone()
        if seen:
            if seen[1] >= 0:
                # Hozz resends a batch when a response was lost. The data is
                # already here, so acknowledging without storing it again is
                # exactly right.
                return 0, 0, True, 0
            legacy_receipt = True

    reset_affected_sample_ids(db)
    reset_batch_record_semantics(db)
    stored = deleted = canonical_count = 0
    pending_null_heart_aliases = []
    scope_key = run_scope_key or batch_key
    current_run = f"batch:{scope_key}" if scope_key else None
    occurrences = {}
    for index, line in enumerate(lines):
        if isinstance(line, bytes):
            original_line = decode_utf8(line, f"line {index + 1}")
        else:
            original_line = line
        original_line = original_line.removesuffix("\n").removesuffix("\r")
        parse_line = original_line.strip()
        if not parse_line:
            continue
        try:
            record = parse_json(parse_line)
        except (json.JSONDecodeError, ValueError) as error:
            # Most often a body truncated by a dropped connection. Refusing the
            # whole batch makes Hozz retry it, which is exactly right.
            raise PartialBatch(f"line {index + 1} is not valid JSON") from error
        if not isinstance(record, dict):
            raise PartialBatch(f"line {index + 1} is not a JSON object")
        schema_version = record.get("schemaVersion")
        if schema_version is not None and (
            isinstance(schema_version, bool)
            or not isinstance(schema_version, int)
            or schema_version != 1
        ):
            raise PartialBatch(
                f"line {index + 1} has an unsupported schemaVersion"
            )
        if strict_v1:
            validate_strict_v1(record, index + 1)

        kind = record.get("kind")
        if kind in RUN_KINDS:
            if record.get("run"):
                current_run = record["run"]
            stored_line = (
                original_line
                if strict_v1 or "schemaVersion" in record
                else normalize_legacy_run_line(record)
            )
            scope = current_run or "unscoped"
            fingerprint = hashlib.sha256(
                f"{scope}\0{stored_line}".encode()
            ).hexdigest()
            if (
                fingerprint not in occurrences
                and len(occurrences) >= MAX_RUN_OCCURRENCE_KEYS
            ):
                raise PartialBatch(
                    "run contains too many distinct record forms"
                )
            if fingerprint not in occurrences:
                first_occurrence = 0
                if (
                    batch_key
                    and not legacy_receipt
                    and not replay_run_occurrences
                ):
                    first_occurrence = db.execute(
                        """
                        SELECT COALESCE(MAX(occurrence) + 1, 0)
                        FROM archive_run_records
                        WHERE fingerprint = ?
                        """,
                        (fingerprint,),
                    ).fetchone()[0]
                occurrences[fingerprint] = first_occurrence
            occurrence = occurrences[fingerprint]
            occurrences[fingerprint] = occurrence + 1
            db.execute(
                """
                INSERT OR IGNORE INTO archive_run_records
                    (fingerprint, occurrence, kind, raw)
                VALUES (?, ?, ?, ?)
                """,
                (fingerprint, occurrence, kind, stored_line),
            )
            continue

        identity = record_identity(record)
        if identity is None:
            raise PartialBatch(
                f"line {index + 1} has no record identity"
            )
        canonical_count += 1
        canonical_id, source_id, parent_id, version = identity
        resolution_id = nonempty_text(record.get("resolutionCanonicalId"))
        duplicate_in_batch = prevalidate_canonical_record(
            db,
            canonical_id,
            version,
            record,
        )
        mark_affected_sample_ids(
            db,
            (canonical_id, parent_id, resolution_id),
        )
        if duplicate_in_batch:
            continue
        tombstone = kind == "deletion" or record.get("deleted") is True
        record_type = record.get("type", "")
        start_date = record.get("startDate")
        if not tombstone:
            mapped_stable_ids = db.execute(
                """
                SELECT stable_id FROM compatible_alias_identity
                WHERE legacy_id = ?
                """,
                (canonical_id,),
            ).fetchall()
            if len(mapped_stable_ids) > 1:
                raise PartialBatch(
                    "legacy identity maps to more than one stable record"
                )
            if len(mapped_stable_ids) == 1:
                retired_cursor = db.execute(
                    """
                    UPDATE samples
                    SET tombstone = 1,
                        record_version = MAX(record_version + 1, ?)
                    WHERE canonical_id = ? AND tombstone = 0
                    """,
                    (version + 1, canonical_id),
                )
                deleted += retired_cursor.rowcount
                continue
        if (
            not tombstone
            and canonical_id.startswith("apple.healthkit:")
            and source_id.startswith(f"{record_type}:")
        ):
            if db.execute(
                """
                SELECT 1 FROM compatible_unresolved_deletion
                WHERE type = ? LIMIT 1
                """,
                (record_type,),
            ).fetchone():
                raise PartialBatch(
                    "legacy identity cannot be reconciled with a pending deletion"
                )
            signature = compatibility_record_signature(record)
            quantity = record.get("quantity")
            source_object = record.get("source")
            known_null_heart_rate = is_known_legacy_heart_rate_alias(
                source_id,
                start_date,
                record.get("endDate"),
                (
                    quantity.get("value")
                    if isinstance(quantity, dict)
                    else record.get("value")
                ),
                quantity.get("unit") if isinstance(quantity, dict) else None,
                (
                    source_object.get("name")
                    if isinstance(source_object, dict)
                    else None
                ),
                kind,
                parse_line,
            )
            if known_null_heart_rate:
                pending_null_heart_aliases.append(
                    (canonical_id, version, signature)
                )
                continue
            if signature is None:
                if (
                    record_type == "sleep_analysis"
                    and source_id == "sleep_analysis:None"
                    and (
                        db.execute(
                        """
                        SELECT 1 FROM samples
                        WHERE type = 'sleep_analysis' AND tombstone = 0
                          AND canonical_id LIKE 'healthAutoExport:%'
                        LIMIT 1
                        """
                        ).fetchone()
                        or db.execute(
                            """
                            SELECT 1 FROM compatible_alias_retirement
                            WHERE type = 'sleep_analysis'
                            LIMIT 1
                            """
                        ).fetchone()
                        or db.execute(
                            """
                            SELECT 1 FROM compatible_unresolved_deletion
                            WHERE type = 'sleep_analysis'
                            LIMIT 1
                            """
                        ).fetchone()
                    )
                ):
                    raise PartialBatch(
                        "date-less legacy sleep identity is ambiguous"
                    )
            else:
                retired_ids = db.execute(
                    """
                    SELECT stable_id FROM compatible_alias_retirement
                    WHERE type = ? AND start_instant = ?
                      AND end_instant IS ? AND value IS ? AND unit IS ?
                      AND source IS ? AND kind IS ?
                    """,
                    signature,
                ).fetchall()
                if not retired_ids:
                    matches = []
                    for candidate in db.execute(
                        """
                        SELECT canonical_id, type, start_date, end_date,
                               value, unit, source, kind
                        FROM samples
                        WHERE type = ? AND tombstone = 0
                          AND canonical_id LIKE 'healthAutoExport:%'
                        """,
                        (record_type,),
                    ):
                        candidate_signature = compatibility_stored_signature(
                            candidate[1:]
                        )
                        if candidate_signature == signature:
                            matches.append(candidate[0])
                    if len(matches) > 1:
                        raise PartialBatch(
                            "legacy identity matches more than one stable record"
                        )
                    if len(matches) == 1:
                        db.execute(
                            """
                            INSERT OR IGNORE INTO compatible_alias_retirement
                                (type, start_instant, end_instant, value, unit,
                                 source, kind, stable_id)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            (*signature, matches[0]),
                        )
                        retired_ids = [(matches[0],)]
                if len(retired_ids) > 1:
                    raise PartialBatch(
                        "legacy identity matches more than one stable record"
                    )
                if len(retired_ids) == 1:
                    mapped = db.execute(
                        """
                        SELECT 1 FROM compatible_alias_identity
                        WHERE stable_id = ? AND legacy_id = ?
                        """,
                        (retired_ids[0][0], canonical_id),
                    ).fetchone()
                    if not mapped:
                        raise PartialBatch(
                            "legacy identity has no unambiguous stable mapping"
                        )
                    retired_cursor = db.execute(
                        """
                        UPDATE samples
                        SET tombstone = 1,
                            record_version = MAX(record_version + 1, 2)
                        WHERE canonical_id = ? AND tombstone = 0
                        """,
                        (canonical_id,),
                    )
                    deleted += retired_cursor.rowcount
                    continue
        if parent_id:
            parent = db.execute(
                "SELECT record_version, tombstone FROM samples "
                "WHERE canonical_id = ?",
                (parent_id,),
            ).fetchone()
            if parent and parent[1]:
                tombstone = True
                version = max(version, parent[0])

        quantity = record.get("quantity") or {}
        source = record.get("source") or {}
        cursor = db.execute(
            """
            INSERT INTO samples
                (canonical_id, source_id, parent_canonical_id,
                 resolution_canonical_id, record_version,
                 tombstone, type, kind, start_date, end_date, value, unit,
                 minimum, maximum, text_value, duration_seconds, source, raw)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(canonical_id) DO UPDATE SET
                source_id = excluded.source_id,
                parent_canonical_id = excluded.parent_canonical_id,
                resolution_canonical_id = excluded.resolution_canonical_id,
                record_version = excluded.record_version,
                tombstone = excluded.tombstone,
                type = excluded.type,
                kind = excluded.kind,
                start_date = excluded.start_date,
                end_date = excluded.end_date,
                value = excluded.value,
                unit = excluded.unit,
                minimum = excluded.minimum,
                maximum = excluded.maximum,
                text_value = excluded.text_value,
                duration_seconds = excluded.duration_seconds,
                source = excluded.source,
                raw = excluded.raw
            WHERE excluded.record_version > samples.record_version
            """,
            (
                canonical_id,
                source_id,
                parent_id,
                resolution_id,
                version,
                1 if tombstone else 0,
                record.get("type", ""),
                kind,
                record.get("startDate"),
                record.get("endDate"),
                quantity.get(
                    "value",
                    record.get("value", record.get("duration")),
                ),
                quantity.get("unit"),
                record.get("minimum"),
                record.get("maximum"),
                record.get("textValue"),
                record.get("durationSeconds", record.get("duration")),
                source.get("name"),
                parse_line,
            ),
        )
        winner = db.execute(
            "SELECT record_version, tombstone FROM samples "
            "WHERE canonical_id = ?",
            (canonical_id,),
        ).fetchone()
        preserve_compatible_stable_state(
            db,
            canonical_id,
            version,
            record,
            winner,
        )
        if winner and winner[1]:
            cascade = db.execute(
                """
                UPDATE samples
                SET tombstone = 1,
                    record_version = MAX(record_version, ?)
                WHERE parent_canonical_id = ?
                """,
                (winner[0], canonical_id),
            )
            deleted += cursor.rowcount + cascade.rowcount
        else:
            stored += cursor.rowcount
            if kind != "sampleEncodingError":
                db.execute(
                    """
                    UPDATE samples
                    SET tombstone = 1,
                        record_version = MAX(record_version, ? + 1)
                    WHERE parent_canonical_id = ?
                      AND kind = 'sampleEncodingError'
                      AND resolution_canonical_id IS NULL
                    """,
                    (winner[0] if winner else version, canonical_id),
                )

    verified_null_heart_aliases = resolve_pending_null_heart_aliases(
        db,
        pending_null_heart_aliases,
    )
    for stable_id, canonical_id, version in verified_null_heart_aliases:
        record_compatible_alias_identity(
            db,
            stable_id,
            canonical_id,
        )
        retired_cursor = db.execute(
            """
            UPDATE samples
            SET tombstone = 1,
                record_version = MAX(record_version + 1, ?)
            WHERE canonical_id = ? AND tombstone = 0
            """,
            (version + 1, canonical_id),
        )
        deleted += retired_cursor.rowcount

    if batch_key:
        if legacy_receipt:
            db.execute(
                "UPDATE batches SET deletions = ? WHERE key = ?",
                (deleted, batch_key),
            )
        else:
            db.execute(
                """
                INSERT OR IGNORE INTO batches
                    (key, received_at, records, deletions)
                VALUES (?, ?, ?, ?)
                """,
                (batch_key, time.time(), stored, deleted),
            )
    if canonical_count:
        reconcile_affected_encoding_errors(db)
    return stored, deleted, legacy_receipt, canonical_count


def reset_batch_record_semantics(db):
    db.execute(
        """
        CREATE TEMP TABLE IF NOT EXISTS receiver_batch_record_semantics (
            canonical_id TEXT NOT NULL,
            record_version INTEGER NOT NULL,
            semantics TEXT NOT NULL,
            PRIMARY KEY (canonical_id, record_version)
        ) WITHOUT ROWID
        """
    )
    db.execute("DELETE FROM receiver_batch_record_semantics")


def prevalidate_canonical_record(db, canonical_id, version, record):
    semantics = normalized_record_semantics(record)
    existing = db.execute(
        """
        SELECT raw FROM samples
        WHERE canonical_id = ? AND record_version = ?
        """,
        (canonical_id, version),
    ).fetchone()
    if (
        existing is not None
        and not records_semantically_identical(existing[0], record)
    ):
        raise PartialBatch(
            "record conflicts with an existing record at the same version"
        )
    seen = db.execute(
        """
        SELECT semantics FROM receiver_batch_record_semantics
        WHERE canonical_id = ? AND record_version = ?
        """,
        (canonical_id, version),
    ).fetchone()
    if seen is not None:
        if seen[0] != semantics:
            raise PartialBatch(
                "record conflicts with another record at the same version"
            )
        return True
    db.execute(
        """
        INSERT INTO receiver_batch_record_semantics
            (canonical_id, record_version, semantics)
        VALUES (?, ?, ?)
        """,
        (canonical_id, version, semantics),
    )
    return False


def normalized_record_semantics(record):
    return json.dumps(
        record,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )


def records_semantically_identical(stored_raw, incoming):
    try:
        stored = parse_json(stored_raw)
    except (TypeError, ValueError):
        return False
    return normalized_record_semantics(stored) == normalized_record_semantics(
        incoming
    )


def record_compatible_alias_identity(db, stable_id, legacy_id):
    existing = db.execute(
        """
        SELECT stable_id FROM compatible_alias_identity
        WHERE legacy_id = ?
        """,
        (legacy_id,),
    ).fetchone()
    if existing is not None and existing[0] != stable_id:
        raise PartialBatch(
            "legacy identity maps to more than one stable record"
        )
    db.execute(
        """
        INSERT OR IGNORE INTO compatible_alias_identity
            (stable_id, legacy_id)
        VALUES (?, ?)
        """,
        (stable_id, legacy_id),
    )


def preserve_compatible_stable_state(
    db,
    canonical_id,
    incoming_version,
    record,
    winner,
):
    if (
        not canonical_id.startswith("healthAutoExport:")
        or winner is None
        or winner[0] != incoming_version
    ):
        return
    stable_id = canonical_id
    record_type = record.get("type", "")
    if winner[1]:
        has_signature = db.execute(
            """
            SELECT 1 FROM compatible_alias_retirement
            WHERE stable_id = ? LIMIT 1
            """,
            (stable_id,),
        ).fetchone()
        if has_signature:
            db.execute(
                """
                INSERT OR IGNORE INTO compatible_resolved_deletion (stable_id)
                VALUES (?)
                """,
                (stable_id,),
            )
            db.execute(
                """
                DELETE FROM compatible_unresolved_deletion
                WHERE stable_id = ?
                """,
                (stable_id,),
            )
        else:
            db.execute(
                """
                INSERT OR REPLACE INTO compatible_unresolved_deletion
                    (stable_id, type)
                VALUES (?, ?)
                """,
                (stable_id, record_type),
            )
        return

    signature = compatibility_record_signature(record)
    if signature is None:
        db.execute(
            """
            INSERT OR REPLACE INTO compatible_unresolved_deletion
                (stable_id, type)
            VALUES (?, ?)
            """,
            (stable_id, record_type),
        )
        return
    existing = {
        tuple(row) for row in db.execute(
            """
            SELECT type, start_instant, end_instant, value, unit, source, kind
            FROM compatible_alias_retirement
            WHERE stable_id = ?
            """,
            (stable_id,),
        )
    }
    if existing and signature not in existing:
        raise PartialBatch(
            "stable identity conflicts with its preserved alias signature"
        )
    db.execute(
        """
        INSERT OR IGNORE INTO compatible_alias_retirement
            (type, start_instant, end_instant, value, unit,
             source, kind, stable_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (*signature, stable_id),
    )
    db.execute(
        """
        INSERT OR IGNORE INTO compatible_resolved_deletion (stable_id)
        VALUES (?)
        """,
        (stable_id,),
    )
    db.execute(
        """
        DELETE FROM compatible_unresolved_deletion
        WHERE stable_id = ?
        """,
        (stable_id,),
    )


def reset_affected_sample_ids(db):
    db.execute(
        """
        CREATE TEMP TABLE IF NOT EXISTS receiver_affected_sample_ids (
            canonical_id TEXT PRIMARY KEY
        ) WITHOUT ROWID
        """
    )
    db.execute("DELETE FROM receiver_affected_sample_ids")


def mark_affected_sample_ids(db, canonical_ids):
    db.executemany(
        """
        INSERT OR IGNORE INTO receiver_affected_sample_ids (canonical_id)
        VALUES (?)
        """,
        (
            (canonical_id,)
            for canonical_id in canonical_ids
            if canonical_id is not None
        ),
    )


def reconcile_affected_encoding_errors(db):
    db.execute(
        """
        CREATE TEMP TABLE IF NOT EXISTS receiver_affected_encoding_errors (
            canonical_id TEXT PRIMARY KEY
        ) WITHOUT ROWID
        """
    )
    db.execute("DELETE FROM receiver_affected_encoding_errors")
    db.execute(
        """
        INSERT OR IGNORE INTO receiver_affected_encoding_errors (canonical_id)
        SELECT sample.canonical_id
        FROM receiver_affected_sample_ids AS affected
        CROSS JOIN samples AS sample
          ON sample.canonical_id = affected.canonical_id
        WHERE sample.kind = 'sampleEncodingError'
        """
    )
    db.execute(
        """
        INSERT OR IGNORE INTO receiver_affected_encoding_errors (canonical_id)
        SELECT child.canonical_id
        FROM samples AS child INDEXED BY samples_parent_kind
        WHERE child.parent_canonical_id IN (
            SELECT canonical_id FROM receiver_affected_sample_ids
        )
          AND child.kind = 'sampleEncodingError'
        """
    )
    db.execute(
        """
        INSERT OR IGNORE INTO receiver_affected_encoding_errors (canonical_id)
        SELECT child.canonical_id
        FROM samples AS child INDEXED BY samples_resolution_kind
        WHERE child.resolution_canonical_id IN (
            SELECT canonical_id FROM receiver_affected_sample_ids
        )
          AND child.kind = 'sampleEncodingError'
        """
    )
    restore_unresolved_continuation_errors(db, affected_only=True)
    reconcile_encoding_errors(db, affected_only=True)


def reconcile_encoding_errors(db, affected_only=False):
    affected_clause = (
        """
          AND child.rowid IN (
              SELECT candidate.rowid
              FROM receiver_affected_encoding_errors AS affected
              CROSS JOIN samples AS candidate
                ON candidate.canonical_id = affected.canonical_id
          )
        """
        if affected_only
        else ""
    )
    db.execute(
        f"""
        UPDATE samples AS child
        SET tombstone = 1,
            record_version = MAX(
                child.record_version + 1,
                (
                    SELECT parent.record_version + 1
                    FROM samples AS parent
                    WHERE parent.canonical_id = COALESCE(
                        child.resolution_canonical_id,
                        child.parent_canonical_id
                    )
                )
            )
        WHERE child.kind = 'sampleEncodingError'
          AND child.tombstone = 0
          AND EXISTS (
              SELECT 1
              FROM samples AS parent
              WHERE parent.canonical_id = COALESCE(
                  child.resolution_canonical_id,
                  child.parent_canonical_id
              )
                AND parent.kind != 'sampleEncodingError'
                AND parent.tombstone = 0
                AND (
                    child.resolution_canonical_id IS NULL
                    OR (
                        parent.kind IN (
                            CASE
                                WHEN child.type = 'HKWorkoutRouteTypeIdentifier'
                                    THEN 'workoutRouteEnd'
                                WHEN child.type = 'HKDataTypeIdentifierElectrocardiogram'
                                    THEN 'electrocardiogramEnd'
                                ELSE 'quantitySeriesEnd'
                            END
                        )
                        AND parent.type = child.type
                        AND parent.parent_canonical_id =
                            child.parent_canonical_id
                    )
                )
          )
          {affected_clause}
        """
    )


def restore_unresolved_continuation_errors(db, affected_only=False):
    affected_clause = (
        """
          AND child.rowid IN (
              SELECT candidate.rowid
              FROM receiver_affected_encoding_errors AS affected
              CROSS JOIN samples AS candidate
                ON candidate.canonical_id = affected.canonical_id
          )
        """
        if affected_only
        else ""
    )
    db.execute(
        f"""
        UPDATE samples AS child
        SET tombstone = 0,
            record_version = child.record_version + 1
        WHERE child.kind = 'sampleEncodingError'
          AND child.resolution_canonical_id IS NOT NULL
          AND child.tombstone = 1
          AND NOT EXISTS (
              SELECT 1
              FROM samples AS parent
              WHERE parent.canonical_id = child.parent_canonical_id
                AND parent.tombstone = 1
          )
          AND NOT EXISTS (
              SELECT 1
              FROM samples AS resolver
              WHERE resolver.canonical_id =
                        child.resolution_canonical_id
                AND resolver.type = child.type
                AND resolver.parent_canonical_id =
                        child.parent_canonical_id
                AND resolver.tombstone = 0
                AND resolver.kind = CASE
                    WHEN child.type = 'HKWorkoutRouteTypeIdentifier'
                        THEN 'workoutRouteEnd'
                    WHEN child.type = 'HKDataTypeIdentifierElectrocardiogram'
                        THEN 'electrocardiogramEnd'
                    ELSE 'quantitySeriesEnd'
                END
          )
          {affected_clause}
        """
    )


def restore_continuation_errors(db):
    rows = db.execute(
        """
        SELECT canonical_id, parent_canonical_id, raw, record_version,
               resolution_canonical_id, tombstone
        FROM samples
        WHERE kind = 'sampleEncodingError'
        """
    )
    for (
        canonical_id,
        parent_id,
        raw,
        stored_version,
        stored_resolution_id,
        stored_tombstone,
    ) in rows:
        try:
            record = parse_json(raw)
        except (TypeError, ValueError):
            continue
        if not isinstance(record, dict):
            continue
        try:
            record_identity(record)
        except PartialBatch:
            continue
        resolution_id = nonempty_text(record.get("resolutionCanonicalId"))
        if resolution_id is None:
            continue
        if stored_resolution_id is None:
            db.execute(
                """
                UPDATE samples
                SET resolution_canonical_id = ?
                WHERE canonical_id = ?
                """,
                (resolution_id, canonical_id),
            )
        parent = db.execute(
            "SELECT tombstone FROM samples WHERE canonical_id = ?",
            (parent_id,),
        ).fetchone()
        resolver = db.execute(
            """
            SELECT kind, parent_canonical_id, tombstone, type
            FROM samples
            WHERE canonical_id = ?
            """,
            (resolution_id,),
        ).fetchone()
        has_valid_end = (
            resolver is not None
            and resolver[0] == series_end_kind(
                nonempty_text(record.get("type")) or ""
            )
            and resolver[1] == parent_id
            and resolver[2] == 0
            and resolver[3] == record.get("type")
        )
        if (
            stored_tombstone
            and (parent is None or parent[0] == 0)
            and not has_valid_end
        ):
            version = record.get("recordVersion")
            if (
                isinstance(version, bool)
                or not isinstance(version, int)
                or version < 3
            ):
                version = 3
            db.execute(
                """
                UPDATE samples
                SET record_version = ?, tombstone = 0
                WHERE canonical_id = ?
                """,
                (max(stored_version + 1, version), canonical_id),
            )


def reconcile_parent_tombstones(db):
    db.execute(
        """
        UPDATE samples AS child
        SET tombstone = 1,
            record_version = MAX(
                child.record_version,
                (
                    SELECT parent.record_version
                    FROM samples AS parent
                    WHERE parent.canonical_id = child.parent_canonical_id
                )
            )
        WHERE EXISTS (
            SELECT 1
            FROM samples AS parent
            WHERE parent.canonical_id = child.parent_canonical_id
              AND parent.tombstone = 1
        )
        """
    )


def normalize_legacy_run_line(record):
    normalized = dict(record)
    normalized.setdefault("schemaVersion", 1)
    return json.dumps(
        normalized,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )


def ingest_payload(db, payload, batch_key=None):
    """Handle NDJSON, a JSON array, or the compatible envelope."""
    if len(payload) > MAX_PENDING_BATCH_BYTES:
        raise PartialBatch("payload exceeds the pending import memory budget")
    return ingest_seekable_stream(
        db,
        io.BytesIO(payload),
        len(payload),
        batch_key,
    )


class LengthLimitedRawReader(io.RawIOBase):
    def __init__(self, source, length):
        super().__init__()
        self.source = source
        self.length = length
        self.position = 0
        self.source.seek(0)

    def readable(self):
        return True

    def seekable(self):
        return True

    def readinto(self, buffer):
        if self.closed:
            raise ValueError("I/O operation on closed stream")
        remaining = self.length - self.position
        if remaining <= 0:
            return 0
        data = self.source.read(min(len(buffer), remaining))
        if not data:
            return 0
        size = len(data)
        buffer[:size] = data
        self.position += size
        return size

    def seek(self, offset, whence=os.SEEK_SET):
        if self.closed:
            raise ValueError("I/O operation on closed stream")
        if whence == os.SEEK_SET:
            position = offset
        elif whence == os.SEEK_CUR:
            position = self.position + offset
        elif whence == os.SEEK_END:
            position = self.length + offset
        else:
            raise ValueError("invalid whence")
        if position < 0 or position > self.length:
            raise ValueError("seek outside captured file length")
        self.source.seek(position)
        self.position = position
        return position

    def tell(self):
        return self.position


@contextmanager
def length_limited_stream(source, length):
    raw = LengthLimitedRawReader(source, length)
    bounded = io.BufferedReader(raw, buffer_size=64 * 1_024)
    try:
        yield bounded
    finally:
        bounded.close()
        source.seek(0)


def ingest_seekable_stream(
    db,
    stream,
    length,
    batch_key=None,
    commit=True,
    run_scope_key=None,
    replay_run_occurrences=False,
):
    with length_limited_stream(stream, length) as bounded:
        return _ingest_seekable_stream(
            db,
            bounded,
            length,
            batch_key,
            commit,
            run_scope_key,
            replay_run_occurrences,
        )


def _ingest_seekable_stream(
    db,
    stream,
    length,
    batch_key=None,
    commit=True,
    run_scope_key=None,
    replay_run_occurrences=False,
):
    stream.seek(0)
    first_offset = None
    scanned = 0
    while scanned < length:
        chunk = stream.read(min(64 * 1_024, length - scanned))
        if not chunk:
            break
        for index, value in enumerate(chunk):
            if not chr(value).isspace():
                first_offset = scanned + index
                break
        if first_offset is not None:
            break
        scanned += len(chunk)
    if first_offset is None:
        return 0, 0, False
    stream.seek(first_offset)
    prefix = stream.read(min(length - first_offset, 512))
    stream.seek(first_offset)
    first = prefix[0]
    if first == ord("{") and length - first_offset <= MAX_ENVELOPE_BYTES:
        candidate = stream.read(length - first_offset)
        stream.seek(first_offset)
        try:
            envelope = parse_json(decode_utf8(candidate, "payload"))
        except (ValueError, TypeError):
            envelope = None
        if is_compatible_envelope(envelope):
            return ingest_compatible(db, envelope, batch_key, commit=commit)

    text = None
    if first == ord("["):
        text = io.TextIOWrapper(stream, encoding="utf-8", errors="strict")
        lines = iter_json_array_lines(text)
    else:
        stream.seek(0)
        lines = iter_ndjson_lines(stream)
    try:
        stored, deleted, duplicate, _ = _ingest_lines(
            db,
            lines,
            batch_key,
            run_scope_key=run_scope_key,
            replay_run_occurrences=replay_run_occurrences,
        )
        if text is not None:
            text.detach()
            text = None
        if commit:
            db.commit()
        return stored, deleted, duplicate
    except Exception:
        if text is not None:
            try:
                text.detach()
            except (ValueError, OSError):
                pass
        db.rollback()
        raise


def iter_ndjson_lines(stream):
    count = 0
    while True:
        raw = stream.readline(MAX_RECORD_BYTES + 2)
        if not raw:
            return
        content = raw[:-1] if raw.endswith(b"\n") else raw
        if content.endswith(b"\r"):
            content = content[:-1]
        if len(content) > MAX_RECORD_BYTES:
            raise PartialBatch("record exceeds the byte limit")
        if raw.strip():
            count += 1
            if count > MAX_RECORD_LINES:
                raise PartialBatch("payload contains too many records")
        yield raw


def iter_json_array_lines(stream):
    decoder = json.JSONDecoder(
        parse_constant=lambda value: (_ for _ in ()).throw(
            ValueError(f"{value} is not valid JSON")
        )
    )
    buffer = ""
    position = 0
    eof = False

    def read_more():
        nonlocal buffer, position, eof
        if position:
            buffer = buffer[position:]
            position = 0
        chunk = stream.read(64 * 1_024)
        if chunk == "":
            eof = True
        else:
            buffer += chunk
        if len(buffer.encode("utf-8")) > MAX_RECORD_BYTES + 64 * 1_024:
            raise PartialBatch("JSON array item exceeds the byte limit")

    read_more()
    while True:
        while position < len(buffer) and buffer[position].isspace():
            position += 1
        if position < len(buffer):
            break
        if eof:
            raise PartialBatch("JSON array is empty or incomplete")
        read_more()
    if buffer[position] != "[":
        raise PartialBatch("payload is not a JSON array")
    position += 1
    count = 0
    expect_value = True
    while True:
        while True:
            while position < len(buffer) and buffer[position].isspace():
                position += 1
            if position < len(buffer) or eof:
                break
            read_more()
        if position < len(buffer) and buffer[position] == "]":
            if expect_value and count > 0:
                raise PartialBatch("JSON array has a trailing separator")
            position += 1
            trailing = buffer[position:]
            while True:
                chunk = stream.read(64 * 1_024)
                if chunk == "":
                    break
                trailing += chunk
                if len(trailing) > 64 * 1_024 and trailing.strip():
                    raise PartialBatch("JSON array has trailing content")
                if not trailing.strip():
                    trailing = ""
            if trailing.strip():
                raise PartialBatch("JSON array has trailing content")
            return
        if not expect_value:
            if position >= len(buffer) or buffer[position] != ",":
                raise PartialBatch("JSON array has no item separator")
            position += 1
            expect_value = True
            continue
        try:
            item_start = position
            value, end = decoder.raw_decode(buffer, position)
        except (json.JSONDecodeError, ValueError) as error:
            if eof:
                raise PartialBatch("JSON array item is incomplete") from error
            read_more()
            continue
        position = end
        if len(buffer[item_start:end].encode("utf-8")) > MAX_RECORD_BYTES:
            raise PartialBatch("JSON array item exceeds the byte limit")
        count += 1
        if count > MAX_RECORD_LINES:
            raise PartialBatch("payload contains too many records")
        yield json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        expect_value = False


def parse_content_length(value):
    if isinstance(value, int):
        text = str(value)
    elif isinstance(value, str):
        text = value
    else:
        text = ""
    if re.fullmatch(r"[0-9]+", text) is None:
        raise PartialBatch("Content-Length is not a nonnegative integer")
    if len(text) > 20:
        raise PartialBatch("Content-Length is too large")
    try:
        return int(text)
    except ValueError as error:
        raise PartialBatch("Content-Length is too large") from error


def is_compatible_envelope(value):
    if not isinstance(value, dict):
        return False
    if any(key in value for key in ("kind", "id", "canonicalId", "type")):
        return False
    data = value.get("data")
    if not isinstance(data, dict):
        return False
    return (
        isinstance(data.get("metrics"), list)
        or isinstance(data.get("deletions"), list)
        or isinstance(data.get("workouts"), list)
    )


def nonempty_token(value):
    if not value:
        raise argparse.ArgumentTypeError("token must not be empty")
    return value


def positive_number(value):
    try:
        number = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive number") from error
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a positive number")
    return number


def positive_integer(value):
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def ingest_compatible(db, envelope, batch_key=None, commit=True):
    """Flatten the Health Auto Export shaped payload into the same table."""
    lines = []
    deletion_lines = []
    legacy_aliases = []
    identities = set()
    deletion_identities = set()
    incoming_stable_ids = set()
    unresolved_deletions = []
    data = envelope.get("data", {})
    if not isinstance(data, dict):
        raise PartialBatch("compatible envelope data is not an object")
    metrics = data.get("metrics", [])
    workouts = data.get("workouts", [])
    deletions = data.get("deletions", [])
    if not all(isinstance(value, list) for value in (metrics, workouts, deletions)):
        raise PartialBatch("compatible envelope collections are not arrays")
    receipt = (
        db.execute(
            "SELECT records, deletions FROM batches WHERE key = ?",
            (batch_key,),
        ).fetchone()
        if batch_key
        else None
    )
    duplicate_receipt = receipt is not None
    migrate_legacy_receipt = bool(
        duplicate_receipt and receipt[1] < 0
    )
    repair_legacy_deletions = bool(
        migrate_legacy_receipt and deletions
    )
    if duplicate_receipt and not migrate_legacy_receipt:
        # Releases before stable point IDs could acknowledge a mixed batch while
        # dropping its date-less deletions. The receipt proves its live records
        # were already handled; replay only the deletions so those old batches
        # can be repaired without accepting another unmatchable live record.
        metrics = []
        workouts = []

    for metric in metrics:
        if not isinstance(metric, dict):
            raise PartialBatch("compatible metric is not an object")
        name = require_text(metric, "name", "compatible metric")
        units = require_text(metric, "units", "compatible metric")
        points = metric.get("data")
        if not isinstance(points, list):
            raise PartialBatch(f"compatible metric {name} has no data array")
        for point in points:
            if not isinstance(point, dict):
                raise PartialBatch(f"compatible metric {name} has a non-object point")
            source = point.get("source")
            if source is not None and not isinstance(source, str):
                raise PartialBatch(f"compatible metric {name} has invalid source")
            identity = require_text(point, "id", f"{name} point")
            stable_canonical_id = canonical_id_for("healthAutoExport", identity)
            incoming_stable_ids.add(stable_canonical_id)
            if name == "heart_rate":
                start = require_compatible_timestamp(
                    point,
                    "date",
                    "heart-rate point",
                )
                end = require_compatible_timestamp(
                    point,
                    "endDate",
                    "heart-rate point",
                    default=start,
                )
                legacy_aliases.append(
                    (
                        name,
                        start,
                        compatible_normalized_timestamp(start),
                        stable_canonical_id,
                    )
                )
                values = [
                    finite_number(point, field, "heart-rate point")
                    for field in ("Min", "Avg", "Max")
                ]
                if values[0] != values[1] or values[1] != values[2]:
                    raise PartialBatch(
                        "heart-rate compatibility point is an aggregate"
                    )
                line = compatibility_quantity(
                    identity,
                    name,
                    units,
                    start,
                    end,
                    values[1],
                    source,
                    point,
                    minimum=values[0],
                    maximum=values[2],
                )
            elif name == "sleep_analysis":
                start = require_compatible_timestamp(
                    point,
                    "startDate",
                    "sleep point",
                )
                end = require_compatible_timestamp(
                    point,
                    "endDate",
                    "sleep point",
                )
                legacy_aliases.append(
                    (
                        name,
                        start,
                        compatible_normalized_timestamp(start),
                        stable_canonical_id,
                    )
                )
                hours = finite_number(point, "qty", "sleep point")
                stage = require_text(point, "value", "sleep point")
                stages = {
                    "In Bed": 0,
                    "Asleep": 1,
                    "Awake": 2,
                    "Core": 3,
                    "Deep": 4,
                    "REM": 5,
                }
                if stage == "Unspecified":
                    raw_stage = finite_number(point, "rawValue", "sleep point")
                    if not raw_stage.is_integer() or not -(2**31) <= raw_stage < 2**31:
                        raise PartialBatch("sleep point has invalid rawValue")
                    stage_value = int(raw_stage)
                elif stage in stages:
                    stage_value = stages[stage]
                else:
                    raise PartialBatch(f"unsupported sleep stage {stage}")
                line = {
                    "id": identity,
                    "kind": "category",
                    "recordVersion": 1,
                    "schemaVersion": 1,
                    "sourceRecord": {
                        "id": identity,
                        "store": "healthAutoExport",
                        "type": name,
                    },
                    "startDate": start,
                    "endDate": end,
                    "textValue": stage,
                    "durationSeconds": hours * 3_600,
                    "type": name,
                    "value": stage_value,
                    "compatibilityRaw": point,
                }
                if source:
                    line["source"] = {"name": source}
            else:
                start = require_compatible_timestamp(
                    point,
                    "date",
                    f"{name} point",
                )
                end = require_compatible_timestamp(
                    point,
                    "endDate",
                    f"{name} point",
                    default=start,
                )
                legacy_aliases.append(
                    (
                        name,
                        start,
                        compatible_normalized_timestamp(start),
                        stable_canonical_id,
                    )
                )
                line = compatibility_quantity(
                    identity,
                    name,
                    units,
                    start,
                    end,
                    finite_number(point, "qty", f"{name} point"),
                    source,
                    point,
                )
            add_compatible_line(lines, identities, line)

    for workout in workouts:
        if not isinstance(workout, dict):
            raise PartialBatch("compatible workout is not an object")
        identity = require_text(workout, "id", "compatible workout")
        name = require_text(workout, "name", "compatible workout")
        start = require_compatible_timestamp(
            workout,
            "start",
            "compatible workout",
        )
        end = require_compatible_timestamp(
            workout,
            "end",
            "compatible workout",
        )
        duration = finite_number(workout, "duration", "compatible workout")
        add_compatible_line(
            lines,
            identities,
            {
                "id": identity,
                "kind": "workout",
                "recordVersion": 1,
                "schemaVersion": 1,
                "sourceRecord": {
                    "id": identity,
                    "store": "healthAutoExport",
                    "type": "workout",
                },
                "startDate": start,
                "endDate": end,
                "duration": duration,
                "durationSeconds": duration,
                "textValue": name,
                "type": "workout",
                "compatibilityRaw": workout,
            },
        )

    for deletion in deletions:
        if not isinstance(deletion, dict):
            raise PartialBatch("compatible deletion is not an object")
        stable_identity = require_text(deletion, "id", "compatible deletion")
        name = require_text(deletion, "name", "compatible deletion")
        record_type = require_text(deletion, "type", "compatible deletion")
        deletion_date = deletion.get("date")
        if not isinstance(deletion_date, str):
            raise PartialBatch("compatible deletion has an invalid timestamp")
        if deletion_date:
            compatible_normalized_timestamp(deletion_date)
        canonical_id = canonical_id_for("healthAutoExport", stable_identity)
        stable_row = db.execute(
            """
            SELECT start_date FROM samples
            WHERE canonical_id = ? AND tombstone = 0
            """,
            (canonical_id,),
        ).fetchone()
        resolved_identity = db.execute(
            """
            SELECT 1 FROM compatible_resolved_deletion
            WHERE stable_id = ?
            """,
            (canonical_id,),
        ).fetchone()
        if stable_row and isinstance(stable_row[0], str):
            legacy_aliases.append(
                (
                    name,
                    stable_row[0],
                    compatible_normalized_timestamp(stable_row[0]),
                    canonical_id,
                )
            )
        if not repair_legacy_deletions:
            if not deletion_date:
                stable_exists = db.execute(
                    "SELECT 1 FROM samples WHERE canonical_id = ?",
                    (canonical_id,),
                ).fetchone()
                legacy_prefix = f"apple.healthkit:{name}:%"
                legacy_exists = db.execute(
                    """
                    SELECT 1 FROM samples
                    WHERE tombstone = 0 AND type = ?
                      AND canonical_id LIKE ?
                    LIMIT 1
                    """,
                    (name, legacy_prefix),
                ).fetchone()
                if (
                    stable_exists is None
                    and resolved_identity is None
                    and canonical_id not in incoming_stable_ids
                    and legacy_exists is not None
                ):
                    raise PartialBatch(
                        "date-less deletion cannot identify a pre-stable record"
                    )
                if (
                    stable_exists is None
                    and resolved_identity is None
                    and canonical_id not in incoming_stable_ids
                ):
                    unresolved_deletions.append((canonical_id, name))
            else:
                if (
                    stable_row
                    or resolved_identity
                    or canonical_id in incoming_stable_ids
                ):
                    legacy_aliases.append(
                        (
                            name,
                            deletion_date,
                            compatible_normalized_timestamp(deletion_date),
                            canonical_id,
                        )
                    )
                else:
                    deletion_instant = compatible_normalized_timestamp(
                        deletion_date
                    )
                    for (legacy_start,) in db.execute(
                        """
                        SELECT start_date FROM samples
                        WHERE type = ? AND tombstone = 0
                          AND canonical_id LIKE 'apple.healthkit:%'
                        """,
                        (name,),
                    ):
                        try:
                            same_instant = (
                                isinstance(legacy_start, str)
                                and compatible_normalized_timestamp(legacy_start)
                                    == deletion_instant
                            )
                        except PartialBatch:
                            same_instant = False
                        if same_instant:
                            raise PartialBatch(
                                "dated deletion cannot identify a legacy record"
                            )
                    unresolved_deletions.append((canonical_id, name))
        add_compatible_line(
            deletion_lines,
            deletion_identities,
            {
                "deleted": True,
                "id": stable_identity,
                "kind": "deletion",
                "recordVersion": 2,
                "schemaVersion": 1,
                "sourceRecord": {
                    "id": stable_identity,
                    "store": "healthAutoExport",
                    "type": record_type,
                },
                "textValue": name,
                "type": record_type,
                "compatibilityRaw": deletion,
            },
        )
        legacy_date = deletion.get("date")
        mapped_legacy = (
            canonical_id_for(
                "apple.healthkit",
                f"{name}:{legacy_date}",
            )
            if isinstance(legacy_date, str) and legacy_date
            else None
        )
        has_legacy_mapping = bool(
            mapped_legacy
            and db.execute(
                """
                SELECT 1 FROM compatible_alias_identity
                WHERE stable_id = ? AND legacy_id = ?
                """,
                (canonical_id, mapped_legacy),
            ).fetchone()
        )
        if repair_legacy_deletions and not has_legacy_mapping:
            raise PartialBatch(
                "legacy receipt deletion has no proven alias mapping"
            )
        if has_legacy_mapping:
            date = require_text(
                deletion,
                "date",
                "legacy compatible deletion",
            )
            legacy_identity = f"{name}:{date}"
            add_compatible_line(
                deletion_lines,
                deletion_identities,
                {
                    "deleted": True,
                    "id": legacy_identity,
                    "kind": "deletion",
                    "recordVersion": 2,
                    "schemaVersion": 1,
                    "sourceRecord": {
                        "id": legacy_identity,
                        "store": "apple.healthkit",
                        "type": name,
                    },
                    "textValue": name,
                    "type": name,
                    "compatibilityRaw": deletion,
                },
            )

    try:
        for stable_id, record_type in unresolved_deletions:
            db.execute(
                """
                INSERT OR REPLACE INTO compatible_unresolved_deletion
                    (stable_id, type)
                VALUES (?, ?)
                """,
                (stable_id, record_type),
            )
        alias_deletions = reconcile_compatible_aliases(
            db,
            legacy_aliases,
            lines,
        )
        encoded_lines = [
            json.dumps(line, separators=(",", ":"))
            for line in [*lines, *deletion_lines]
        ]
        if migrate_legacy_receipt:
            stored, deleted, _, _ = _ingest_lines(db, encoded_lines)
            duplicate = True
            db.execute(
                "UPDATE batches SET deletions = ? WHERE key = ?",
                (deleted, batch_key),
            )
        else:
            stored, deleted, duplicate, _ = _ingest_lines(
                db,
                encoded_lines,
                batch_key,
            )
        deleted += alias_deletions
        if commit:
            db.commit()
        return stored, deleted, duplicate
    except Exception:
        db.rollback()
        raise


def reconcile_compatible_aliases(db, aliases, records):
    record_signatures = {}
    for record in records:
        source_record = record.get("sourceRecord")
        if not isinstance(source_record, dict):
            continue
        stable_id = canonical_id_for(
            source_record.get("store", "healthAutoExport"),
            source_record.get("id", record.get("id", "")),
        )
        signature = compatibility_record_signature(record)
        if signature is not None:
            record_signatures[stable_id] = signature
    targets = {}
    for record_type, _date_text, _instant, stable_id in dict.fromkeys(aliases):
        signature = record_signatures.get(stable_id)
        if signature is None:
            stored = db.execute(
                """
                SELECT type, start_instant, end_instant, value,
                       unit, source, kind
                FROM compatible_alias_retirement
                WHERE stable_id = ?
                LIMIT 1
                """,
                (stable_id,),
            ).fetchone()
            signature = tuple(stored) if stored else None
        if signature is None:
            continue
        existing_signatures = db.execute(
            """
            SELECT type, start_instant, end_instant, value, unit, source, kind
            FROM compatible_alias_retirement
            WHERE stable_id = ?
            """,
            (stable_id,),
        ).fetchall()
        if existing_signatures and signature not in {
            tuple(existing) for existing in existing_signatures
        }:
            raise PartialBatch(
                "stable identity conflicts with its preserved alias signature"
            )
        targets.setdefault(record_type, {})[stable_id] = signature
        db.execute(
            """
            INSERT OR IGNORE INTO compatible_alias_retirement
                (type, start_instant, end_instant, value, unit,
                 source, kind, stable_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (*signature, stable_id),
        )
        db.execute(
            """
            INSERT OR IGNORE INTO compatible_resolved_deletion (stable_id)
            VALUES (?)
            """,
            (stable_id,),
        )
        db.execute(
            """
            DELETE FROM compatible_unresolved_deletion
            WHERE stable_id = ?
            """,
            (stable_id,),
        )

    tombstones = []
    for record_type, target_signatures in targets.items():
        rows = db.execute(
            """
            SELECT source_id, start_date, end_date, value, unit,
                   source, kind, record_version, raw
            FROM samples
            WHERE type = ? AND tombstone = 0
              AND canonical_id LIKE 'apple.healthkit:%'
            """,
            (record_type,),
        )
        candidates = []
        for (
            source_id,
            start_date,
            end_date,
            value,
            unit,
            source,
            kind,
            version,
            raw,
        ) in rows:
            if (
                record_type == "sleep_analysis"
                and source_id == "sleep_analysis:None"
                and target_signatures
            ):
                raise PartialBatch(
                    "date-less legacy sleep identity is ambiguous"
                )
            if not (
                isinstance(start_date, str)
                and source_id.startswith(f"{record_type}:")
            ):
                continue
            try:
                candidate = compatibility_stored_signature(
                    (
                        record_type,
                        start_date,
                        end_date,
                        value,
                        unit,
                        source,
                        kind,
                    )
                )
            except PartialBatch:
                continue
            known_null_heart_rate = is_known_legacy_heart_rate_alias(
                source_id,
                start_date,
                end_date,
                value,
                unit,
                source,
                kind,
                raw,
            )
            candidates.append(
                (source_id, version, candidate, known_null_heart_rate)
            )

        regular_counts = {}
        finite_legacy_counts_by_key = {}
        null_heart_rate_counts = {}
        for _, _, candidate, known_null_heart_rate in candidates:
            if known_null_heart_rate:
                key = heart_rate_alias_key(candidate)
                null_heart_rate_counts[key] = (
                    null_heart_rate_counts.get(key, 0) + 1
                )
            else:
                regular_counts[candidate] = regular_counts.get(candidate, 0) + 1
                key = heart_rate_alias_key(candidate)
                if key is not None and finite_signature_value(candidate[3]):
                    finite_legacy_counts_by_key[key] = (
                        finite_legacy_counts_by_key.get(key, 0) + 1
                    )

        stable_ids_by_signature = {}
        heart_rate_ids_by_key = {}
        starts = sorted({candidate[1] for _, _, candidate, _ in candidates})
        for offset in range(0, len(starts), 500):
            chunk = starts[offset:offset + 500]
            placeholders = ",".join("?" for _ in chunk)
            rows = db.execute(
                f"""
                SELECT start_instant, end_instant, value, unit, source, kind,
                       stable_id
                FROM compatible_alias_retirement
                WHERE type = ? AND start_instant IN ({placeholders})
                """,
                (record_type, *chunk),
            )
            for row in rows:
                signature = (record_type, *row[:6])
                stable_id = row[6]
                stable_ids_by_signature.setdefault(signature, set()).add(
                    stable_id
                )
                key = heart_rate_alias_key(signature)
                if key is not None and finite_signature_value(signature[3]):
                    heart_rate_ids_by_key.setdefault(key, set()).add(stable_id)

        for source_id, version, candidate, known_null_heart_rate in candidates:
            key = heart_rate_alias_key(candidate)
            if known_null_heart_rate:
                matching_targets = set(heart_rate_ids_by_key.get(key, ()))
                matching_candidates = (
                    null_heart_rate_counts.get(key, 0)
                    + finite_legacy_counts_by_key.get(key, 0)
                )
            else:
                matching_targets = set(
                    stable_ids_by_signature.get(candidate, ())
                )
                matching_candidates = regular_counts.get(candidate, 0)
                if key is not None and finite_signature_value(candidate[3]):
                    matching_candidates += null_heart_rate_counts.get(key, 0)
            if matching_targets and (
                len(matching_targets) != 1 or matching_candidates != 1
            ):
                raise PartialBatch(
                    "compatible alias identity is ambiguous"
                )
            if not matching_targets:
                continue
            record_compatible_alias_identity(
                db,
                next(iter(matching_targets)),
                canonical_id_for("apple.healthkit", source_id),
            )
            tombstones.append(json.dumps({
                "deleted": True,
                "id": source_id,
                "kind": "deletion",
                "recordVersion": max(2, version + 1),
                "schemaVersion": 1,
                "sourceRecord": {
                    "id": source_id,
                    "store": "apple.healthkit",
                    "type": record_type,
                },
                "type": record_type,
            }, separators=(",", ":")))
    if not tombstones:
        return 0
    _, deleted, _, _ = _ingest_lines(db, tombstones)
    return deleted


def is_known_legacy_heart_rate_alias(
    source_id,
    start_date,
    end_date,
    value,
    unit,
    source,
    kind,
    raw,
):
    if (
        kind != "quantity"
        or value is not None
        or not isinstance(start_date, str)
        or source_id != f"heart_rate:{start_date}"
    ):
        return False
    try:
        record = parse_json(raw)
    except (TypeError, ValueError):
        return False
    if not isinstance(record, dict) or set(record) != {
        "id",
        "type",
        "kind",
        "startDate",
        "endDate",
        "quantity",
        "source",
    }:
        return False
    quantity = record.get("quantity")
    source_object = record.get("source")
    return bool(
        record.get("id") == source_id
        and record.get("type") == "heart_rate"
        and record.get("kind") == "quantity"
        and record.get("startDate") == start_date
        and record.get("endDate") == end_date
        and isinstance(quantity, dict)
        and set(quantity) == {"value", "unit"}
        and quantity.get("value") is None
        and quantity.get("unit") == unit
        and isinstance(source_object, dict)
        and set(source_object) == {"name"}
        and source_object.get("name") == source
    )


def resolve_pending_null_heart_aliases(db, pending):
    if not pending:
        return []
    pending_by_key = {}
    for canonical_id, version, signature in pending:
        key = heart_rate_alias_key(signature)
        if key is None:
            raise PartialBatch(
                "legacy null heart-rate identity is not unambiguous"
            )
        pending_by_key.setdefault(key, []).append(
            (canonical_id, version, signature)
        )

    stable_ids_by_key = {}
    starts = sorted({signature[1] for _, _, signature in pending})
    for offset in range(0, len(starts), 800):
        chunk = starts[offset:offset + 800]
        placeholders = ",".join("?" for _ in chunk)
        for row in db.execute(
            f"""
            SELECT type, start_instant, end_instant, value, unit,
                   source, kind, stable_id
            FROM compatible_alias_retirement
            WHERE type = 'heart_rate'
              AND value IS NOT NULL
              AND start_instant IN ({placeholders})
            """,
            chunk,
        ):
            signature = tuple(row[:7])
            key = heart_rate_alias_key(signature)
            if key in pending_by_key:
                stable_ids_by_key.setdefault(key, set()).add(row[7])

    competitors_by_key = {}
    for row in db.execute(
        """
        SELECT canonical_id, source_id, type, start_date, end_date,
               value, unit, source, kind
        FROM samples
        WHERE type = 'heart_rate'
          AND tombstone = 0
          AND value IS NOT NULL
          AND (
            canonical_id LIKE 'healthAutoExport:%'
            OR canonical_id LIKE 'apple.healthkit:%'
          )
        """
    ):
        canonical_id, source_id = row[:2]
        try:
            signature = compatibility_stored_signature(row[2:])
        except PartialBatch:
            continue
        if not finite_signature_value(signature[3]):
            continue
        key = heart_rate_alias_key(signature)
        if key not in pending_by_key:
            continue
        if canonical_id.startswith("healthAutoExport:"):
            stable_ids_by_key.setdefault(key, set()).add(canonical_id)
        elif source_id.startswith("heart_rate:"):
            competitors_by_key.setdefault(key, set()).add(canonical_id)

    resolved = []
    for key, aliases in pending_by_key.items():
        stable_ids = stable_ids_by_key.get(key, set())
        competitors = competitors_by_key.get(key, set())
        if len(aliases) != 1 or len(stable_ids) != 1 or competitors:
            raise PartialBatch(
                "legacy null heart-rate identity is not unambiguous"
            )
        canonical_id, version, _ = aliases[0]
        resolved.append((next(iter(stable_ids)), canonical_id, version))
    return resolved


def heart_rate_alias_key(signature):
    if signature is None or signature[0] != "heart_rate":
        return None
    return (
        signature[0],
        signature[1],
        signature[2],
        signature[4],
        signature[5],
        signature[6],
    )


def finite_signature_value(value):
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def require_compatible_timestamp(record, field, context, default=None):
    value = record.get(field, default)
    if not isinstance(value, str) or not value:
        raise PartialBatch(f"{context} has an invalid timestamp")
    compatible_normalized_timestamp(value)
    return value


def compatible_normalized_timestamp(value):
    match = (
        COMPATIBLE_TIMESTAMP.fullmatch(value)
        if isinstance(value, str)
        else None
    )
    if match is None:
        raise PartialBatch("compatible point has an invalid timestamp")
    hour, minute, second = (
        int(component) for component in match.group("time").split(":")
    )
    if hour > 23 or minute > 59 or second > 59:
        raise PartialBatch("compatible point has an invalid timestamp")
    zone = match.group("zone")
    if zone == "Z":
        zone = "+00:00"
    else:
        compact_zone = zone[1:].replace(":", "")
        offset_hour = int(compact_zone[:2])
        offset_minute = int(compact_zone[2:])
        if offset_hour > 23 or offset_minute > 59:
            raise PartialBatch("compatible point has an invalid timestamp")
        zone = f"{zone[0]}{compact_zone[:2]}:{compact_zone[2:]}"
    try:
        parsed = datetime.fromisoformat(
            f"{match.group('date')}T{match.group('time')}{zone}"
        )
        utc = parsed.astimezone(timezone.utc)
    except (OverflowError, ValueError) as error:
        raise PartialBatch("compatible point has an invalid timestamp") from error
    normalized = (
        f"{utc.year:04d}-{utc.month:02d}-{utc.day:02d}"
        f"T{utc.hour:02d}:{utc.minute:02d}:{utc.second:02d}"
    )
    fraction = match.group("fraction")
    if fraction is not None:
        digits = fraction[1:].rstrip("0")
        if digits:
            normalized += f".{digits}"
    return f"{normalized}Z"


def compatibility_record_signature(record):
    start = record.get("startDate")
    if not isinstance(start, str):
        return None
    try:
        start_instant = compatible_normalized_timestamp(start)
        end = record.get("endDate")
        end_instant = compatible_normalized_timestamp(
            end if isinstance(end, str) else start
        )
    except PartialBatch:
        return None
    quantity = record.get("quantity")
    if not isinstance(quantity, dict):
        quantity = {}
    source = record.get("source")
    if not isinstance(source, dict):
        source = {}
    return (
        record.get("type", ""),
        start_instant,
        end_instant,
        quantity.get("value", record.get("value", record.get("duration"))),
        quantity.get("unit", record.get("unit")),
        source.get("name"),
        record.get("kind"),
    )


def compatibility_stored_signature(values):
    (
        record_type,
        start_date,
        end_date,
        value,
        unit,
        source,
        kind,
    ) = values
    if not isinstance(start_date, str):
        return None
    return (
        record_type,
        compatible_normalized_timestamp(start_date),
        compatible_normalized_timestamp(
            end_date if isinstance(end_date, str) else start_date
        ),
        value,
        unit,
        source,
        kind,
    )


def compatibility_quantity(
    identity,
    name,
    units,
    start,
    end,
    value,
    source,
    raw,
    minimum=None,
    maximum=None,
):
    line = {
        "id": identity,
        "kind": "quantity",
        "recordVersion": 1,
        "schemaVersion": 1,
        "sourceRecord": {
            "id": identity,
            "store": "healthAutoExport",
            "type": name,
        },
        "startDate": start,
        "endDate": end,
        "quantity": {"value": value, "unit": units},
        "type": name,
        "compatibilityRaw": raw,
    }
    if source:
        line["source"] = {"name": source}
    if minimum is not None:
        line["minimum"] = minimum
    if maximum is not None:
        line["maximum"] = maximum
    return line


def add_compatible_line(lines, identities, line):
    identity = line["id"]
    if identity in identities:
        raise PartialBatch(
            "compatible payload contains records with indistinguishable identities"
        )
    identities.add(identity)
    lines.append(line)


def finite_number(value, field, context):
    number = value.get(field)
    if (
        isinstance(number, bool)
        or not isinstance(number, (int, float))
        or not math.isfinite(number)
    ):
        raise PartialBatch(f"{context} has invalid {field}")
    return float(number)


class ReceiverHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    block_on_close = True
    allow_reuse_address = True

    def __init__(
        self,
        address,
        handler,
        *,
        address_family,
        tls_context,
        tls_timeout,
        max_connections,
    ):
        self.address_family = address_family
        self.tls_context = tls_context
        self.tls_timeout = tls_timeout
        self.connection_slots = threading.BoundedSemaphore(max_connections)
        super().__init__(address, handler)

    def process_request(self, request, client_address):
        if not self.connection_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.connection_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        wrapped = request
        try:
            if self.tls_context is not None:
                request.settimeout(self.tls_timeout)
                wrapped = self.tls_context.wrap_socket(
                    request,
                    server_side=True,
                )
                wrapped.settimeout(None)
            super().process_request_thread(wrapped, client_address)
        except (OSError, ssl.SSLError):
            self.shutdown_request(wrapped)
        finally:
            self.connection_slots.release()


def create_receiver_server(args, db=None):
    tls_context, address_family = serve_security(
        args.host,
        args.cert,
        args.key,
    )
    database = db or connect(args.database)
    db_lock = threading.RLock()
    header_timeout = getattr(args, "header_timeout", DEFAULT_HEADER_TIMEOUT)
    body_timeout = getattr(args, "body_timeout", DEFAULT_BODY_TIMEOUT)
    tls_timeout = getattr(args, "tls_timeout", DEFAULT_TLS_TIMEOUT)
    max_connections = getattr(
        args,
        "max_connections",
        DEFAULT_MAX_CONNECTIONS,
    )

    class Handler(BaseHTTPRequestHandler):
        def handle(self):
            self._header_timer = threading.Timer(
                header_timeout,
                self.close_for_timeout,
            )
            self._header_timer.daemon = True
            self._header_timer.start()
            try:
                super().handle()
            finally:
                self._header_timer.cancel()

        def do_POST(self):
            self._header_timer.cancel()
            if not args.allow_unauthenticated:
                supplied = self.headers.get("Authorization", "")
                if not hmac.compare_digest(
                    supplied.encode("utf-8"),
                    args.token.encode("utf-8"),
                ):
                    return self.finish_with(401, {"error": "unauthorized"})
            if self.headers.get("Transfer-Encoding"):
                return self.finish_with(
                    400,
                    {"error": "Transfer-Encoding is not supported"},
                )

            lengths = self.headers.get_all("Content-Length", [])
            if len(lengths) != 1:
                return self.finish_with(
                    400,
                    {"error": "exactly one Content-Length is required"},
                )
            try:
                length = parse_content_length(lengths[0])
            except PartialBatch as error:
                return self.finish_with(400, {"error": str(error)})
            if length > MAX_NETWORK_BODY_BYTES:
                return self.finish_with(
                    413,
                    {"error": "payload exceeds the pending import memory budget"},
                )
            key = self.headers.get("Idempotency-Key")
            timer = threading.Timer(body_timeout, self.close_for_timeout)
            timer.daemon = True
            timer.start()
            try:
                with tempfile.TemporaryFile() as body:
                    remaining = length
                    while remaining:
                        chunk = self.rfile.read(min(remaining, 64 * 1_024))
                        if not chunk:
                            return
                        body.write(chunk)
                        remaining -= len(chunk)
                    timer.cancel()
                    body.seek(0)
                    try:
                        with db_lock:
                            stored, deleted, duplicate = ingest_seekable_stream(
                                database,
                                body,
                                length,
                                key,
                            )
                    except PartialBatch as error:
                        return self.finish_with(400, {"error": str(error)})
                    except Exception as error:  # noqa: BLE001 - report, never crash
                        return self.finish_with(500, {"error": str(error)})
            finally:
                timer.cancel()

            if duplicate:
                print(f"batch {key[:8] if key else '?'} already stored")
            else:
                print(f"stored {stored}, deleted {deleted}")
            self.finish_with(200, {
                "stored": stored, "deleted": deleted, "duplicate": duplicate,
            })

        def close_for_timeout(self):
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        def finish_with(self, code, body):
            encoded = json.dumps(body).encode()
            try:
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
            except OSError:
                self.close_connection = True

        def log_message(self, *_):
            pass

    server = ReceiverHTTPServer(
        (args.host, args.port),
        Handler,
        address_family=address_family,
        tls_context=tls_context,
        tls_timeout=tls_timeout,
        max_connections=max_connections,
    )
    server.database = database
    return server


def serve(args):
    server = create_receiver_server(args)
    scheme = "https" if server.tls_context is not None else "http"
    display_host = f"[{args.host}]" if ":" in args.host else args.host
    print(f"Hozz receiver listening on {scheme}://{display_host}:{args.port}")
    print(f"Database: {os.path.abspath(args.database)}")
    if args.allow_unauthenticated:
        print("Unauthenticated access was explicitly enabled.")
    try:
        server.serve_forever()
    finally:
        server.server_close()
        server.database.close()


def serve_security(host, certificate, key):
    if bool(certificate) != bool(key):
        raise ValueError("--cert and --key must be provided together")
    try:
        address = ipaddress.ip_address(host)
    except ValueError as error:
        if host != "localhost":
            raise ValueError("serve host must be an IP literal or localhost") from error
        address = ipaddress.ip_address("127.0.0.1")
    family = socket.AF_INET6 if address.version == 6 else socket.AF_INET
    if certificate is None:
        if not address.is_loopback:
            raise ValueError(
                "plaintext serving is restricted to loopback; configure --cert and --key"
            )
        return None, family
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=certificate, keyfile=key)
    return context, family


RELIABLE_CHANGE_TIME_FILESYSTEMS = frozenset({"apfs"})
_FILESYSTEM_TYPE_CACHE = {}


def parse_darwin_mounts(output):
    mounts = []
    for line in output.splitlines():
        location, separator, options = line.rpartition(" (")
        if not separator or not options.endswith(")"):
            continue
        _, separator, mount_point = location.rpartition(" on ")
        if not separator:
            continue
        filesystem = options[:-1].split(",", 1)[0].strip().lower()
        if filesystem:
            mounts.append((Path(mount_point), filesystem))
    return tuple(mounts)


def darwin_mounts():
    try:
        result = subprocess.run(
            ["/sbin/mount"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return ()
    if result.returncode != 0:
        return ()
    return parse_darwin_mounts(result.stdout)


def filesystem_type_from_mounts(path, mounts, stat_function=os.stat):
    try:
        target_device = stat_function(path).st_dev
    except OSError:
        return None
    matches = set()
    for mount_point, filesystem in mounts:
        try:
            mount_device = stat_function(mount_point).st_dev
        except OSError:
            continue
        if mount_device == target_device:
            matches.add(filesystem)
    return next(iter(matches)) if len(matches) == 1 else None


def filesystem_type(path):
    if sys.platform == "darwin":
        try:
            device = path.stat().st_dev
        except OSError:
            return None
        cache_key = ("darwin", device)
        if cache_key not in _FILESYSTEM_TYPE_CACHE:
            _FILESYSTEM_TYPE_CACHE[cache_key] = filesystem_type_from_mounts(
                path,
                darwin_mounts(),
            )
        return _FILESYSTEM_TYPE_CACHE[cache_key]
    statvfs = getattr(os, "statvfs", None)
    if statvfs is None:
        return None
    try:
        name = getattr(statvfs(path), "f_fstypename", None)
    except OSError:
        return None
    if isinstance(name, bytes):
        name = name.decode("ascii", errors="ignore")
    return name.lower() if isinstance(name, str) and name else None


def file_change_time_is_reliable(path):
    return filesystem_type(path) in RELIABLE_CHANGE_TIME_FILESYSTEMS


def cached_file_failure_is_active(
    name,
    key,
    deterministic_failures,
    transient_failures,
):
    if deterministic_failures.get(name) == key:
        return True
    transient = transient_failures.get(name)
    if (
        transient is not None
        and transient[0] == key
        and time.monotonic() < transient[1]
    ):
        return True
    if deterministic_failures.get(name) != key:
        deterministic_failures.pop(name, None)
    if transient is not None and transient[0] != key:
        transient_failures.pop(name, None)
    return False


def file_generation_was_ingested(db, name, generation):
    return db.execute(
        """
        SELECT 1 FROM ingested_files
        WHERE name = ? AND device = ? AND inode = ?
          AND size = ? AND mtime_ns = ? AND ctime_ns = ?
          AND digest IS NOT NULL
        """,
        (name, *generation),
    ).fetchone() is not None


def file_digest_was_ingested(db, name, digest):
    return db.execute(
        """
        SELECT 1 FROM ingested_files
        WHERE name = ? AND digest = ?
        """,
        (name, digest),
    ).fetchone() is not None


def watch(args):
    """Import files Hozz drops into a synced folder."""
    db = connect(args.database)
    folder = Path(args.folder).expanduser()
    deterministic_failures = {}
    transient_failures = {}
    print(f"Watching {folder}")
    print(f"Database: {os.path.abspath(args.database)}")

    while True:
        for path in sorted(folder.glob("hozz-*")):
            try:
                generation = validated_file_snapshot(path.stat())
            except PartialBatch as error:
                print(f"skipped {path.name}: {error}")
                continue
            except OSError:
                continue
            reliable_change_time = file_change_time_is_reliable(path)
            failure_key = generation if reliable_change_time else None
            if failure_key is not None and cached_file_failure_is_active(
                path.name,
                failure_key,
                deterministic_failures,
                transient_failures,
            ):
                continue
            try:
                if reliable_change_time and file_generation_was_ingested(
                    db,
                    path.name,
                    generation,
                ):
                    continue
                spool_directory = snapshot_spool_directory(db, path)
                with open_hashed_file(
                    path,
                    generation,
                    spool_directory,
                    capture=reliable_change_time,
                ) as prepared:
                    captured, source, snapshot, file_batch_key, digest = prepared
                    if not reliable_change_time:
                        failure_key = (generation, digest)
                        if cached_file_failure_is_active(
                            path.name,
                            failure_key,
                            deterministic_failures,
                            transient_failures,
                        ):
                            continue
                        if file_digest_was_ingested(db, path.name, digest):
                            continue
                        with captured_file_snapshot(
                            source,
                            snapshot,
                            spool_directory,
                            expected_digest=digest,
                        ) as immutable:
                            captured = immutable[0]
                            verify_file_snapshot(path, source, snapshot)
                            stored, deleted = ingest_hashed_file(
                                db,
                                path,
                                captured,
                                source,
                                snapshot,
                                file_batch_key,
                                digest,
                                path.name,
                            )
                    else:
                        stored, deleted = ingest_hashed_file(
                            db,
                            path,
                            captured,
                            source,
                            snapshot,
                            file_batch_key,
                            digest,
                            path.name,
                        )
            except PartialBatch as error:
                if failure_key is not None:
                    deterministic_failures[path.name] = failure_key
                print(f"skipped {path.name}: {error}")
                continue
            except Exception as error:  # noqa: BLE001
                if failure_key is None:
                    print(f"skipped {path.name}: {error}")
                    continue
                previous = transient_failures.get(path.name)
                delay = (
                    min(previous[2] * 2, 60.0)
                    if previous is not None and previous[0] == failure_key
                    else max(float(args.interval), 1.0)
                )
                transient_failures[path.name] = (
                    failure_key,
                    time.monotonic() + delay,
                    delay,
                )
                print(f"skipped {path.name}: {error}")
                continue
            deterministic_failures.pop(path.name, None)
            transient_failures.pop(path.name, None)
            print(f"{path.name}: stored {stored}, deleted {deleted}")

        if args.once:
            db.close()
            return
        time.sleep(args.interval)


def ingest_file(db, path, watch_receipt_name=None):
    """A ZIP from a full export, or a plain batch file."""
    with open_hashed_file(
        path,
        spool_directory=snapshot_spool_directory(db, path),
    ) as prepared:
        captured, source, initial, file_batch_key, digest = prepared
        return ingest_hashed_file(
            db,
            path,
            captured,
            source,
            initial,
            file_batch_key,
            digest,
            watch_receipt_name,
        )


def ingest_hashed_file(
    db,
    path,
    captured,
    source,
    initial,
    file_batch_key,
    digest,
    watch_receipt_name,
):
    try:
        legacy_scope = legacy_file_receipt_scope(
            db,
            path.name,
            initial,
            digest,
        )
        legacy_receipt = legacy_file_receipt(db, path.name)
        repair_legacy_receipt = (
            legacy_scope is not None
            and legacy_receipt is not None
            and legacy_scope == legacy_receipt[0]
            and legacy_receipt[3] < 0
        )
        if (
            legacy_scope is None
            and legacy_receipt is not None
            and legacy_receipt[3] >= 0
            and file_matches_legacy_receipt(
                db,
                path,
                captured,
                source,
                initial,
                legacy_receipt[0],
            )
        ):
            copy_batch_receipt(
                db,
                legacy_receipt[0],
                file_batch_key,
            )
            verify_file_content(path, source, initial, digest)
            record_file_receipt(
                db,
                watch_receipt_name,
                initial,
                digest,
            )
            db.commit()
            return 0, 0
        if path.suffix == ".zip":
            if not repair_legacy_receipt:
                return ingest_zip_stream(
                    db,
                    path,
                    captured,
                    initial,
                    file_batch_key,
                    watch_receipt_name,
                    legacy_scope,
                    verification_source=source,
                    file_digest=digest,
                )
            stored, deleted = ingest_zip_stream(
                db,
                path,
                captured,
                initial,
                legacy_scope,
                None,
                legacy_scope,
                verification_source=source,
                file_digest=digest,
                commit=False,
            )
            copy_batch_receipt(db, legacy_scope, file_batch_key)
            record_file_receipt(
                db,
                watch_receipt_name,
                initial,
                digest,
            )
            db.commit()
            return stored, deleted

        file_size = initial[2]
        stored, deleted, _ = ingest_seekable_stream(
            db,
            captured,
            file_size,
            legacy_scope if repair_legacy_receipt else file_batch_key,
            commit=False,
            run_scope_key=legacy_scope,
            replay_run_occurrences=legacy_scope is not None,
        )
        verify_file_content(path, source, initial, digest)
        if repair_legacy_receipt:
            copy_batch_receipt(db, legacy_scope, file_batch_key)
        record_file_receipt(
            db,
            watch_receipt_name,
            initial,
            digest,
        )
        db.commit()
        return stored, deleted
    except Exception:
        db.rollback()
        raise


def ingest_zip_stream(
    db,
    path,
    source,
    initial,
    file_batch_key,
    watch_receipt_name,
    legacy_scope,
    verification_source=None,
    file_digest=None,
    commit=True,
):
    stored = deleted = canonical_count = line_count = 0
    preflight_zip_entry_count_stream(source)
    source.seek(0)
    with zipfile.ZipFile(source) as archive:
        infos = archive.infolist()
        validate_zip_entries(infos)
        manifests = [
            info for info in infos
            if info.filename == "hozz-manifest.json"
        ]
        if len(manifests) > 1:
            raise PartialBatch("archive contains more than one manifest")
        manifest = None
        manifest_info = None
        if manifests:
            manifest_info = manifests[0]
            if manifest_info.file_size > MAX_MANIFEST_BYTES:
                raise PartialBatch("archive manifest is too large")
            manifest = parse_json(
                decode_utf8(
                    archive.read(manifest_info),
                    "archive manifest",
                )
            )
            validate_archive_manifest(manifest)
            ndjson_infos = [
                info for info in infos
                if info.filename.endswith(".ndjson")
            ]
            if (
                len(ndjson_infos) != 1
                or ndjson_infos[0].filename != manifest["recordsEntry"]
            ):
                raise PartialBatch(
                    "archive must contain only its declared NDJSON stream"
                )
            record_infos = ndjson_infos
        else:
            record_infos = [
                info for info in infos
                if info.filename.endswith(".ndjson")
            ]
            if len(record_infos) != 1:
                raise PartialBatch(
                    "legacy archive must contain one NDJSON stream"
                )

        record_info = record_infos[0]
        for info in infos:
            if info.is_dir() or info == manifest_info:
                continue
            if info != record_info:
                drain_zip_entry(archive, info)

        for info in record_infos:
            def lines():
                nonlocal line_count
                with archive.open(info) as stream:
                    while True:
                        raw = stream.readline(MAX_RECORD_BYTES + 2)
                        if not raw:
                            return
                        content = raw[:-1] if raw.endswith(b"\n") else raw
                        if content.endswith(b"\r"):
                            content = content[:-1]
                        if len(content) > MAX_RECORD_BYTES:
                            raise PartialBatch(
                                "archive record exceeds the byte limit"
                            )
                        line = decode_utf8(raw, "archive record")
                        if line.strip():
                            line_count += 1
                            if line_count > MAX_RECORD_LINES:
                                raise PartialBatch(
                                    "archive contains too many records"
                                )
                        yield line

            added, removed, duplicate, read = _ingest_lines(
                db,
                lines(),
                batch_key=file_batch_key,
                strict_v1=manifest is not None,
                run_scope_key=legacy_scope,
                replay_run_occurrences=legacy_scope is not None,
            )
            stored += added
            deleted += removed
            canonical_count += read
        if (
            manifest is not None
            and manifest.get("recordCount") is not None
            and not duplicate
            and canonical_count != manifest["recordCount"]
        ):
            raise PartialBatch(
                "archive record count does not match its manifest"
            )
        verification = verification_source or source
        if file_digest is None:
            verify_file_snapshot(path, verification, initial)
        else:
            verify_file_content(path, verification, initial, file_digest)
        if commit:
            record_file_receipt(
                db,
                watch_receipt_name,
                initial,
                file_digest,
            )
            db.commit()
        return stored, deleted


def file_snapshot(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def validated_file_snapshot(metadata):
    if not stat.S_ISREG(metadata.st_mode):
        raise PartialBatch("folder candidate is not a regular file")
    snapshot = file_snapshot(metadata)
    if snapshot[2] > MAX_INFLATED_BYTES:
        raise PartialBatch("file exceeds the import byte limit")
    return snapshot


@contextmanager
def open_hashed_file(
    path,
    expected_snapshot=None,
    spool_directory=None,
    capture=True,
):
    if expected_snapshot is None:
        try:
            path_metadata = path.stat()
        except OSError as error:
            raise TransientFileError(
                "file could not be inspected before ingestion"
            ) from error
        path_snapshot = validated_file_snapshot(path_metadata)
    else:
        path_snapshot = expected_snapshot
    try:
        stream = path.open("rb", buffering=0)
    except OSError as error:
        raise TransientFileError(
            "file could not be opened for ingestion"
        ) from error
    with stream:
        snapshot = validated_file_snapshot(os.fstat(stream.fileno()))
        if snapshot != path_snapshot:
            raise PartialBatch("file changed before hashing")
        if capture:
            with captured_file_snapshot(
                stream,
                snapshot,
                spool_directory,
            ) as immutable:
                captured, key, digest = immutable
                verify_file_snapshot(path, stream, snapshot)
                yield captured, stream, snapshot, key, digest
        else:
            key = file_content_key(stream, snapshot)
            verify_file_snapshot(path, stream, snapshot)
            yield None, stream, snapshot, key, key[len("file:v3:"):]


@contextmanager
def captured_file_snapshot(
    source,
    initial,
    spool_directory,
    expected_digest=None,
):
    with tempfile.SpooledTemporaryFile(
        max_size=MAX_SNAPSHOT_MEMORY_BYTES,
        mode="w+b",
        dir=spool_directory,
        prefix=".hozz-snapshot-",
    ) as captured:
        key = file_content_key(source, initial, captured)
        digest = key[len("file:v3:"):]
        if expected_digest is not None and digest != expected_digest:
            raise PartialBatch("file content changed while capturing snapshot")
        captured.seek(0)
        yield captured, key, digest


def file_content_key(stream, initial, captured=None):
    digest = hashlib.sha256()
    remaining = initial[2]
    try:
        if captured is not None:
            captured.seek(0)
            captured.truncate()
        stream.seek(0)
        while remaining:
            chunk = stream.read(min(64 * 1_024, remaining))
            if not chunk:
                raise PartialBatch("file changed during hashing")
            if len(chunk) > remaining:
                raise PartialBatch("file changed during hashing")
            digest.update(chunk)
            if captured is not None:
                captured.write(chunk)
            remaining -= len(chunk)
        if stream.read(1):
            raise PartialBatch("file changed during hashing")
        if file_snapshot(os.fstat(stream.fileno())) != initial:
            raise PartialBatch("file changed during hashing")
        if captured is not None:
            captured.seek(0)
        return f"file:v3:{digest.hexdigest()}"
    finally:
        stream.seek(0)


def snapshot_spool_directory(db, path):
    for _, name, filename in db.execute("PRAGMA database_list"):
        if name == "main" and filename:
            return str(Path(filename).resolve().parent)
    return str(path.resolve().parent)


def legacy_file_receipt_scope(db, name, snapshot, digest):
    receipt = legacy_file_receipt(db, name)
    if receipt:
        exact_file = db.execute(
            """
            SELECT 1 FROM ingested_files
            WHERE name = ? AND device = ? AND inode = ?
              AND size = ? AND mtime_ns = ? AND ctime_ns = ? AND digest = ?
            """,
            (name, *snapshot, digest),
        ).fetchone()
        if exact_file:
            return receipt[0]
        migrated_filename_receipt = db.execute(
            """
            SELECT 1 FROM ingested_files
            WHERE name = ? AND digest IS NULL
            """,
            (name,),
        ).fetchone()
        if receipt[3] < 0 and migrated_filename_receipt:
            return receipt[0]
    return None


def legacy_file_receipt(db, name):
    for legacy_key in (f"file:{name}", name):
        receipt = db.execute(
            """
            SELECT received_at, records, deletions FROM batches
            WHERE key = ?
            """,
            (legacy_key,),
        ).fetchone()
        if receipt:
            return (legacy_key, *receipt)
    return None


def copy_batch_receipt(db, source_key, destination_key):
    receipt = db.execute(
        """
        SELECT received_at, records, deletions FROM batches
        WHERE key = ?
        """,
        (source_key,),
    ).fetchone()
    if receipt is None or receipt[2] < 0:
        raise RuntimeError("legacy batch receipt was not repaired")
    db.execute(
        """
        INSERT OR IGNORE INTO batches
            (key, received_at, records, deletions)
        VALUES (?, ?, ?, ?)
        """,
        (destination_key, *receipt),
    )


def quote_sqlite_identifier(identifier):
    return '"' + identifier.replace('"', '""') + '"'


@contextmanager
def track_durable_mutations(db):
    tracker = quote_sqlite_identifier(DURABLE_MUTATION_TRACKER)
    db.execute(f"DROP TABLE IF EXISTS temp.{tracker}")
    db.execute(
        f"""
        CREATE TEMP TABLE {tracker} (
            table_name TEXT NOT NULL,
            operation TEXT NOT NULL,
            mutations INTEGER NOT NULL,
            PRIMARY KEY (table_name, operation)
        ) WITHOUT ROWID
        """
    )
    trigger_names = []
    try:
        # TEMP triggers on main tables observe durable row changes without
        # counting the receiver's TEMP validation and reconciliation tables.
        for table_index, table_name in enumerate(DURABLE_RECEIVER_TABLES):
            quoted_table = quote_sqlite_identifier(table_name)
            table_literal = table_name.replace("'", "''")
            for operation in ("INSERT", "UPDATE", "DELETE"):
                trigger_name = (
                    f"receiver_track_durable_{table_index}_{operation.lower()}"
                )
                trigger_names.append(trigger_name)
                quoted_trigger = quote_sqlite_identifier(trigger_name)
                db.execute(
                    f"""
                    CREATE TEMP TRIGGER {quoted_trigger}
                    AFTER {operation} ON main.{quoted_table}
                    BEGIN
                        INSERT INTO {tracker}
                            (table_name, operation, mutations)
                        VALUES ('{table_literal}', '{operation.lower()}', 1)
                        ON CONFLICT(table_name, operation) DO UPDATE SET
                            mutations = mutations + 1;
                    END
                    """
                )
        yield
    finally:
        for trigger_name in trigger_names:
            db.execute(
                "DROP TRIGGER IF EXISTS temp."
                + quote_sqlite_identifier(trigger_name)
            )
        db.execute(f"DROP TABLE IF EXISTS temp.{tracker}")


def durable_mutations(db):
    return tuple(
        db.execute(
            f"""
            SELECT table_name, operation, mutations
            FROM temp.{quote_sqlite_identifier(DURABLE_MUTATION_TRACKER)}
            WHERE mutations > 0
            ORDER BY table_name, operation
            """
        )
    )


def file_matches_legacy_receipt(
    db,
    path,
    captured,
    verification_source,
    initial,
    legacy_key,
):
    savepoint = "legacy_file_probe"
    try:
        with track_durable_mutations(db):
            db.execute(f"SAVEPOINT {savepoint}")
            try:
                if path.suffix == ".zip":
                    ingest_zip_stream(
                        db,
                        path,
                        captured,
                        initial,
                        None,
                        None,
                        legacy_key,
                        verification_source=verification_source,
                        commit=False,
                    )
                else:
                    ingest_seekable_stream(
                        db,
                        captured,
                        initial[2],
                        batch_key=None,
                        commit=False,
                        run_scope_key=legacy_key,
                        replay_run_occurrences=True,
                    )
                unchanged = not durable_mutations(db)
            finally:
                db.execute(f"ROLLBACK TO {savepoint}")
                db.execute(f"RELEASE {savepoint}")
            return unchanged
    except Exception:  # noqa: BLE001 - a failed probe falls back to normal ingest
        db.rollback()
    finally:
        captured.seek(0)
    return False


def verify_file_snapshot(path, stream, initial):
    descriptor = file_snapshot(os.fstat(stream.fileno()))
    try:
        current_path = file_snapshot(path.stat())
    except OSError as error:
        raise TransientFileError("file could not be verified after ingestion") from error
    if descriptor != initial or current_path != initial:
        raise PartialBatch("file changed during ingestion")


def verify_file_content(path, stream, initial, expected_digest):
    verify_file_snapshot(path, stream, initial)
    try:
        current_key = file_content_key(stream, initial)
    except PartialBatch as error:
        raise PartialBatch("file content changed during ingestion") from error
    current_digest = current_key[len("file:v3:"):]
    if current_digest != expected_digest:
        raise PartialBatch("file content changed during ingestion")
    verify_file_snapshot(path, stream, initial)


def record_file_receipt(db, name, snapshot, digest=None):
    if name is None:
        return
    db.execute(
        """
        INSERT OR REPLACE INTO ingested_files
            (name, ingested_at, device, inode, size, mtime_ns, ctime_ns, digest)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (name, time.time(), *snapshot, digest),
    )


def decode_utf8(payload, field):
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PartialBatch(f"{field} is not valid UTF-8") from error


def drain_zip_entry(archive, info):
    read = 0
    with archive.open(info) as stream:
        while True:
            chunk = stream.read(64 * 1_024)
            if not chunk:
                break
            read += len(chunk)
            if read > info.file_size:
                raise PartialBatch(
                    f"archive entry {info.filename} exceeds its declared size"
                )
    if read != info.file_size:
        raise PartialBatch(
            f"archive entry {info.filename} does not match its declared size"
        )


def preflight_zip_entry_count(path):
    with path.open("rb") as stream:
        preflight_zip_entry_count_stream(stream)


def preflight_zip_entry_count_stream(stream):
    original = stream.tell()
    try:
        stream.seek(0, os.SEEK_END)
        file_size = stream.tell()
        tail_size = min(file_size, 65_557)
        tail_offset = file_size - tail_size
        stream.seek(tail_offset)
        tail = stream.read(tail_size)
        eocd_index = find_exact_eocd(tail, tail_offset, file_size)
        if eocd_index is None:
            raise PartialBatch("archive has no valid ZIP directory")
        eocd_offset = tail_offset + eocd_index
        disk_number, directory_disk, disk_entries, entries = struct.unpack_from(
            "<HHHH",
            tail,
            eocd_index + 4,
        )
        directory_size = struct.unpack_from("<I", tail, eocd_index + 12)[0]
        directory_offset = struct.unpack_from("<I", tail, eocd_index + 16)[0]
        zip64 = read_zip64_directory(stream, eocd_offset, file_size)
        if zip64 is not None:
            entries, directory_size, directory_offset, directory_end = zip64
        elif (
            entries == 0xFFFF
            or directory_size == 0xFFFFFFFF
            or directory_offset == 0xFFFFFFFF
        ):
            raise PartialBatch("archive has no valid ZIP64 directory")
        else:
            if disk_number != 0 or directory_disk != 0:
                raise PartialBatch("multi-disk ZIP archives are not supported")
            if disk_entries != entries:
                raise PartialBatch("archive ZIP directory count is inconsistent")
            prefix_size = eocd_offset - directory_size - directory_offset
            if prefix_size < 0:
                raise PartialBatch("archive ZIP directory is out of bounds")
            directory_offset += prefix_size
            directory_end = eocd_offset
        if directory_size > MAX_ZIP_DIRECTORY_BYTES:
            raise PartialBatch("archive ZIP directory exceeds the byte limit")
        if directory_offset + directory_size != directory_end:
            raise PartialBatch("archive ZIP directory is out of bounds")
        parsed_entries = count_central_directory_entries(
            stream,
            directory_offset,
            directory_size,
            file_size,
        )
        if entries != parsed_entries:
            raise PartialBatch("archive ZIP directory count is inconsistent")
        if parsed_entries > MAX_ZIP_ENTRIES:
            raise PartialBatch("archive contains too many entries")
    finally:
        stream.seek(original)


def find_exact_eocd(tail, tail_offset, file_size):
    if (
        len(tail) >= 22
        and tail[-22:-18] == b"PK\x05\x06"
        and tail[-2:] == b"\0\0"
    ):
        return len(tail) - 22
    index = tail.rfind(b"PK\x05\x06")
    if index < 0 or len(tail) - index < 22:
        return None
    comment_length = struct.unpack_from("<H", tail, index + 20)[0]
    if tail_offset + index + 22 + comment_length != file_size:
        raise PartialBatch(
            "archive ZIP end record comment length is inconsistent"
        )
    return index


def read_zip64_directory(stream, eocd_offset, file_size):
    locator_offset = eocd_offset - 20
    if locator_offset < 0:
        return None
    stream.seek(locator_offset)
    locator = stream.read(20)
    if len(locator) != 20 or locator[:4] != b"PK\x06\x07":
        return None
    disk_number = struct.unpack_from("<I", locator, 4)[0]
    relative_offset = struct.unpack_from("<Q", locator, 8)[0]
    disk_count = struct.unpack_from("<I", locator, 16)[0]
    if disk_number != 0 or disk_count > 1:
        raise PartialBatch("multi-disk ZIP archives are not supported")

    expected_record_offset = locator_offset - 56
    if expected_record_offset < 0 or relative_offset > expected_record_offset:
        raise PartialBatch("archive has no valid ZIP64 directory")

    # Python 3.9 reads the record immediately before the locator, while newer
    # versions first follow the locator offset. Both views must describe the
    # same bounded central directory before either runtime may open the file.
    relative_candidate = read_zip64_directory_candidate(
        stream,
        relative_offset,
        56 + expected_record_offset - relative_offset,
        relative_offset,
        file_size,
    )
    if relative_offset == expected_record_offset:
        if relative_candidate is None:
            raise PartialBatch("archive has no valid ZIP64 directory")
        return relative_candidate

    preceding_candidate = read_zip64_directory_candidate(
        stream,
        expected_record_offset,
        56,
        relative_offset,
        file_size,
    )
    if relative_candidate is not None:
        if (
            preceding_candidate is None
            or relative_candidate[:3] != preceding_candidate[:3]
        ):
            raise PartialBatch(
                "archive ZIP64 directory differs across Python versions"
            )
        return relative_candidate
    if preceding_candidate is None:
        raise PartialBatch("archive has no valid ZIP64 directory")
    return preceding_candidate


def read_zip64_directory_candidate(
    stream,
    record_offset,
    record_size,
    relative_offset,
    file_size,
):
    stream.seek(record_offset)
    header = stream.read(56)
    if len(header) != 56 or header[:4] != b"PK\x06\x06":
        return None
    declared_size = struct.unpack_from("<Q", header, 4)[0] + 12
    if (
        declared_size != record_size
        or record_size > MAX_ZIP64_END_RECORD_BYTES
    ):
        raise PartialBatch("archive has no valid ZIP64 directory")
    disk_number = struct.unpack_from("<I", header, 16)[0]
    directory_disk = struct.unpack_from("<I", header, 20)[0]
    disk_entries = struct.unpack_from("<Q", header, 24)[0]
    entries = struct.unpack_from("<Q", header, 32)[0]
    directory_size = struct.unpack_from("<Q", header, 40)[0]
    directory_offset = struct.unpack_from("<Q", header, 48)[0]
    if disk_number != 0 or directory_disk != 0 or disk_entries != entries:
        raise PartialBatch("multi-disk ZIP archives are not supported")
    if directory_offset + directory_size != relative_offset:
        raise PartialBatch("archive ZIP64 directory is out of bounds")
    if directory_size > MAX_ZIP_DIRECTORY_BYTES:
        raise PartialBatch("archive ZIP directory exceeds the byte limit")
    resolved_offset = record_offset - directory_size
    if (
        resolved_offset < 0
        or resolved_offset > file_size
        or directory_size > file_size - resolved_offset
    ):
        raise PartialBatch("archive ZIP64 directory is out of bounds")
    if entries > MAX_ZIP_ENTRIES:
        raise PartialBatch("archive contains too many entries")
    return entries, directory_size, resolved_offset, record_offset


def count_central_directory_entries(stream, offset, length, file_size):
    if offset > file_size or length > file_size - offset:
        raise PartialBatch("archive ZIP directory is out of bounds")
    stream.seek(offset)
    consumed = 0
    entries = 0
    while consumed < length:
        if entries >= MAX_ZIP_ENTRIES + 1:
            return entries + 1
        header = stream.read(46)
        if len(header) != 46 or header[:4] != b"PK\x01\x02":
            raise PartialBatch("archive ZIP directory is malformed")
        flags, method = struct.unpack_from("<HH", header, 8)
        if flags & ZIP_ENCRYPTION_FLAGS:
            raise PartialBatch("archive contains an encrypted ZIP entry")
        if method not in SUPPORTED_ZIP_METHODS:
            raise PartialBatch("archive uses an unsupported compression method")
        filename_length, extra_length, comment_length = struct.unpack_from(
            "<HHH",
            header,
            28,
        )
        variable_length = filename_length + extra_length + comment_length
        consumed += 46 + variable_length
        if consumed > length:
            raise PartialBatch("archive ZIP directory is malformed")
        stream.seek(variable_length, os.SEEK_CUR)
        entries += 1
    if consumed != length:
        raise PartialBatch("archive ZIP directory is malformed")
    return entries


def validate_zip_entries(infos):
    if len(infos) > MAX_ZIP_ENTRIES:
        raise PartialBatch("archive contains too many entries")
    total_inflated = sum(info.file_size for info in infos)
    total_compressed = sum(info.compress_size for info in infos)
    if total_inflated > MAX_INFLATED_BYTES:
        raise PartialBatch("archive expands beyond the byte limit")
    for info in infos:
        if info.flag_bits & ZIP_ENCRYPTION_FLAGS:
            raise PartialBatch("archive contains an encrypted ZIP entry")
        if info.compress_type not in SUPPORTED_ZIP_METHODS:
            raise PartialBatch("archive uses an unsupported compression method")
        if (
            info.file_size
            > info.compress_size * MAX_ENTRY_COMPRESSION_RATIO
            + ENTRY_RATIO_SLACK_BYTES
        ):
            raise PartialBatch(
                f"archive entry {info.filename} has an unsafe compression ratio"
            )
    if (
        total_inflated
        > total_compressed * MAX_GLOBAL_COMPRESSION_RATIO
        + GLOBAL_RATIO_SLACK_BYTES
    ):
        raise PartialBatch("archive has an unsafe global compression ratio")


def validate_archive_manifest(manifest):
    if not isinstance(manifest, dict):
        raise PartialBatch("archive manifest is not an object")
    required = {
        "archiveId": str,
        "createdAt": str,
        "format": str,
        "recordSchema": str,
        "recordsEntry": str,
        "schemaVersion": int,
    }
    for field, expected_type in required.items():
        value = manifest.get(field)
        if (
            isinstance(value, bool)
            or not isinstance(value, expected_type)
            or isinstance(value, str) and not value
        ):
            raise PartialBatch(f"archive manifest has an invalid {field}")
    if manifest["schemaVersion"] != 1:
        raise PartialBatch("archive schema version is not supported")
    if manifest["format"] != "hozz-ndjson":
        raise PartialBatch("archive format is not supported")
    if manifest["recordSchema"] != "hozz/v1/canonical-record":
        raise PartialBatch("archive record schema is not supported")
    if "recordCount" in manifest:
        record_count = manifest["recordCount"]
        if (
            isinstance(record_count, bool)
            or not isinstance(record_count, int)
            or record_count < 0
        ):
            raise PartialBatch("archive record count is invalid")
    require_instant(manifest, "createdAt", "archive manifest")


def stats(args):
    db = connect(args.database)
    total = db.execute(
        "SELECT COUNT(*) FROM samples WHERE tombstone = 0"
    ).fetchone()[0]
    batches = db.execute("SELECT COUNT(*) FROM batches").fetchone()[0]
    print(f"{total:,} records from {batches:,} batches\n")

    rows = db.execute(
        "SELECT type, COUNT(*) c, MIN(start_date), MAX(start_date) "
        "FROM samples WHERE tombstone = 0 "
        "GROUP BY type ORDER BY c DESC LIMIT ?",
        (args.limit,),
    ).fetchall()
    if not rows:
        print("Nothing stored yet.")
        return
    width = max(len(row[0]) for row in rows)
    for kind, count, first, last in rows:
        span = f"{(first or '?')[:10]} to {(last or '?')[:10]}"
        print(f"{kind:<{width}}  {count:>9,}  {span}")


def build_argument_parser():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--database", default="health.db")
    sub = parser.add_subparsers(dest="command", required=True)

    serve_parser = sub.add_parser("serve", help="accept batches over HTTP")
    serve_parser.add_argument("--port", type=int, default=8765)
    serve_parser.add_argument("--host", "--bind", default="127.0.0.1")
    serve_parser.add_argument("--cert")
    serve_parser.add_argument("--key")
    serve_parser.add_argument(
        "--tls-timeout",
        type=positive_number,
        default=DEFAULT_TLS_TIMEOUT,
    )
    serve_parser.add_argument(
        "--header-timeout",
        type=positive_number,
        default=DEFAULT_HEADER_TIMEOUT,
    )
    serve_parser.add_argument(
        "--body-timeout",
        type=positive_number,
        default=DEFAULT_BODY_TIMEOUT,
    )
    serve_parser.add_argument(
        "--max-connections",
        type=positive_integer,
        default=DEFAULT_MAX_CONNECTIONS,
    )
    authentication = serve_parser.add_mutually_exclusive_group(required=True)
    authentication.add_argument(
        "--token",
        type=nonempty_token,
        help="require this Authorization value",
    )
    authentication.add_argument(
        "--allow-unauthenticated",
        action="store_true",
        help="explicitly accept unauthenticated network writes",
    )
    serve_parser.set_defaults(func=serve)

    watch_parser = sub.add_parser("watch", help="import from a synced folder")
    watch_parser.add_argument("folder")
    watch_parser.add_argument("--interval", type=float, default=10)
    watch_parser.add_argument("--once", action="store_true")
    watch_parser.set_defaults(func=watch)

    stats_parser = sub.add_parser("stats", help="summarise what is stored")
    stats_parser.add_argument("--limit", type=int, default=25)
    stats_parser.set_defaults(func=stats)
    return parser


def main():
    args = build_argument_parser().parse_args()
    try:
        args.func(args)
    except KeyboardInterrupt:
        print("\nStopped.")
        sys.exit(0)


if __name__ == "__main__":
    main()
