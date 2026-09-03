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
import json
import math
import os
import re
import sqlite3
import struct
import sys
import time
import uuid
import zipfile
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
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
MAX_INFLATED_BYTES = 64 * 1_024 * 1_024 * 1_024
MAX_RECORD_LINES = 50_000_000
MAX_RECORD_BYTES = 16 * 1_024 * 1_024
MAX_PENDING_BATCH_BYTES = 64 * 1_024 * 1_024
MAX_RUN_OCCURRENCE_KEYS = 100_000
MAX_MANIFEST_BYTES = 256 * 1_024
MAX_ENTRY_COMPRESSION_RATIO = 200
MAX_GLOBAL_COMPRESSION_RATIO = 100
ENTRY_RATIO_SLACK_BYTES = 8 * 1_024 * 1_024
GLOBAL_RATIO_SLACK_BYTES = 32 * 1_024 * 1_024
RFC3339 = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"
    r"(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"
)
SOURCE_NAMESPACE = re.compile(r"^[A-Za-z0-9._-]+$")

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
    source      TEXT,
    raw         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS samples_type_start ON samples(type, start_date);
CREATE INDEX IF NOT EXISTS samples_parent ON samples(parent_canonical_id);

CREATE TABLE IF NOT EXISTS batches (
    key         TEXT PRIMARY KEY,
    received_at REAL NOT NULL,
    records     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS ingested_files (
    name        TEXT PRIMARY KEY,
    ingested_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS archive_run_records (
    fingerprint TEXT NOT NULL,
    occurrence INTEGER NOT NULL,
    kind        TEXT NOT NULL,
    raw         TEXT NOT NULL,
    PRIMARY KEY (fingerprint, occurrence)
);
"""


def connect(path):
    db = sqlite3.connect(path, check_same_thread=False)
    try:
        columns = {
            row[1] for row in db.execute("PRAGMA table_info(samples)").fetchall()
        }
        legacy_exists = db.execute(
            "SELECT 1 FROM sqlite_master "
            "WHERE type = 'table' AND name = 'samples_legacy'"
        ).fetchone() is not None
        needs_migration = columns and "canonical_id" not in columns
        if needs_migration or legacy_exists:
            db.execute("BEGIN IMMEDIATE")
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


def ensure_current_columns(db):
    columns = {
        row[1] for row in db.execute("PRAGMA table_info(samples)")
    }
    if "resolution_canonical_id" not in columns:
        db.execute(
            "ALTER TABLE samples ADD COLUMN resolution_canonical_id TEXT"
        )
    restore_continuation_errors(db)
    reconcile_parent_tombstones(db)
    reconcile_encoding_errors(db)


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
                 source, raw)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
    restore_continuation_errors(db)
    reconcile_parent_tombstones(db)
    reconcile_encoding_errors(db)


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
    if isinstance(value, bool) or not isinstance(value, int):
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


def _ingest_lines(db, lines, batch_key=None, strict_v1=False):
    if batch_key:
        seen = db.execute(
            "SELECT 1 FROM batches WHERE key = ?", (batch_key,)
        ).fetchone()
        if seen:
            # Hozz resends a batch when a response was lost. The data is
            # already here, so acknowledging without storing it again is
            # exactly right.
            return 0, 0, True, 0

    stored = deleted = canonical_count = 0
    current_run = f"batch:{batch_key}" if batch_key else None
    occurrences = {}
    for index, line in enumerate(lines):
        line = line.strip()
        if not line:
            continue
        try:
            record = parse_json(line)
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
            stored_line = normalize_legacy_run_line(record)
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
                if batch_key:
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
            if strict_v1:
                raise PartialBatch(
                    f"line {index + 1} has no canonical identity"
                )
            continue
        canonical_count += 1
        canonical_id, source_id, parent_id, version = identity
        resolution_id = nonempty_text(record.get("resolutionCanonicalId"))
        tombstone = kind == "deletion" or record.get("deleted") is True
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
                 source, raw)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                quantity.get("value", record.get("value")),
                quantity.get("unit"),
                source.get("name"),
                line if isinstance(line, str) else line.decode(),
            ),
        )
        winner = db.execute(
            "SELECT record_version, tombstone FROM samples "
            "WHERE canonical_id = ?",
            (canonical_id,),
        ).fetchone()
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

    if batch_key:
        db.execute(
            "INSERT OR IGNORE INTO batches VALUES (?, ?, ?)",
            (batch_key, time.time(), stored),
        )
    restore_unresolved_continuation_errors(db)
    reconcile_encoding_errors(db)
    return stored, deleted, False, canonical_count


def reconcile_encoding_errors(db):
    db.execute(
        """
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
        """
    )


def restore_unresolved_continuation_errors(db):
    db.execute(
        """
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
    try:
        text = payload.decode("utf-8").strip()
    except UnicodeDecodeError as error:
        raise PartialBatch("payload is not valid UTF-8") from error
    if not text:
        return 0, 0, False

    if text.startswith("["):
        try:
            return ingest_lines(
                db,
                [json.dumps(item) for item in parse_json(text)],
                batch_key,
            )
        except (json.JSONDecodeError, ValueError):
            pass

    if text.startswith("{") and '"data"' in text[:200]:
        try:
            envelope = parse_json(text)
            return ingest_compatible(db, envelope, batch_key)
        except (json.JSONDecodeError, ValueError):
            pass

    return ingest_lines(db, text.splitlines(), batch_key)


def parse_content_length(value):
    try:
        length = int(value)
    except (TypeError, ValueError) as error:
        raise PartialBatch("Content-Length is not a nonnegative integer") from error
    if length < 0:
        raise PartialBatch("Content-Length is not a nonnegative integer")
    return length


def ingest_compatible(db, envelope, batch_key=None):
    """Flatten the Health Auto Export shaped payload into the same table."""
    lines = []
    data = envelope.get("data", {})
    for metric in data.get("metrics", []):
        name = metric.get("name", "unknown")
        units = metric.get("units")
        for point in metric.get("data", []):
            lines.append(json.dumps({
                "id": f"{name}:{point.get('date')}",
                "type": name,
                "kind": "quantity",
                "startDate": point.get("date"),
                "endDate": point.get("endDate", point.get("date")),
                "quantity": {"value": point.get("qty"), "unit": units},
                "source": {"name": point.get("source")},
            }))
    # Upserts from this envelope are keyed by name and date, because the format
    # carries no per-sample identifier. Deletions arrive with HealthKit's real
    # identifier, which would match nothing, so they are applied by the same
    # (type, date) pair the upserts used.
    deletions = [
        (deletion.get("name") or deletion.get("type"), deletion.get("date"))
        for deletion in data.get("deletions", [])
    ]
    try:
        stored, deleted, duplicate, _ = _ingest_lines(
            db, lines, batch_key
        )
        deletion_lines = []
        for name, date in deletions:
            if not name or not date:
                continue
            deletion_lines.append(json.dumps({
                "deleted": True,
                "id": f"{name}:{date}",
                "kind": "deletion",
                "schemaVersion": 1,
                "startDate": date,
                "endDate": date,
                "type": name,
            }))
        if deletion_lines:
            deletion_stored, deletion_count, _, _ = _ingest_lines(
                db,
                deletion_lines,
            )
            stored += deletion_stored
            deleted += deletion_count
        db.commit()
        return stored, deleted, duplicate
    except Exception:
        db.rollback()
        raise


def serve(args):
    db = connect(args.database)

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            if args.token:
                supplied = self.headers.get("Authorization", "")
                if supplied != args.token:
                    return self.finish_with(401, {"error": "unauthorized"})

            try:
                length = parse_content_length(
                    self.headers.get("Content-Length", 0)
                )
            except PartialBatch as error:
                return self.finish_with(400, {"error": str(error)})
            if length > MAX_PENDING_BATCH_BYTES:
                return self.finish_with(
                    413,
                    {"error": "payload exceeds the pending import memory budget"},
                )
            payload = self.rfile.read(length)
            key = self.headers.get("Idempotency-Key")

            # A socket read returns short at EOF, so a connection dropped
            # mid-post yields a truncated body. Storing part of it and
            # answering 200 would lose the rest permanently.
            if len(payload) != length:
                return self.finish_with(400, {"error": "incomplete body"})

            try:
                stored, deleted, duplicate = ingest_payload(db, payload, key)
            except PartialBatch as error:
                return self.finish_with(400, {"error": str(error)})
            except Exception as error:  # noqa: BLE001 - report, never crash
                return self.finish_with(500, {"error": str(error)})

            if duplicate:
                print(f"batch {key[:8] if key else '?'} already stored")
            else:
                print(f"stored {stored}, deleted {deleted}")
            self.finish_with(200, {
                "stored": stored, "deleted": deleted, "duplicate": duplicate,
            })

        def finish_with(self, code, body):
            encoded = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, *_):
            pass  # Access logs would record nothing useful and add noise.

    print(f"Hozz receiver listening on http://0.0.0.0:{args.port}")
    print(f"Database: {os.path.abspath(args.database)}")
    if not args.token:
        print("No token set. Anyone on your network can post to this.")
    HTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


def watch(args):
    """Import files Hozz drops into a synced folder."""
    db = connect(args.database)
    folder = Path(args.folder).expanduser()
    print(f"Watching {folder}")
    print(f"Database: {os.path.abspath(args.database)}")

    while True:
        for path in sorted(folder.glob("hozz-*")):
            done = db.execute(
                "SELECT 1 FROM ingested_files WHERE name = ?", (path.name,)
            ).fetchone()
            if done:
                continue
            try:
                stored, deleted = ingest_file(db, path)
            except Exception as error:  # noqa: BLE001
                print(f"skipped {path.name}: {error}")
                continue
            db.execute(
                "INSERT OR REPLACE INTO ingested_files VALUES (?, ?)",
                (path.name, time.time()),
            )
            db.commit()
            print(f"{path.name}: stored {stored}, deleted {deleted}")

        if args.once:
            return
        time.sleep(args.interval)


def ingest_file(db, path):
    """A ZIP from a full export, or a plain batch file."""
    file_batch_key = f"file:{path.name}"
    if path.suffix == ".zip":
        try:
            stored = deleted = canonical_count = line_count = 0
            preflight_zip_entry_count(path)
            with zipfile.ZipFile(path) as archive:
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
                                if len(raw.rstrip(b"\r\n")) > MAX_RECORD_BYTES:
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
            db.commit()
            return stored, deleted
        except Exception:
            db.rollback()
            raise

    file_size = path.stat().st_size
    if file_size > MAX_INFLATED_BYTES:
        raise PartialBatch("file exceeds the import byte limit")
    if file_size <= MAX_PENDING_BATCH_BYTES:
        stored, deleted, _ = ingest_payload(
            db,
            path.read_bytes(),
            batch_key=file_batch_key,
        )
        return stored, deleted
    try:
        line_count = 0

        def lines():
            nonlocal line_count
            with path.open("rb") as stream:
                while True:
                    raw = stream.readline(MAX_RECORD_BYTES + 2)
                    if not raw:
                        return
                    if len(raw.rstrip(b"\r\n")) > MAX_RECORD_BYTES:
                        raise PartialBatch(
                            "record exceeds the byte limit"
                        )
                    line = decode_utf8(raw, "record")
                    if line.strip():
                        line_count += 1
                        if line_count > MAX_RECORD_LINES:
                            raise PartialBatch("file contains too many records")
                    yield line

        stored, deleted, _, _ = _ingest_lines(
            db,
            lines(),
            batch_key=file_batch_key,
        )
        db.commit()
        return stored, deleted
    except Exception:
        db.rollback()
        raise


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
        stream.seek(0, os.SEEK_END)
        size = stream.tell()
        tail_size = min(size, 65_557)
        stream.seek(size - tail_size)
        tail = stream.read(tail_size)
        eocd_index = tail.rfind(b"PK\x05\x06")
        if eocd_index < 0 or len(tail) - eocd_index < 22:
            raise PartialBatch("archive has no valid ZIP directory")
        entries = struct.unpack_from("<H", tail, eocd_index + 10)[0]
        directory_size = struct.unpack_from("<I", tail, eocd_index + 12)[0]
        directory_offset = struct.unpack_from("<I", tail, eocd_index + 16)[0]
        if (
            entries == 0xFFFF
            or directory_size == 0xFFFFFFFF
            or directory_offset == 0xFFFFFFFF
        ):
            locator_index = tail.rfind(
                b"PK\x06\x07",
                max(0, eocd_index - 1_024),
                eocd_index,
            )
            if locator_index < 0 or len(tail) - locator_index < 20:
                raise PartialBatch("archive has no valid ZIP64 directory")
            zip64_offset = struct.unpack_from("<Q", tail, locator_index + 8)[0]
            stream.seek(zip64_offset)
            header = stream.read(56)
            if len(header) < 56 or header[:4] != b"PK\x06\x06":
                raise PartialBatch("archive has no valid ZIP64 directory")
            entries = struct.unpack_from("<Q", header, 32)[0]
            directory_size = struct.unpack_from("<Q", header, 40)[0]
            directory_offset = struct.unpack_from("<Q", header, 48)[0]
        parsed_entries = count_central_directory_entries(
            stream,
            directory_offset,
            directory_size,
            size,
        )
        if entries != parsed_entries:
            raise PartialBatch("archive ZIP directory count is inconsistent")
        if parsed_entries > MAX_ZIP_ENTRIES:
            raise PartialBatch("archive contains too many entries")


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


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--database", default="health.db")
    sub = parser.add_subparsers(dest="command", required=True)

    serve_parser = sub.add_parser("serve", help="accept batches over HTTP")
    serve_parser.add_argument("--port", type=int, default=8765)
    serve_parser.add_argument("--token", help="require this Authorization value")
    serve_parser.set_defaults(func=serve)

    watch_parser = sub.add_parser("watch", help="import from a synced folder")
    watch_parser.add_argument("folder")
    watch_parser.add_argument("--interval", type=float, default=10)
    watch_parser.add_argument("--once", action="store_true")
    watch_parser.set_defaults(func=watch)

    stats_parser = sub.add_parser("stats", help="summarise what is stored")
    stats_parser.add_argument("--limit", type=int, default=25)
    stats_parser.set_defaults(func=stats)

    args = parser.parse_args()
    try:
        args.func(args)
    except KeyboardInterrupt:
        print("\nStopped.")
        sys.exit(0)


if __name__ == "__main__":
    main()
