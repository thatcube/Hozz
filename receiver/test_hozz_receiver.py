import contextlib
import http.client
import io
import json
import os
import sqlite3
import socket
import struct
import tempfile
import threading
import time
import tracemalloc
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import receiver.hozz_receiver as receiver
from receiver.hozz_receiver import (
    PartialBatch,
    connect,
    encoding_failure_id,
    ingest_file,
    ingest_compatible,
    ingest_lines,
)


ROOT = Path(__file__).resolve().parents[1]


class CanonicalIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.database = Path(self.directory.name) / "receiver.sqlite"
        self.db = connect(self.database)
        vectors = json.loads(
            (
                ROOT
                / "schema/hozz/v1/fixtures/identity-vectors.json"
            ).read_text()
        )
        self.vector = vectors["encodingFailure"]
        self.series_vector = vectors["seriesCompletion"]

    def tearDown(self):
        self.db.close()
        self.directory.cleanup()

    def error(self):
        source_id = self.vector["sourceRecordId"]
        return json.dumps({
            "id": self.vector["recordId"],
            "kind": "sampleEncodingError",
            "message": "fixture",
            "parentCanonicalId": f"apple.healthkit:{source_id}",
            "schemaVersion": 1,
            "sourceRecord": {
                "id": source_id,
                "store": "apple.healthkit",
                "type": self.vector["sourceType"],
            },
            "type": self.vector["sourceType"],
        })

    def success(self, version=1):
        source_id = self.vector["sourceRecordId"]
        return json.dumps({
            "canonicalId": f"apple.healthkit:{source_id}",
            "canonicalType": "activity.steps",
            "endDate": "2026-01-01T00:01:00Z",
            "id": source_id,
            "kind": "quantity",
            "lineage": [{
                "recordId": source_id,
                "store": "apple.healthkit",
            }],
            "quantity": {"unit": "count", "value": 1},
            "recordVersion": version,
            "schemaVersion": 1,
            "sourceRecord": {
                "id": source_id,
                "store": "apple.healthkit",
                "type": self.vector["sourceType"],
            },
            "startDate": "2026-01-01T00:00:00Z",
            "type": self.vector["sourceType"],
        })

    def deletion(self):
        source_id = self.vector["sourceRecordId"]
        return json.dumps({
            "canonicalId": f"apple.healthkit:{source_id}",
            "canonicalType": "activity.steps",
            "id": source_id,
            "kind": "deletion",
            "lineage": [{
                "recordId": source_id,
                "store": "apple.healthkit",
            }],
            "recordVersion": 2,
            "schemaVersion": 1,
            "sourceRecord": {
                "id": source_id,
                "store": "apple.healthkit",
                "type": self.vector["sourceType"],
            },
            "type": self.vector["sourceType"],
        })

    def rows(self):
        return self.db.execute(
            """
            SELECT canonical_id, parent_canonical_id, record_version, tombstone
            FROM samples ORDER BY canonical_id
            """
        ).fetchall()

    def series_header(self, source_id):
        return json.dumps({
            "canonicalId": f"apple.healthkit:{source_id}",
            "canonicalType": "activity.exercise-route",
            "endDate": "2026-01-01T00:01:00Z",
            "id": source_id,
            "kind": "workoutRoute",
            "lineage": [{
                "recordId": source_id,
                "store": "apple.healthkit",
            }],
            "recordVersion": 1,
            "schemaVersion": 1,
            "sourceRecord": {
                "id": source_id,
                "store": "apple.healthkit",
                "type": "HKWorkoutRouteTypeIdentifier",
            },
            "startDate": "2026-01-01T00:00:00Z",
            "type": "HKWorkoutRouteTypeIdentifier",
        })

    def continuation_error(self, source_id, end_id):
        error_id = encoding_failure_id(
            source_id,
            "HKWorkoutRouteTypeIdentifier",
        )
        return json.dumps({
            "canonicalId": f"apple.healthkit:{error_id}",
            "canonicalType": "archive.encoding-error",
            "id": error_id,
            "kind": "sampleEncodingError",
            "lineage": [{
                "recordId": source_id,
                "store": "apple.healthkit",
            }],
            "message": "continuation failed",
            "parentCanonicalId": f"apple.healthkit:{source_id}",
            "recordVersion": 3,
            "resolutionCanonicalId": f"apple.healthkit:{end_id}",
            "schemaVersion": 1,
            "sourceRecord": {
                "id": source_id,
                "store": "apple.healthkit",
                "type": "HKWorkoutRouteTypeIdentifier",
            },
            "type": "HKWorkoutRouteTypeIdentifier",
        })

    def series_end(self, source_id, end_id):
        return json.dumps({
            "canonicalId": f"apple.healthkit:{end_id}",
            "canonicalType": "activity.exercise-route-end",
            "endDate": "2026-01-01T00:01:00Z",
            "id": end_id,
            "kind": "workoutRouteEnd",
            "lineage": [{
                "recordId": source_id,
                "store": "apple.healthkit",
            }],
            "parentCanonicalId": f"apple.healthkit:{source_id}",
            "recordVersion": 1,
            "sample": source_id,
            "schemaVersion": 1,
            "sourceRecord": {
                "id": source_id,
                "store": "apple.healthkit",
                "type": "HKWorkoutRouteTypeIdentifier",
            },
            "startDate": "2026-01-01T00:00:00Z",
            "type": "HKWorkoutRouteTypeIdentifier",
        })

    def test_encoding_failure_identity_matches_shared_fixture(self):
        self.assertEqual(
            self.vector["recordId"],
            encoding_failure_id(
                self.vector["sourceRecordId"],
                self.vector["sourceType"],
            ),
        )

    def test_series_completion_identity_matches_shared_fixture(self):
        self.assertEqual(
            self.series_vector["recordId"],
            receiver.series_end_id(
                self.series_vector["sourceRecordId"],
                self.series_vector["sourceType"],
            ),
        )

    def test_later_success_resolves_prior_error(self):
        ingest_lines(self.db, [self.error()])
        ingest_lines(self.db, [self.success()])

        rows = self.rows()
        self.assertEqual(2, len(rows))
        error = rows[1]
        self.assertEqual(self.vector["canonicalId"], error[0])
        self.assertEqual(
            f"apple.healthkit:{self.vector['sourceRecordId']}",
            error[1],
        )
        self.assertGreaterEqual(error[2], 2)
        self.assertEqual(1, error[3])
        self.assertEqual(1, sum(row[3] == 0 for row in rows))

    def test_parent_deletion_resolves_error_and_stays_idempotent(self):
        ingest_lines(self.db, [self.error()])
        ingest_lines(self.db, [self.deletion()])
        first = self.rows()
        ingest_lines(self.db, [self.deletion()])

        self.assertEqual(first, self.rows())
        self.assertTrue(all(row[3] == 1 for row in first))

    def test_legacy_series_child_uses_sample_as_parent_for_deletion(self):
        source_id = self.vector["sourceRecordId"]
        child_id = receiver.series_record_id(
            source_id,
            self.vector["sourceType"],
            "readings-0",
        )
        child = json.dumps({
            "id": child_id,
            "kind": "quantitySeriesReadings",
            "sample": source_id,
            "schemaVersion": 1,
            "sequence": 0,
            "type": self.vector["sourceType"],
        })

        ingest_lines(self.db, [child])
        ingest_lines(self.db, [self.deletion()])

        rows = self.rows()
        self.assertEqual(2, len(rows))
        self.assertTrue(all(row[3] == 1 for row in rows))
        self.assertEqual(
            f"apple.healthkit:{source_id}",
            next(row for row in rows if row[0].endswith(child_id))[1],
        )

    def test_legacy_parented_record_uses_source_record_without_sample(self):
        source_id = "00000000-0000-0000-0000-000000000204"
        end_id = receiver.series_end_id(
            source_id,
            "HKWorkoutRouteTypeIdentifier",
        )
        record = {
            "canonicalId": f"apple.healthkit:{end_id}",
            "id": end_id,
            "kind": "workoutRouteEnd",
            "schemaVersion": 1,
            "sourceRecord": {
                "id": source_id,
                "store": "apple.healthkit",
                "type": "HKWorkoutRouteTypeIdentifier",
            },
            "type": "HKWorkoutRouteTypeIdentifier",
        }

        ingest_lines(self.db, [json.dumps(record)])

        self.assertEqual(
            (f"apple.healthkit:{source_id}",),
            self.db.execute(
                "SELECT parent_canonical_id FROM samples"
            ).fetchone(),
        )

    def test_continuation_failure_waits_for_end_marker(self):
        source_id = "00000000-0000-0000-0000-000000000123"
        end_id = receiver.series_end_id(
            source_id,
            "HKWorkoutRouteTypeIdentifier",
        )
        ingest_lines(
            self.db,
            [
                self.series_header(source_id),
                self.continuation_error(source_id, end_id),
            ],
        )
        error = self.db.execute(
            "SELECT tombstone FROM samples WHERE kind = 'sampleEncodingError'"
        ).fetchone()
        self.assertEqual((0,), error)

        ingest_lines(self.db, [self.series_end(source_id, end_id)])

        error = self.db.execute(
            "SELECT tombstone FROM samples WHERE kind = 'sampleEncodingError'"
        ).fetchone()
        self.assertEqual((1,), error)

    def test_wrong_series_end_kind_cannot_resolve_failure(self):
        source_id = "00000000-0000-0000-0000-000000000127"
        end_id = receiver.series_end_id(
            source_id,
            "HKWorkoutRouteTypeIdentifier",
        )
        wrong_end = json.loads(self.series_end(source_id, end_id))
        wrong_end["kind"] = "electrocardiogramEnd"
        wrong_end["canonicalType"] = "cardiac.electrocardiogram-end"

        with self.assertRaises(PartialBatch):
            ingest_lines(self.db, [json.dumps(wrong_end)])

        ingest_lines(
            self.db,
            [
                self.series_header(source_id),
                self.continuation_error(source_id, end_id),
            ],
        )
        self.assertEqual(
            (0,),
            self.db.execute(
                "SELECT tombstone FROM samples "
                "WHERE kind = 'sampleEncodingError'"
            ).fetchone(),
        )

    def test_resolved_error_round_trip_preserves_version(self):
        source_id = "00000000-0000-0000-0000-000000000130"
        end_id = receiver.series_end_id(
            source_id,
            "HKWorkoutRouteTypeIdentifier",
        )
        error = json.loads(self.continuation_error(source_id, end_id))
        error["deleted"] = True
        error["recordVersion"] = 4

        ingest_lines(
            self.db,
            [
                self.series_header(source_id),
                json.dumps(error),
                self.series_end(source_id, end_id),
            ],
        )

        self.assertEqual(
            (4, 1),
            self.db.execute(
                "SELECT record_version, tombstone FROM samples "
                "WHERE kind = 'sampleEncodingError'"
            ).fetchone(),
        )

    def test_missing_synthetic_id_cannot_fall_back_to_header(self):
        source_id = "00000000-0000-0000-0000-000000000131"
        missing_id = {
            "kind": "workoutRouteEnd",
            "recordVersion": 99,
            "schemaVersion": 1,
            "sourceRecord": {
                "id": source_id,
                "store": "apple.healthkit",
                "type": "HKWorkoutRouteTypeIdentifier",
            },
            "type": "HKWorkoutRouteTypeIdentifier",
        }

        with self.assertRaises(PartialBatch):
            ingest_lines(self.db, [json.dumps(missing_id)])
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )

    def test_forged_continuation_tombstone_stays_live_without_end(self):
        source_id = "00000000-0000-0000-0000-000000000129"
        end_id = receiver.series_end_id(
            source_id,
            "HKWorkoutRouteTypeIdentifier",
        )
        error = json.loads(self.continuation_error(source_id, end_id))
        error["deleted"] = True

        ingest_lines(
            self.db,
            [self.series_header(source_id), json.dumps(error)],
        )

        self.assertEqual(
            (4, 0),
            self.db.execute(
                "SELECT record_version, tombstone FROM samples "
                "WHERE kind = 'sampleEncodingError'"
            ).fetchone(),
        )

    def test_parent_deletion_resolves_continuation_failure_without_end(self):
        source_id = "00000000-0000-0000-0000-000000000124"
        end_id = receiver.series_end_id(
            source_id,
            "HKWorkoutRouteTypeIdentifier",
        )
        ingest_lines(
            self.db,
            [
                self.series_header(source_id),
                self.continuation_error(source_id, end_id),
            ],
        )
        deletion = json.loads(self.series_header(source_id))
        deletion["kind"] = "deletion"
        deletion["recordVersion"] = 2
        deletion.pop("startDate")
        deletion.pop("endDate")

        ingest_lines(self.db, [json.dumps(deletion)])

        self.assertTrue(
            all(
                row[0] == 1
                for row in self.db.execute(
                    "SELECT tombstone FROM samples"
                )
            )
        )

    def test_continuation_failure_supersedes_resolved_header_error(self):
        source_id = "00000000-0000-0000-0000-000000000125"
        end_id = receiver.series_end_id(
            source_id,
            "HKWorkoutRouteTypeIdentifier",
        )
        header_error = json.loads(
            self.continuation_error(source_id, end_id)
        )
        header_error["recordVersion"] = 1
        header_error.pop("resolutionCanonicalId")

        ingest_lines(self.db, [json.dumps(header_error)])
        ingest_lines(self.db, [self.series_header(source_id)])
        self.assertEqual(
            (2, 1),
            self.db.execute(
                "SELECT record_version, tombstone FROM samples "
                "WHERE kind = 'sampleEncodingError'"
            ).fetchone(),
        )
        ingest_lines(
            self.db,
            [self.continuation_error(source_id, end_id)],
        )
        self.assertEqual(
            (3, 0),
            self.db.execute(
                "SELECT record_version, tombstone FROM samples "
                "WHERE kind = 'sampleEncodingError'"
            ).fetchone(),
        )

    def test_upgrade_restores_continuation_error_hidden_by_old_consumer(self):
        source_id = "00000000-0000-0000-0000-000000000126"
        end_id = receiver.series_end_id(
            source_id,
            "HKWorkoutRouteTypeIdentifier",
        )
        ingest_lines(
            self.db,
            [
                self.series_header(source_id),
                self.continuation_error(source_id, end_id),
            ],
        )
        raw = self.db.execute(
            "SELECT raw FROM samples WHERE kind = 'sampleEncodingError'"
        ).fetchone()[0]
        raw_object = json.loads(raw)
        raw_object["deleted"] = True
        self.db.execute(
            """
            UPDATE samples
            SET resolution_canonical_id = NULL,
                record_version = 4,
                tombstone = 1,
                raw = ?
            WHERE kind = 'sampleEncodingError'
            """,
            (json.dumps(raw_object),),
        )
        self.db.commit()
        self.db.close()

        self.db = connect(self.database)

        self.assertEqual(
            (5, 0, f"apple.healthkit:{end_id}"),
            self.db.execute(
                """
                SELECT record_version, tombstone, resolution_canonical_id
                FROM samples
                WHERE kind = 'sampleEncodingError'
                """
            ).fetchone(),
        )
        self.db.close()
        self.db = connect(self.database)
        self.assertEqual(
            (5, 0),
            self.db.execute(
                "SELECT record_version, tombstone FROM samples "
                "WHERE kind = 'sampleEncodingError'"
            ).fetchone(),
        )

    def test_upgrade_reconciles_live_error_when_end_already_exists(self):
        source_id = "00000000-0000-0000-0000-000000000128"
        end_id = receiver.series_end_id(
            source_id,
            "HKWorkoutRouteTypeIdentifier",
        )
        ingest_lines(
            self.db,
            [
                self.series_header(source_id),
                self.continuation_error(source_id, end_id),
                self.series_end(source_id, end_id),
            ],
        )
        self.db.execute(
            """
            UPDATE samples
            SET resolution_canonical_id = NULL,
                record_version = 3,
                tombstone = 0
            WHERE kind = 'sampleEncodingError'
            """
        )
        self.db.commit()
        self.db.close()

        self.db = connect(self.database)

        self.assertEqual(
            (4, 1),
            self.db.execute(
                "SELECT record_version, tombstone FROM samples "
                "WHERE kind = 'sampleEncodingError'"
            ).fetchone(),
        )

    def test_late_error_after_deletion_is_tombstoned_immediately(self):
        ingest_lines(self.db, [self.deletion()])
        ingest_lines(self.db, [self.error()])

        rows = self.rows()
        self.assertEqual(2, len(rows))
        self.assertTrue(all(row[3] == 1 for row in rows))
        self.assertTrue(all(row[2] >= 2 for row in rows))

    def test_late_error_after_success_is_tombstoned_immediately(self):
        ingest_lines(self.db, [self.success()])
        ingest_lines(self.db, [self.error()])

        rows = self.rows()
        self.assertEqual(2, len(rows))
        self.assertEqual(1, sum(row[3] == 0 for row in rows))
        self.assertEqual(1, sum(row[3] == 1 for row in rows))

    def test_legacy_deleted_flag_supersedes_unversioned_live_record(self):
        live = json.loads(self.success())
        live.pop("recordVersion")
        deleted = dict(live)
        deleted["deleted"] = True

        ingest_lines(self.db, [json.dumps(live)])
        ingest_lines(self.db, [json.dumps(deleted)])

        row = self.rows()[0]
        self.assertEqual(2, row[2])
        self.assertEqual(1, row[3])

    def test_legacy_characteristics_get_stable_identity_and_time_version(self):
        read_at = "2026-01-01T00:00:00Z"
        ingest_lines(self.db, [json.dumps({
            "characteristics": {"biologicalSex": {"value": "female"}},
            "kind": "characteristics",
            "readAt": read_at,
            "schemaVersion": 1,
        })])

        row = self.db.execute(
            """
            SELECT canonical_id, source_id, record_version
            FROM samples
            """
        ).fetchone()
        self.assertEqual("apple.healthkit:characteristics", row[0])
        self.assertEqual("characteristics", row[1])
        self.assertGreater(row[2], 1)


class MigrationTests(unittest.TestCase):
    def test_legacy_batch_receipts_are_marked_with_unknown_deletion_count(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receiver.sqlite"
            db = sqlite3.connect(path)
            db.execute(
                """
                CREATE TABLE batches (
                    key TEXT PRIMARY KEY,
                    received_at REAL NOT NULL,
                    records INTEGER NOT NULL
                )
                """
            )
            db.execute("INSERT INTO batches VALUES ('old', 0, 1)")
            db.commit()
            db.close()

            migrated = connect(path)
            value = migrated.execute(
                "SELECT deletions FROM batches WHERE key = 'old'"
            ).fetchone()[0]
            migrated.close()

            self.assertEqual(-1, value)

    def test_legacy_database_is_migrated_without_losing_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receiver.sqlite"
            db = sqlite3.connect(path)
            db.execute(
                """
                CREATE TABLE samples (
                    id TEXT PRIMARY KEY, type TEXT NOT NULL, kind TEXT,
                    start_date TEXT, end_date TEXT, value REAL, unit TEXT,
                    source TEXT, raw TEXT NOT NULL
                )
                """
            )
            db.execute(
                """
                INSERT INTO samples VALUES
                    ('legacy', 'steps', 'quantity', NULL, NULL, 1, 'count',
                     'fixture', '{}')
                """
            )
            db.commit()
            db.close()

            migrated = connect(path)
            row = migrated.execute(
                "SELECT canonical_id, source_id, tombstone FROM samples"
            ).fetchone()
            migrated.close()

            self.assertEqual(("apple.healthkit:legacy", "legacy", 0), row)

    def test_migrated_record_replays_under_the_same_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receiver.sqlite"
            db = sqlite3.connect(path)
            db.execute(
                """
                CREATE TABLE samples (
                    id TEXT PRIMARY KEY, type TEXT NOT NULL, kind TEXT,
                    start_date TEXT, end_date TEXT, value REAL, unit TEXT,
                    source TEXT, raw TEXT NOT NULL
                )
                """
            )
            db.execute(
                """
                INSERT INTO samples VALUES
                    ('legacy', 'steps', 'quantity', NULL, NULL, 1, 'count',
                     'fixture', '{"id":"legacy","kind":"quantity","type":"steps"}')
                """
            )
            db.commit()
            db.close()

            migrated = connect(path)
            ingest_lines(
                migrated,
                [json.dumps({
                    "id": "legacy",
                    "kind": "deletion",
                    "schemaVersion": 1,
                    "type": "steps",
                })],
            )
            rows = migrated.execute(
                "SELECT canonical_id, tombstone FROM samples"
            ).fetchall()
            migrated.close()

            self.assertEqual([("apple.healthkit:legacy", 1)], rows)

    def test_migration_preserves_canonical_version_parent_and_tombstone(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receiver.sqlite"
            raw = json.dumps({
                "canonicalId": "apple.healthkit:error",
                "deleted": True,
                "id": "error",
                "kind": "sampleEncodingError",
                "parentCanonicalId": "apple.healthkit:parent",
                "recordVersion": 7,
                "sourceRecord": {
                    "id": "source",
                    "store": "apple.healthkit",
                    "type": "steps",
                },
                "type": "steps",
            })
            db = sqlite3.connect(path)
            db.execute(
                """
                CREATE TABLE samples (
                    id TEXT PRIMARY KEY, type TEXT NOT NULL, kind TEXT,
                    start_date TEXT, end_date TEXT, value REAL, unit TEXT,
                    source TEXT, raw TEXT NOT NULL
                )
                """
            )
            db.execute(
                """
                INSERT INTO samples VALUES
                    ('legacy-error', 'steps', 'sampleEncodingError',
                     NULL, NULL, NULL, NULL, 'fixture', ?)
                """,
                (raw,),
            )
            db.commit()
            db.close()

            migrated = connect(path)
            row = migrated.execute(
                """
                SELECT canonical_id, source_id, parent_canonical_id,
                       record_version, tombstone
                FROM samples
                """
            ).fetchone()
            migrated.close()

            self.assertEqual(
                (
                    "apple.healthkit:error",
                    "source",
                    "apple.healthkit:parent",
                    7,
                    1,
                ),
                row,
            )

    def test_migration_tolerates_previously_accepted_source_record_shape(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receiver.sqlite"
            raw = json.dumps({
                "id": "legacy",
                "kind": "quantity",
                "sourceRecord": "unexpected",
                "type": "steps",
            })
            db = sqlite3.connect(path)
            db.execute(
                """
                CREATE TABLE samples (
                    id TEXT PRIMARY KEY, type TEXT NOT NULL, kind TEXT,
                    start_date TEXT, end_date TEXT, value REAL, unit TEXT,
                    source TEXT, raw TEXT NOT NULL
                )
                """
            )
            db.execute(
                """
                INSERT INTO samples VALUES
                    ('legacy', 'steps', 'quantity', NULL, NULL, 1, 'count',
                     'fixture', ?)
                """,
                (raw,),
            )
            db.commit()
            db.close()

            migrated = connect(path)
            self.assertEqual(
                ("apple.healthkit:legacy", "legacy"),
                migrated.execute(
                    "SELECT canonical_id, source_id FROM samples"
                ).fetchone(),
            )
            migrated.close()

    def test_migration_falls_back_from_non_string_nested_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receiver.sqlite"
            raw = json.dumps({
                "id": "legacy",
                "kind": "quantity",
                "sourceRecord": {"id": ["malformed"], "store": 7},
                "type": "steps",
            })
            db = sqlite3.connect(path)
            db.execute(
                """
                CREATE TABLE samples (
                    id TEXT PRIMARY KEY, type TEXT NOT NULL, kind TEXT,
                    start_date TEXT, end_date TEXT, value REAL, unit TEXT,
                    source TEXT, raw TEXT NOT NULL
                )
                """
            )
            db.execute(
                """
                INSERT INTO samples VALUES
                    ('legacy', 'steps', 'quantity', NULL, NULL, 1, 'count',
                     'fixture', ?)
                """,
                (raw,),
            )
            db.commit()
            db.close()

            migrated = connect(path)
            self.assertEqual(
                ("apple.healthkit:legacy", "legacy"),
                migrated.execute(
                    "SELECT canonical_id, source_id FROM samples"
                ).fetchone(),
            )
            migrated.close()

    def test_failed_migration_rolls_back_and_can_resume(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receiver.sqlite"
            db = sqlite3.connect(path)
            db.execute(
                """
                CREATE TABLE samples (
                    id TEXT PRIMARY KEY, type TEXT NOT NULL, kind TEXT,
                    start_date TEXT, end_date TEXT, value REAL, unit TEXT,
                    source TEXT, raw TEXT NOT NULL
                )
                """
            )
            db.execute(
                """
                INSERT INTO samples VALUES
                    ('legacy', 'steps', 'quantity', NULL, NULL, 1, 'count',
                     'fixture', '{}')
                """
            )
            db.commit()
            db.close()

            with (
                mock.patch.object(
                    receiver,
                    "legacy_canonical_id",
                    side_effect=RuntimeError("interrupted"),
                ),
                self.assertRaises(RuntimeError),
            ):
                connect(path)

            interrupted = sqlite3.connect(path)
            columns = {
                row[1] for row in interrupted.execute(
                    "PRAGMA table_info(samples)"
                )
            }
            self.assertIn("id", columns)
            self.assertNotIn("canonical_id", columns)
            self.assertIsNone(
                interrupted.execute(
                    "SELECT 1 FROM sqlite_master "
                    "WHERE type = 'table' AND name = 'samples_legacy'"
                ).fetchone()
            )
            interrupted.close()

            migrated = connect(path)
            self.assertEqual(
                ("apple.healthkit:legacy", "legacy"),
                migrated.execute(
                    "SELECT canonical_id, source_id FROM samples"
                ).fetchone(),
            )
            migrated.close()

    def test_migration_reconciles_error_after_all_rows_are_copied(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receiver.sqlite"
            source_id = "00000000-0000-0000-0000-000000000123"
            error_id = encoding_failure_id(source_id, "steps")
            parent_raw = json.dumps({
                "canonicalId": f"apple.healthkit:{source_id}",
                "id": source_id,
                "kind": "quantity",
                "recordVersion": 1,
                "sourceRecord": {
                    "id": source_id,
                    "store": "apple.healthkit",
                    "type": "steps",
                },
                "type": "steps",
            })
            error_raw = json.dumps({
                "canonicalId": f"apple.healthkit:{error_id}",
                "id": error_id,
                "kind": "sampleEncodingError",
                "parentCanonicalId": f"apple.healthkit:{source_id}",
                "recordVersion": 1,
                "sourceRecord": {
                    "id": source_id,
                    "store": "apple.healthkit",
                    "type": "steps",
                },
                "type": "steps",
            })
            db = sqlite3.connect(path)
            db.execute(
                """
                CREATE TABLE samples (
                    id TEXT PRIMARY KEY, type TEXT NOT NULL, kind TEXT,
                    start_date TEXT, end_date TEXT, value REAL, unit TEXT,
                    source TEXT, raw TEXT NOT NULL
                )
                """
            )
            db.executemany(
                "INSERT INTO samples VALUES (?, 'steps', ?, NULL, NULL, "
                "NULL, NULL, 'fixture', ?)",
                [
                    (source_id, "quantity", parent_raw),
                    (error_id, "sampleEncodingError", error_raw),
                ],
            )
            db.commit()
            db.close()

            migrated = connect(path)
            rows = migrated.execute(
                "SELECT kind, tombstone FROM samples ORDER BY kind"
            ).fetchall()
            migrated.close()

            self.assertEqual(
                [("quantity", 0), ("sampleEncodingError", 1)],
                rows,
            )

    def test_migration_cascades_a_parent_tombstone_to_its_child(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receiver.sqlite"
            parent_id = "parent"
            parent_raw = json.dumps({
                "canonicalId": f"apple.healthkit:{parent_id}",
                "deleted": True,
                "id": parent_id,
                "kind": "quantity",
                "recordVersion": 4,
                "type": "steps",
            })
            child_raw = json.dumps({
                "canonicalId": "apple.healthkit:child",
                "id": "child",
                "kind": "quantitySeriesReadings",
                "parentCanonicalId": f"apple.healthkit:{parent_id}",
                "recordVersion": 1,
                "type": "steps",
            })
            db = sqlite3.connect(path)
            db.execute(
                """
                CREATE TABLE samples (
                    id TEXT PRIMARY KEY, type TEXT NOT NULL, kind TEXT,
                    start_date TEXT, end_date TEXT, value REAL, unit TEXT,
                    source TEXT, raw TEXT NOT NULL
                )
                """
            )
            db.executemany(
                "INSERT INTO samples VALUES (?, 'steps', ?, NULL, NULL, "
                "NULL, NULL, 'fixture', ?)",
                [
                    (parent_id, "quantity", parent_raw),
                    ("child", "quantitySeriesReadings", child_raw),
                ],
            )
            db.commit()
            db.close()

            migrated = connect(path)
            rows = migrated.execute(
                "SELECT canonical_id, record_version, tombstone "
                "FROM samples ORDER BY canonical_id"
            ).fetchall()
            migrated.close()

            self.assertEqual(
                [
                    ("apple.healthkit:child", 4, 1),
                    ("apple.healthkit:parent", 4, 1),
                ],
                rows,
            )


class TransactionAndArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.database = Path(self.directory.name) / "receiver.sqlite"
        self.db = connect(self.database)

    def tearDown(self):
        self.db.close()
        self.directory.cleanup()

    def test_any_validation_failure_rolls_back_the_whole_batch(self):
        valid = json.dumps({
            "id": "valid",
            "kind": "quantity",
            "quantity": {"unit": "count", "value": 1},
            "schemaVersion": 1,
            "type": "steps",
        })
        invalid = json.dumps({
            "id": "invalid",
            "kind": "quantity",
            "quantity": ["not", "an", "object"],
            "schemaVersion": 1,
            "type": "steps",
        })

        with self.assertRaises(AttributeError):
            ingest_lines(self.db, [valid, invalid])
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )
        ingest_lines(self.db, [valid])
        self.assertEqual(
            1,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )

    def test_future_schema_does_not_commit_batch_identity(self):
        future = json.dumps({
            "kind": "typeSummary",
            "schemaVersion": 2,
            "state": "complete",
            "type": "steps",
        })
        current = json.dumps({
            "kind": "typeSummary",
            "schemaVersion": 1,
            "state": "complete",
            "type": "steps",
        })

        with self.assertRaises(PartialBatch):
            ingest_lines(self.db, [future], batch_key="future")
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM batches").fetchone()[0],
        )
        ingest_lines(self.db, [current], batch_key="future")
        self.assertEqual(
            1,
            self.db.execute(
                "SELECT COUNT(*) FROM archive_run_records"
            ).fetchone()[0],
        )
    def test_payload_memory_budget_rejects_before_decode(self):
        with (
            mock.patch.object(receiver, "MAX_PENDING_BATCH_BYTES", 8),
            self.assertRaises(PartialBatch),
        ):
            receiver.ingest_payload(self.db, b"123456789")

    def test_negative_or_invalid_content_length_is_rejected(self):
        for value in (
            "-1",
            "not-a-number",
            "+1",
            " 1",
            "1_0",
            "9" * 5_000,
        ):
            with self.assertRaises(PartialBatch):
                receiver.parse_content_length(value)

    def test_large_plain_ndjson_streams_without_whole_file_buffer(self):
        path = Path(self.directory.name) / "large.ndjson"
        records = [
            {
                "id": "stream-one",
                "kind": "quantity",
                "quantity": {"unit": "count", "value": 1},
                "schemaVersion": 1,
                "type": "steps",
            },
            {
                "id": "stream-two",
                "kind": "quantity",
                "quantity": {"unit": "count", "value": 2},
                "schemaVersion": 1,
                "type": "steps",
            },
        ]
        path.write_text(
            "".join(json.dumps(record) + "\n" for record in records)
        )

        with mock.patch.object(receiver, "MAX_PENDING_BATCH_BYTES", 16):
            self.assertEqual((2, 0), ingest_file(self.db, path))

        self.assertEqual(
            2,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )

    def test_json_array_streams_one_record_at_a_time(self):
        payload = json.dumps([
            {
                "id": "array-one",
                "kind": "quantity",
                "quantity": {"unit": "count", "value": 1},
                "schemaVersion": 1,
                "type": "steps",
            },
            {
                "id": "array-two",
                "kind": "quantity",
                "quantity": {"unit": "count", "value": 2},
                "schemaVersion": 1,
                "type": "steps",
            },
        ]).encode()

        stored, deleted, duplicate = receiver.ingest_seekable_stream(
            self.db,
            io.BytesIO(payload),
            len(payload),
            "array",
        )

        self.assertEqual((2, 0, False), (stored, deleted, duplicate))

    def test_long_leading_whitespace_does_not_hide_payload(self):
        record = json.dumps({
            "id": "after-whitespace",
            "kind": "quantity",
            "quantity": {"unit": "count", "value": 1},
            "schemaVersion": 1,
            "type": "steps",
        }).encode()
        payload = b" " * 513 + record

        self.assertEqual(
            (1, 0, False),
            receiver.ingest_seekable_stream(
                self.db,
                io.BytesIO(payload),
                len(payload),
                "whitespace",
            ),
        )

    def test_data_extension_is_not_misclassified_as_envelope(self):
        record = {
            "data": {},
            "id": "data-extension",
            "kind": "quantity",
            "quantity": {"unit": "count", "value": 1},
            "schemaVersion": 1,
            "type": "steps",
        }
        payload = json.dumps(record).encode()

        self.assertEqual(
            (1, 0, False),
            receiver.ingest_seekable_stream(
                self.db,
                io.BytesIO(payload),
                len(payload),
                "data-extension",
            ),
        )

    def test_envelope_is_classified_structurally_beyond_prefix(self):
        payload = json.dumps({
            "padding": "x" * 600,
            "data": {
                "metrics": [{
                    "name": "step_count",
                    "units": "count",
                    "data": [{
                        "id": "point-1",
                        "date": "2026-01-01T00:00:00Z",
                        "qty": 1,
                    }],
                }],
            },
        }).encode()

        self.assertEqual(
            (1, 0, False),
            receiver.ingest_seekable_stream(
                self.db,
                io.BytesIO(payload),
                len(payload),
                "envelope",
            ),
        )

    def test_oversized_envelope_is_rejected_without_batch_receipt(self):
        payload = json.dumps({
            "padding": "x" * receiver.MAX_ENVELOPE_BYTES,
            "data": {"metrics": []},
        }).encode()

        with self.assertRaises(PartialBatch):
            receiver.ingest_seekable_stream(
                self.db,
                io.BytesIO(payload),
                len(payload),
                "oversized-envelope",
            )
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM batches").fetchone()[0],
        )

    def test_large_ndjson_record_uses_record_not_envelope_limit(self):
        record = {
            "id": "large-record",
            "kind": "quantity",
            "padding": "x" * (2 * 1_024 * 1_024),
            "quantity": {"unit": "count", "value": 1},
            "schemaVersion": 1,
            "type": "steps",
        }
        payload = json.dumps(record).encode()

        self.assertEqual(
            (1, 0, False),
            receiver.ingest_seekable_stream(
                self.db,
                io.BytesIO(payload),
                len(payload),
                "large-record",
            ),
        )

    def test_json_array_rejects_trailing_separator_and_content_atomically(self):
        record = json.dumps({
            "id": "array-malformed",
            "kind": "quantity",
            "quantity": {"unit": "count", "value": 1},
            "schemaVersion": 1,
            "type": "steps",
        })
        for suffix in (",]", "] trailing"):
            payload = f"[{record}{suffix}".encode()
            with self.assertRaises(PartialBatch):
                receiver.ingest_seekable_stream(
                    self.db,
                    io.BytesIO(payload),
                    len(payload),
                    f"malformed-{suffix}",
                )
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )

    def test_json_array_limit_measures_item_not_array_syntax(self):
        record = json.dumps({
            "id": "array-limit",
            "kind": "quantity",
            "quantity": {"unit": "count", "value": 1},
            "schemaVersion": 1,
            "type": "steps",
        }, separators=(",", ":"))
        payload = f"[{record}]".encode()

        with mock.patch.object(
            receiver,
            "MAX_RECORD_BYTES",
            len(record.encode()),
        ):
            self.assertEqual(
                (1, 0, False),
                receiver.ingest_seekable_stream(
                    self.db,
                    io.BytesIO(payload),
                    len(payload),
                    "array-limit",
                ),
            )

    def test_record_size_strips_only_one_line_ending(self):
        record = json.dumps({
            "id": "carriage-return",
            "kind": "quantity",
            "quantity": {"unit": "count", "value": 1},
            "schemaVersion": 1,
            "type": "steps",
        }, separators=(",", ":")).encode()
        payload = record + b"\r\r\n"

        with (
            mock.patch.object(receiver, "MAX_RECORD_BYTES", len(record)),
            self.assertRaises(PartialBatch),
        ):
            receiver.ingest_seekable_stream(
                self.db,
                io.BytesIO(payload),
                len(payload),
                "carriage-return",
            )

    def test_streaming_plain_file_peak_is_below_payload_size(self):
        path = Path(self.directory.name) / "stream-peak.ndjson"
        padding = "x" * 4_096
        path.write_text(
            "".join(
                json.dumps({
                    "id": f"peak-{index}",
                    "kind": "quantity",
                    "padding": padding,
                    "quantity": {"unit": "count", "value": index},
                    "schemaVersion": 1,
                    "type": "steps",
                }) + "\n"
                for index in range(512)
            )
        )
        size = path.stat().st_size

        tracemalloc.start()
        with mock.patch.object(
            Path,
            "read_bytes",
            side_effect=AssertionError("whole file was buffered"),
        ):
            ingest_file(self.db, path)
        _, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()

        self.assertLess(peak, size)

    def test_serve_requires_explicit_authentication_choice(self):
        parser = receiver.build_argument_parser()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                parser.parse_args(["serve"])
            with self.assertRaises(SystemExit):
                parser.parse_args(["serve", "--token", ""])
        self.assertEqual(
            "secret",
            parser.parse_args(["serve", "--token", "secret"]).token,
        )
        self.assertTrue(
            parser.parse_args(
                ["serve", "--allow-unauthenticated"]
            ).allow_unauthenticated
        )
        self.assertEqual(
            "127.0.0.1",
            parser.parse_args(["serve", "--token", "secret"]).host,
        )

    def test_plaintext_serve_is_loopback_only(self):
        self.assertEqual(
            (None, socket.AF_INET),
            receiver.serve_security("127.42.0.1", None, None),
        )
        self.assertEqual(
            (None, socket.AF_INET6),
            receiver.serve_security("::1", None, None),
        )
        for host in ("0.0.0.0", "::", "192.168.1.20", "8.8.8.8"):
            with self.assertRaises(ValueError):
                receiver.serve_security(host, None, None)

    def test_non_loopback_tls_uses_supplied_trust_material(self):
        context = mock.Mock()
        with mock.patch.object(
            receiver.ssl,
            "SSLContext",
            return_value=context,
        ) as factory:
            actual, family = receiver.serve_security(
                "192.168.1.20",
                "fullchain.pem",
                "private-key.pem",
            )

        self.assertIs(context, actual)
        self.assertEqual(socket.AF_INET, family)
        factory.assert_called_once_with(receiver.ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain.assert_called_once_with(
            certfile="fullchain.pem",
            keyfile="private-key.pem",
        )

    def test_tls_requires_certificate_and_key_together(self):
        for certificate, key in (("cert.pem", None), (None, "key.pem")):
            with self.assertRaises(ValueError):
                receiver.serve_security("127.0.0.1", certificate, key)

    def test_compatible_blank_date_deletion_is_preserved_with_metric(self):
        date = "2026-01-01T00:00:00Z"
        ingest_compatible(self.db, {
            "data": {
                "deletions": [{
                    "id": "deleted-id",
                    "name": "step_count",
                    "type": "HKQuantityTypeIdentifierStepCount",
                    "date": "",
                }],
            },
        })
        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [{"id": "deleted-id", "date": date, "qty": 100}],
                }],
            },
        })

        rows = self.db.execute(
            "SELECT record_version, tombstone FROM samples ORDER BY tombstone"
        ).fetchall()
        self.assertEqual([(2, 1)], rows)

    def test_date_less_deletion_blocks_legacy_until_stable_identity_arrives(self):
        date = "2026-01-01T00:00:00Z"
        deletion = {
            "data": {
                "deletions": [{
                    "id": "stable-id",
                    "name": "steps",
                    "type": "steps",
                    "date": "",
                }],
            },
        }
        ingest_compatible(self.db, deletion, batch_key="fresh-delete")
        legacy = json.dumps({
            "id": f"steps:{date}",
            "type": "steps",
            "kind": "quantity",
            "startDate": date,
            "endDate": date,
            "quantity": {"value": 100, "unit": "count"},
        })

        with self.assertRaises(PartialBatch):
            ingest_lines(self.db, [legacy], batch_key="legacy-before-stable")

        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [{
                        "id": "stable-id",
                        "date": date,
                        "qty": 100,
                    }],
                }],
            },
        })
        with self.assertRaises(PartialBatch):
            ingest_lines(
                self.db,
                [legacy],
                batch_key="legacy-before-stable",
            )
        self.assertEqual(
            0,
            self.db.execute(
                "SELECT COUNT(*) FROM samples WHERE tombstone = 0"
            ).fetchone()[0],
        )

    def test_pre_upgrade_tombstone_backfills_unresolved_legacy_barrier(self):
        date = "2026-01-01T00:00:00Z"
        ingest_compatible(self.db, {
            "data": {
                "deletions": [{
                    "id": "stable-id",
                    "name": "steps",
                    "type": "steps",
                    "date": "",
                }],
            },
        })
        self.db.execute("DELETE FROM compatible_unresolved_deletion")
        self.db.commit()

        receiver.backfill_compatible_deletion_state(self.db)
        self.db.commit()

        with self.assertRaises(PartialBatch):
            ingest_lines(
                self.db,
                [json.dumps({
                    "id": f"steps:{date}",
                    "type": "steps",
                    "kind": "quantity",
                    "startDate": date,
                    "endDate": date,
                    "quantity": {"value": 100, "unit": "count"},
                })],
                batch_key="legacy-after-upgrade",
            )

    def test_same_timestamp_resolutions_survive_backfill(self):
        date = "2026-01-01T00:00:00Z"
        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [
                        {"id": "first", "date": date, "qty": 1},
                        {"id": "second", "date": date, "qty": 2},
                    ],
                }],
            },
        })
        ingest_compatible(self.db, {
            "data": {
                "deletions": [
                    {"id": "first", "name": "steps", "type": "steps", "date": ""},
                    {"id": "second", "name": "steps", "type": "steps", "date": ""},
                ],
            },
        })
        self.db.execute("DELETE FROM compatible_unresolved_deletion")
        self.db.execute(
            """
            CREATE TABLE compatible_alias_retirement_old_shape (
                type TEXT NOT NULL,
                start_epoch INTEGER NOT NULL,
                stable_id TEXT NOT NULL,
                PRIMARY KEY (type, start_epoch)
            )
            """
        )
        self.db.execute(
            """
            INSERT INTO compatible_alias_retirement_old_shape
            SELECT type, start_epoch, MIN(stable_id)
            FROM compatible_alias_retirement
            GROUP BY type, start_epoch
            """
        )
        self.db.execute("DROP TABLE compatible_alias_retirement")
        self.db.execute(
            """
            ALTER TABLE compatible_alias_retirement_old_shape
            RENAME TO compatible_alias_retirement
            """
        )
        self.db.execute("DELETE FROM compatible_resolved_deletion")

        receiver.ensure_compatible_alias_retirement_schema(self.db)
        receiver.backfill_compatible_deletion_state(self.db)

        self.assertEqual(
            0,
            self.db.execute(
                """
                SELECT COUNT(*) FROM compatible_alias_retirement
                WHERE type = 'steps'
                """
            ).fetchone()[0],
        )
        self.assertEqual(
            2,
            self.db.execute(
                "SELECT COUNT(*) FROM compatible_unresolved_deletion"
            ).fetchone()[0],
        )
        self.assertEqual(
            0,
            self.db.execute(
                "SELECT COUNT(*) FROM compatible_resolved_deletion"
            ).fetchone()[0],
        )

    def test_old_retirement_tombstone_without_raw_becomes_unresolved(self):
        tombstone = {
            "canonicalId": "healthAutoExport:deleted",
            "id": "deleted",
            "kind": "deletion",
            "schemaVersion": 1,
            "recordVersion": 2,
            "sourceRecord": {
                "id": "deleted",
                "store": "healthAutoExport",
                "type": "steps",
            },
            "type": "steps",
        }
        ingest_lines(self.db, [json.dumps(tombstone)])
        self.db.execute("DELETE FROM compatible_resolved_deletion")
        self.db.execute("DELETE FROM compatible_unresolved_deletion")
        self.db.execute("DROP TABLE compatible_alias_retirement")
        self.db.execute(
            """
            CREATE TABLE compatible_alias_retirement (
                type TEXT NOT NULL,
                start_epoch INTEGER NOT NULL,
                stable_id TEXT NOT NULL,
                PRIMARY KEY (type, start_epoch)
            )
            """
        )
        self.db.execute(
            """
            INSERT INTO compatible_alias_retirement
            VALUES ('steps', 1, 'healthAutoExport:deleted')
            """
        )

        receiver.ensure_compatible_alias_retirement_schema(self.db)
        receiver.backfill_compatible_deletion_state(self.db)

        self.assertEqual(
            [("healthAutoExport:deleted", "steps")],
            self.db.execute(
                """
                SELECT stable_id, type FROM compatible_unresolved_deletion
                """
            ).fetchall(),
        )

    def test_alias_reverse_lookups_use_indexes(self):
        identity_plan = " ".join(
            row[3] for row in self.db.execute(
                """
                EXPLAIN QUERY PLAN
                SELECT stable_id FROM compatible_alias_identity
                WHERE legacy_id = 'apple.healthkit:legacy'
                """
            )
        )
        retirement_plan = " ".join(
            row[3] for row in self.db.execute(
                """
                EXPLAIN QUERY PLAN
                SELECT type FROM compatible_alias_retirement
                WHERE stable_id = 'healthAutoExport:stable'
                """
            )
        )

        self.assertIn("compatible_alias_identity_legacy", identity_plan)
        self.assertIn("compatible_alias_retirement_stable", retirement_plan)
    def test_dated_deletion_blocks_ambiguous_delayed_legacy_alias(self):
        date = "2026-01-01T00:00:00Z"
        ingest_compatible(self.db, {
            "data": {
                "deletions": [{
                    "id": "stable-id",
                    "name": "steps",
                    "type": "steps",
                    "date": date,
                }],
            },
        })
        with self.assertRaises(PartialBatch):
            ingest_lines(
                self.db,
                [json.dumps({
                    "id": f"steps:{date}",
                    "type": "steps",
                    "kind": "quantity",
                    "startDate": date,
                    "endDate": date,
                    "quantity": {"value": 100, "unit": "count"},
                })],
                batch_key="legacy-after-dated-delete",
            )
        self.assertEqual(
            0,
            self.db.execute(
                "SELECT COUNT(*) FROM samples WHERE tombstone = 0"
            ).fetchone()[0],
        )

    def test_rejected_compatible_payload_does_not_leak_unresolved_barrier(self):
        malformed = {
            "data": {
                "deletions": [
                    {
                        "id": "pending",
                        "name": "steps",
                        "type": "steps",
                        "date": "",
                    },
                    {
                        "id": "",
                        "name": "steps",
                        "type": "steps",
                        "date": "",
                    },
                ],
            },
        }

        with self.assertRaises(PartialBatch):
            ingest_compatible(self.db, malformed, batch_key="malformed-barrier")

        self.assertFalse(self.db.in_transaction)
        ingest_lines(
            self.db,
            [json.dumps({
                "id": "steps:2026-01-01T00:00:00Z",
                "type": "steps",
                "kind": "quantity",
                "startDate": "2026-01-01T00:00:00Z",
                "endDate": "2026-01-01T00:00:00Z",
                "quantity": {"value": 100, "unit": "count"},
            })],
            batch_key="valid-after-rejection",
        )
        self.assertEqual(
            0,
            self.db.execute(
                "SELECT COUNT(*) FROM compatible_unresolved_deletion"
            ).fetchone()[0],
        )

    def test_date_less_stable_deletion_rejects_live_legacy_alias_without_receipt(self):
        date = "2026-01-01T00:00:00Z"
        ingest_lines(
            self.db,
            [json.dumps({
                "id": f"step_count:{date}",
                "type": "step_count",
                "kind": "quantity",
                "startDate": date,
                "endDate": date,
                "quantity": {"value": 100, "unit": "count"},
            })],
        )
        deletion = {
            "data": {
                "deletions": [{
                    "id": "stable-id",
                    "name": "step_count",
                    "type": "HKQuantityTypeIdentifierStepCount",
                    "date": "",
                }],
            },
        }

        with self.assertRaises(PartialBatch):
            ingest_compatible(self.db, deletion, batch_key="ambiguous-delete")

        self.assertEqual(
            1,
            self.db.execute(
                "SELECT COUNT(*) FROM samples WHERE tombstone = 0"
            ).fetchone()[0],
        )
        self.assertIsNone(
            self.db.execute(
                "SELECT 1 FROM batches WHERE key = 'ambiguous-delete'"
            ).fetchone()
        )

    def test_stable_compatibility_point_retires_delayed_legacy_alias(self):
        date = "2026-01-01T00:00:00Z"
        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "step_count",
                    "units": "count",
                    "data": [{
                        "id": "stable-step",
                        "date": date,
                        "qty": 100,
                    }],
                }],
            },
        })
        self.db.execute("DELETE FROM compatible_alias_retirement")
        self.db.commit()

        with self.assertRaises(PartialBatch):
            ingest_lines(
                self.db,
                [json.dumps({
                    "id": f"step_count:{date}",
                    "type": "step_count",
                    "kind": "quantity",
                    "startDate": date,
                    "endDate": date,
                    "quantity": {"value": 100, "unit": "count"},
                })],
                batch_key="delayed-legacy-step",
            )

        self.assertEqual(
            [("healthAutoExport:stable-step", 0)],
            self.db.execute(
                """
                SELECT canonical_id, tombstone FROM samples
                WHERE type = 'step_count' AND tombstone = 0
                """
            ).fetchall(),
        )

    def test_same_timestamp_distinct_sources_are_not_aliases(self):
        date = "2026-01-01T00:00:00Z"
        ingest_lines(
            self.db,
            [json.dumps({
                "id": f"steps:{date}",
                "type": "steps",
                "kind": "quantity",
                "startDate": date,
                "endDate": date,
                "source": {"name": "Watch"},
                "quantity": {"value": 111, "unit": "count"},
            })],
        )

        result = ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [{
                        "id": "stable-phone",
                        "date": date,
                        "qty": 222,
                        "source": "Phone",
                    }],
                }],
            },
        })

        self.assertEqual((1, 0, False), result)
        self.assertEqual(
            2,
            self.db.execute(
                "SELECT COUNT(*) FROM samples WHERE tombstone = 0"
            ).fetchone()[0],
        )

    def test_two_stable_candidates_reject_one_legacy_alias_atomically(self):
        date = "2026-01-01T00:00:00Z"
        ingest_lines(
            self.db,
            [json.dumps({
                "id": f"steps:{date}",
                "type": "steps",
                "kind": "quantity",
                "startDate": date,
                "endDate": date,
                "quantity": {"value": 100, "unit": "count"},
            })],
        )
        ambiguous = {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [
                        {"id": "stable-a", "date": date, "qty": 100},
                        {"id": "stable-b", "date": date, "qty": 100},
                    ],
                }],
            },
        }

        with self.assertRaises(PartialBatch):
            ingest_compatible(self.db, ambiguous, batch_key="ambiguous-stable")

        self.assertEqual(
            [("apple.healthkit:steps:" + date, 0)],
            self.db.execute(
                """
                SELECT canonical_id, tombstone FROM samples
                WHERE tombstone = 0
                """
            ).fetchall(),
        )
        self.assertIsNone(
            self.db.execute(
                "SELECT 1 FROM batches WHERE key = 'ambiguous-stable'"
            ).fetchone()
        )

    def test_mapped_legacy_replay_cannot_change_fields_and_resurrect(self):
        date = "2026-01-01T00:00:00Z"
        legacy_id = f"steps:{date}"
        ingest_lines(
            self.db,
            [json.dumps({
                "id": legacy_id,
                "type": "steps",
                "kind": "quantity",
                "startDate": date,
                "endDate": date,
                "source": {"name": "Watch"},
                "quantity": {"value": 20, "unit": "count"},
            })],
        )
        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [{
                        "id": "stable",
                        "date": date,
                        "qty": 20,
                        "source": "Watch",
                    }],
                }],
            },
        })

        ingest_lines(
            self.db,
            [json.dumps({
                "canonicalId": "apple.healthkit:" + legacy_id,
                "id": legacy_id,
                "type": "distance",
                "kind": "quantity",
                "schemaVersion": 1,
                "recordVersion": 3,
                "sourceRecord": {
                    "id": legacy_id,
                    "store": "apple.healthkit",
                    "type": "distance",
                },
                "startDate": date,
                "endDate": date,
                "source": {"name": "Other"},
                "quantity": {"value": 999, "unit": "count"},
            })],
            batch_key="mutated-mapped-replay",
        )

        self.assertEqual(
            [("healthAutoExport:stable", 0)],
            self.db.execute(
                """
                SELECT canonical_id, tombstone FROM samples
                WHERE tombstone = 0
                """
            ).fetchall(),
        )

    def test_tombstoned_stable_signature_cannot_be_replaced(self):
        date = "2026-01-01T00:00:00Z"
        ingest_compatible(self.db, {
            "data": {
                "deletions": [{
                    "id": "stable",
                    "name": "steps",
                    "type": "steps",
                    "date": "",
                }],
            },
        })
        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [{
                        "id": "stable",
                        "date": date,
                        "qty": 20,
                    }],
                }],
            },
        })

        with self.assertRaises(PartialBatch):
            ingest_compatible(self.db, {
                "data": {
                    "metrics": [{
                        "name": "steps",
                        "units": "count",
                        "data": [{
                            "id": "stable",
                            "date": date,
                            "qty": 999,
                        }],
                    }],
                },
            })

        self.assertEqual(
            1,
            self.db.execute(
                "SELECT COUNT(*) FROM compatible_alias_retirement"
            ).fetchone()[0],
        )

    def test_stable_sleep_retires_date_less_legacy_sleep_alias(self):
        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "sleep_analysis",
                    "units": "hr",
                    "data": [{
                        "id": "stable-sleep",
                        "startDate": "2026-01-01T00:00:00Z",
                        "endDate": "2026-01-01T01:00:00Z",
                        "qty": 1,
                        "value": "Core",
                    }],
                }],
            },
        })
        self.db.execute("DELETE FROM compatible_alias_retirement")
        self.db.commit()

        with self.assertRaises(PartialBatch):
            ingest_lines(
                self.db,
                [json.dumps({
                    "id": "sleep_analysis:None",
                    "type": "sleep_analysis",
                    "kind": "category",
                    "value": 3,
                })],
                batch_key="delayed-legacy-sleep",
            )

        self.assertEqual(
            [("healthAutoExport:stable-sleep", 0)],
            self.db.execute(
                """
                SELECT canonical_id, tombstone FROM samples
                WHERE type = 'sleep_analysis' AND tombstone = 0
                """
            ).fetchall(),
        )

    def test_deleted_stable_sleep_keeps_date_less_legacy_retryable(self):
        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "sleep_analysis",
                    "units": "hr",
                    "data": [{
                        "id": "stable-sleep",
                        "startDate": "2026-01-01T00:00:00Z",
                        "endDate": "2026-01-01T01:00:00Z",
                        "qty": 1,
                        "value": "Core",
                    }],
                }],
            },
        })
        ingest_compatible(self.db, {
            "data": {
                "deletions": [{
                    "id": "stable-sleep",
                    "name": "sleep_analysis",
                    "type": "sleep_analysis",
                    "date": "",
                }],
            },
        })

        with self.assertRaises(PartialBatch):
            ingest_lines(
                self.db,
                [json.dumps({
                    "id": "sleep_analysis:None",
                    "type": "sleep_analysis",
                    "kind": "category",
                    "value": 3,
                })],
                batch_key="legacy-sleep-after-delete",
            )

    def test_same_batch_stable_replacement_resolves_legacy_before_deletion(self):
        date = "2026-01-01T00:00:00Z"
        ingest_lines(
            self.db,
            [json.dumps({
                "id": f"step_count:{date}",
                "type": "step_count",
                "kind": "quantity",
                "startDate": date,
                "endDate": date,
                "quantity": {"value": 100, "unit": "count"},
            })],
        )
        result = ingest_compatible(
            self.db,
            {
                "data": {
                    "metrics": [{
                        "name": "step_count",
                        "units": "count",
                        "data": [{
                            "id": "stable-step",
                            "date": date,
                            "qty": 100,
                        }],
                    }],
                    "deletions": [{
                        "id": "stable-step",
                        "name": "step_count",
                        "type": "HKQuantityTypeIdentifierStepCount",
                        "date": "",
                    }],
                },
            },
            batch_key="replacement-and-delete",
        )

        self.assertEqual((1, 2, False), result)
        self.assertEqual(
            0,
            self.db.execute(
                "SELECT COUNT(*) FROM samples WHERE tombstone = 0"
            ).fetchone()[0],
        )

    def test_duplicate_legacy_date_less_deletion_refuses_false_repair(self):
        date = "2026-01-01T00:00:00Z"
        ingest_lines(
            self.db,
            [json.dumps({
                "id": f"steps:{date}",
                "type": "steps",
                "kind": "quantity",
                "startDate": date,
                "endDate": date,
                "quantity": {"value": 100, "unit": "count"},
            })],
        )
        self.db.execute(
            "INSERT INTO batches (key, received_at, records) VALUES (?, ?, ?)",
            ("legacy-deletion", 0, 0),
        )
        self.db.commit()

        with self.assertRaises(PartialBatch):
            ingest_compatible(
                self.db,
                {
                    "data": {
                        "metrics": [{
                            "name": "steps",
                            "units": "count",
                            "data": [{"date": date, "qty": 100}],
                        }],
                        "deletions": [{
                            "id": "deleted-id",
                            "name": "steps",
                            "type": "steps",
                            "date": "",
                        }],
                    },
                },
                batch_key="legacy-deletion",
            )
        self.assertEqual(
            [(1, 0)],
            self.db.execute(
                "SELECT record_version, tombstone FROM samples ORDER BY tombstone"
            ).fetchall(),
        )

    def test_duplicate_legacy_dated_deletion_without_mapping_stays_retryable(self):
        date = "2026-01-01T00:00:00Z"
        ingest_lines(
            self.db,
            [json.dumps({
                "id": f"steps:{date}",
                "type": "steps",
                "kind": "quantity",
                "startDate": date,
                "endDate": date,
                "quantity": {"value": 100, "unit": "count"},
            })],
        )
        ingest_lines(
            self.db,
            [json.dumps({
                "id": "unavailable-in-old-row",
                "type": "steps",
                "kind": "quantity",
                "schemaVersion": 1,
                "recordVersion": 1,
                "sourceRecord": {
                    "id": "unavailable-in-old-row",
                    "store": "healthAutoExport",
                    "type": "steps",
                },
                "startDate": date,
                "endDate": date,
                "quantity": {"value": 100, "unit": "count"},
            })],
        )
        self.db.execute(
            "INSERT INTO batches (key, received_at, records) VALUES (?, ?, ?)",
            ("legacy-dated", 1, 0),
        )
        self.db.commit()

        with self.assertRaises(PartialBatch):
            ingest_compatible(
                self.db,
                {
                    "data": {
                        "deletions": [{
                            "id": "unavailable-in-old-row",
                            "name": "steps",
                            "type": "steps",
                            "date": date,
                        }],
                    },
                },
                batch_key="legacy-dated",
            )
        self.assertEqual(
            [(1, 0), (1, 0)],
            self.db.execute(
                """
                SELECT record_version, tombstone FROM samples
                ORDER BY canonical_id
                """
            ).fetchall(),
        )
        self.assertEqual(
            -1,
            self.db.execute(
                "SELECT deletions FROM batches WHERE key = 'legacy-dated'"
            ).fetchone()[0],
        )

    def test_duplicate_legacy_receipt_migrates_stable_id_before_acknowledging(self):
        date = "2026-01-01 12:00:00 +0000"
        legacy_id = f"steps:{date}"
        ingest_lines(
            self.db,
            [json.dumps({
                "id": legacy_id,
                "kind": "quantity",
                "quantity": {"unit": "count", "value": 100},
                "startDate": date,
                "type": "steps",
            })],
        )
        self.db.execute(
            "INSERT INTO batches (key, received_at, records) VALUES (?, ?, ?)",
            ("legacy-retry", 0, 1),
        )
        self.db.commit()

        self.assertEqual(
            (1, 1, True),
            ingest_compatible(
                self.db,
                {
                    "data": {
                        "metrics": [{
                            "name": "steps",
                            "units": "count",
                            "data": [{
                                "id": "stable-retry",
                                "date": "2026-01-01 07:00:00 -0500",
                                "qty": 100,
                            }],
                        }],
                    },
                },
                batch_key="legacy-retry",
            ),
        )
        self.assertEqual(
            [
                ("apple.healthkit:" + legacy_id, 1),
                ("healthAutoExport:stable-retry", 0),
            ],
            self.db.execute(
                """
                SELECT canonical_id, tombstone FROM samples
                ORDER BY canonical_id
                """
            ).fetchall(),
        )
        self.assertEqual(
            0,
            self.db.execute(
                "SELECT deletions FROM batches WHERE key = 'legacy-retry'"
            ).fetchone()[0],
        )

    def test_documented_heart_sleep_workout_and_deletion_shapes(self):
        envelope = {
            "data": {
                "metrics": [
                    {
                        "name": "heart_rate",
                        "units": "bpm",
                        "data": [{
                            "id": "heart-1",
                            "date": "2026-01-01 12:00:00 +0000",
                            "Min": 62,
                            "Avg": 62,
                            "Max": 62,
                            "source": "Watch",
                        }],
                    },
                    {
                        "name": "sleep_analysis",
                        "units": "hr",
                        "data": [{
                            "id": "sleep-1",
                            "startDate": "2026-01-01 00:00:00 +0000",
                            "endDate": "2026-01-01 01:00:00 +0000",
                            "qty": 1,
                            "value": "REM",
                            "source": "Watch",
                        }],
                    },
                ],
                "workouts": [{
                    "id": "workout-1",
                    "name": "Running",
                    "start": "2026-01-01 13:00:00 +0000",
                    "end": "2026-01-01 13:30:00 +0000",
                    "duration": 1_800,
                }],
                "deletions": [{
                    "id": "deleted-1",
                    "name": "heart_rate",
                    "type": "heart_rate",
                    "date": "",
                }],
            },
        }

        self.assertEqual(
            (3, 1, False),
            ingest_compatible(self.db, envelope, batch_key="documented"),
        )
        rows = self.db.execute(
            """
            SELECT kind, value, minimum, maximum, text_value,
                   duration_seconds, tombstone
            FROM samples ORDER BY kind, tombstone
            """
        ).fetchall()
        self.assertIn(("quantity", 62, 62, 62, None, None, 0), rows)
        self.assertIn(("category", 5, None, None, "REM", 3600, 0), rows)
        self.assertIn(("workout", 1800, None, None, "Running", 1800, 0), rows)
        self.assertTrue(any(row[-1] == 1 for row in rows))

    def test_unknown_sleep_stage_preserves_raw_value(self):
        self.assertEqual(
            (1, 0, False),
            ingest_compatible(self.db, {
                "data": {
                    "metrics": [{
                        "name": "sleep_analysis",
                        "units": "hr",
                        "data": [{
                            "id": "sleep-future",
                            "startDate": "2026-01-01 00:00:00 +0000",
                            "endDate": "2026-01-01 01:00:00 +0000",
                            "qty": 1,
                            "value": "Unspecified",
                            "rawValue": 99,
                        }],
                    }],
                },
            }),
        )
        self.assertEqual(
            (99, "Unspecified"),
            self.db.execute(
                "SELECT value, text_value FROM samples"
            ).fetchone(),
        )

    def test_compatible_source_id_binds_metric_to_retried_deletion(self):
        point = {
            "id": "source-record-1",
            "date": "2026-01-01 12:00:00 +0000",
            "qty": 100,
        }
        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [point],
                }],
            },
        })
        deletion = {
            "data": {
                "deletions": [{
                    "id": "source-record-1",
                    "name": "steps",
                    "type": "steps",
                    "date": "",
                }],
            },
        }

        self.assertEqual(
            (0, 1, False),
            ingest_compatible(self.db, deletion, batch_key="source-deletion"),
        )
        self.assertEqual(
            (0, 0, True),
            ingest_compatible(self.db, deletion, batch_key="source-deletion"),
        )
        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [{
                        "id": "source-record-2",
                        "date": "2026-01-01 13:00:00 +0000",
                        "qty": 200,
                    }],
                }],
            },
        })
        self.assertEqual(
            (0, 0, True),
            ingest_compatible(
                self.db,
                {
                    "data": {
                        "deletions": [{
                            "id": "source-record-2",
                            "name": "steps",
                            "type": "steps",
                            "date": "",
                        }],
                    },
                },
                batch_key="source-deletion",
            ),
        )
        self.assertEqual(
            [(2, 1), (1, 0)],
            self.db.execute(
                """
                SELECT record_version, tombstone FROM samples
                ORDER BY source_id
                """
            ).fetchall(),
        )

    def test_stable_id_retry_tombstones_the_legacy_name_date_alias(self):
        date = "2026-01-01 12:00:00 +0000"
        legacy_id = f"steps:{date}"
        ingest_lines(
            self.db,
            [json.dumps({
                "id": legacy_id,
                "kind": "quantity",
                "quantity": {"unit": "count", "value": 100},
                "startDate": date,
                "type": "steps",
            })],
        )
        envelope = {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [{
                        "id": "stable-1",
                        "date": "2026-01-01 07:00:00 -0500",
                        "qty": 100,
                    }],
                }],
            },
        }

        self.assertEqual(
            (1, 1, False),
            ingest_compatible(self.db, envelope, batch_key="stable-retry"),
        )
        self.assertEqual(
            [
                ("apple.healthkit:" + legacy_id, 1),
                ("healthAutoExport:stable-1", 0),
            ],
            self.db.execute(
                """
                SELECT canonical_id, tombstone FROM samples
                ORDER BY canonical_id
                """
            ).fetchall(),
        )

        ingest_compatible(self.db, {
            "data": {
                "deletions": [{
                    "id": "stable-1",
                    "name": "steps",
                    "type": "steps",
                    "date": "",
                }],
            },
        })
        self.assertEqual(
            0,
            self.db.execute(
                "SELECT COUNT(*) FROM samples WHERE tombstone = 0"
            ).fetchone()[0],
        )

    def test_stable_sleep_retires_the_legacy_none_alias(self):
        ingest_lines(
            self.db,
            [json.dumps({
                "id": "sleep_analysis:None",
                "kind": "quantity",
                "quantity": {"unit": "hr", "value": None},
                "type": "sleep_analysis",
            })],
        )

        with self.assertRaises(PartialBatch):
            ingest_compatible(self.db, {
                "data": {
                    "metrics": [{
                        "name": "sleep_analysis",
                        "units": "hr",
                        "data": [{
                            "id": "sleep-stable",
                            "startDate": "2026-01-01 00:00:00 +0000",
                            "endDate": "2026-01-01 01:00:00 +0000",
                            "qty": 1,
                            "value": "REM",
                            "rawValue": 5,
                        }],
                    }],
                },
            })
        self.assertEqual(
            [
                ("apple.healthkit:sleep_analysis:None", 0),
            ],
            self.db.execute(
                """
                SELECT canonical_id, tombstone FROM samples
                ORDER BY canonical_id
                """
            ).fetchall(),
        )

    def test_idless_compatible_metric_rejects_without_receipt(self):
        envelope = {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [{
                        "date": "2026-01-01 12:00:00 +0000",
                        "qty": 100,
                    }],
                }],
            },
        }

        with self.assertRaises(PartialBatch):
            ingest_compatible(self.db, envelope, batch_key="idless")
        self.assertEqual(0, self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0])
        self.assertEqual(0, self.db.execute("SELECT COUNT(*) FROM batches").fetchone()[0])

    def test_unrepresentable_compatible_item_rolls_back_without_receipt(self):
        envelope = {
            "data": {
                "metrics": [{
                    "name": "heart_rate",
                    "units": "bpm",
                    "data": [{
                        "id": "heart-aggregate",
                        "date": "2026-01-01 12:00:00 +0000",
                        "Min": 60,
                        "Avg": 62,
                        "Max": 64,
                    }],
                }],
                "workouts": [{
                    "id": "workout-1",
                    "name": "Running",
                    "start": "2026-01-01 13:00:00 +0000",
                    "end": "2026-01-01 13:30:00 +0000",
                    "duration": 1_800,
                }],
            },
        }

        with self.assertRaises(PartialBatch):
            ingest_compatible(self.db, envelope, batch_key="invalid-hae")
        self.assertEqual(0, self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0])
        self.assertEqual(0, self.db.execute("SELECT COUNT(*) FROM batches").fetchone()[0])

    def test_malformed_utf8_payload_rejects_atomically(self):
        with self.assertRaises(PartialBatch):
            receiver.ingest_payload(
                self.db,
                b'{"id":"bad","kind":"quantity","type":"st\xffeps"}\n',
                batch_key="bad-utf8",
            )
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM batches").fetchone()[0],
        )

    def test_strict_zip_rejects_atomically_but_legacy_file_imports(self):
        legacy = json.dumps({
            "id": "legacy",
            "kind": "quantity",
            "quantity": {"unit": "count", "value": 1},
            "schemaVersion": 1,
            "type": "steps",
        })
        legacy_path = Path(self.directory.name) / "legacy.ndjson"
        legacy_path.write_text(legacy + "\n")
        self.assertEqual((1, 0), ingest_file(self.db, legacy_path))

        archive = Path(self.directory.name) / "strict.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": legacy + "\n",
            },
        )
        with self.assertRaises(PartialBatch):
            ingest_file(self.db, archive)

        ambiguous_namespace = {
            "canonicalId": "a:b:c",
            "canonicalType": "activity.steps",
            "id": "c",
            "kind": "deletion",
            "lineage": [{"recordId": "c", "store": "a:b"}],
            "recordVersion": 99,
            "schemaVersion": 1,
            "sourceRecord": {
                "id": "c",
                "store": "a:b",
                "type": "steps",
            },
            "type": "steps",
        }
        archive = Path(self.directory.name) / "ambiguous-namespace.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": json.dumps(ambiguous_namespace) + "\n",
            },
        )
        with self.assertRaises(PartialBatch):
            ingest_file(self.db, archive)
        self.assertEqual(
            ["apple.healthkit:legacy"],
            [
                row[0] for row in self.db.execute(
                    "SELECT canonical_id FROM samples ORDER BY canonical_id"
                )
            ],
        )

    def test_substituted_strict_tombstone_cannot_overwrite_victim(self):
        victim = self.strict_record("victim")
        ingest_lines(self.db, [json.dumps(victim)])
        malicious = {
            "canonicalId": "apple.healthkit:victim",
            "canonicalType": "activity.steps",
            "id": "other",
            "kind": "deletion",
            "lineage": [{
                "recordId": "other",
                "store": "apple.healthkit",
            }],
            "recordVersion": 99,
            "schemaVersion": 1,
            "sourceRecord": {
                "id": "other",
                "store": "apple.healthkit",
                "type": "steps",
            },
            "type": "steps",
        }
        archive = Path(self.directory.name) / "substitution.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": json.dumps(malicious) + "\n",
            },
        )

        with self.assertRaises(PartialBatch):
            ingest_file(self.db, archive)

        self.assertEqual(
            ("apple.healthkit:victim", 0, 1),
            self.db.execute(
                "SELECT canonical_id, tombstone, record_version FROM samples"
            ).fetchone(),
        )

        forged_provenance = dict(malicious)
        forged_provenance["id"] = "victim"
        forged_provenance["sourceRecord"] = {
            "id": "attacker",
            "store": "apple.healthkit",
            "type": "steps",
        }
        forged_provenance["lineage"] = [{
            "recordId": "attacker",
            "store": "apple.healthkit",
        }]
        archive = Path(self.directory.name) / "forged-provenance.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": json.dumps(forged_provenance) + "\n",
            },
        )
        with self.assertRaises(PartialBatch):
            ingest_file(self.db, archive)

        attacker_source = "00000000-0000-0000-0000-000000000299"
        forged_error = {
            "canonicalId": "apple.healthkit:victim",
            "canonicalType": "archive.encoding-error",
            "id": "victim",
            "kind": "sampleEncodingError",
            "lineage": [{
                "recordId": attacker_source,
                "store": "apple.healthkit",
            }],
            "message": "forged",
            "parentCanonicalId": f"apple.healthkit:{attacker_source}",
            "recordVersion": 99,
            "schemaVersion": 1,
            "sourceRecord": {
                "id": attacker_source,
                "store": "apple.healthkit",
                "type": "steps",
            },
            "type": "steps",
        }
        archive = Path(self.directory.name) / "forged-error.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": json.dumps(forged_error) + "\n",
            },
        )
        with self.assertRaises(PartialBatch):
            ingest_file(self.db, archive)

        canonical_source = "00000000-0000-0000-0000-000000000299"
        aliased_source = canonical_source.replace("-", "").upper()
        aliased_error_id = encoding_failure_id(
            canonical_source,
            "steps",
        )
        aliased_error = {
            "canonicalId": f"apple.healthkit:{aliased_error_id}",
            "canonicalType": "archive.encoding-error",
            "id": aliased_error_id,
            "kind": "sampleEncodingError",
            "lineage": [{
                "recordId": aliased_source,
                "store": "apple.healthkit",
            }],
            "message": "alias",
            "parentCanonicalId": f"apple.healthkit:{aliased_source}",
            "recordVersion": 99,
            "schemaVersion": 1,
            "sourceRecord": {
                "id": aliased_source,
                "store": "apple.healthkit",
                "type": "steps",
            },
            "type": "steps",
        }
        archive = Path(self.directory.name) / "aliased-error.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": json.dumps(aliased_error) + "\n",
            },
        )
        with self.assertRaises(PartialBatch):
            ingest_file(self.db, archive)

        bad_parent = {
            "canonicalId": "apple.healthkit:detail",
            "canonicalType": "series.readings",
            "endDate": "2026-01-01T00:01:00Z",
            "id": "detail",
            "kind": "quantitySeriesReadings",
            "lineage": [{
                "recordId": "other",
                "store": "apple.healthkit",
            }],
            "parentCanonicalId": "apple.healthkit:victim",
            "recordVersion": 1,
            "sample": "other",
            "schemaVersion": 1,
            "sourceRecord": {
                "id": "other",
                "store": "apple.healthkit",
                "type": "steps",
            },
            "startDate": "2026-01-01T00:00:00Z",
            "type": "steps",
        }
        archive = Path(self.directory.name) / "bad-parent.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": json.dumps(bad_parent) + "\n",
            },
        )
        with self.assertRaises(PartialBatch):
            ingest_file(self.db, archive)

    def test_ignored_zip_bomb_rejects_without_committing_records(self):
        record = self.strict_record("strict")
        archive = Path(self.directory.name) / "bomb.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": json.dumps(record) + "\n",
                "ignored.bin": b"\0" * 32_768,
            },
        )

        with (
            mock.patch.object(receiver, "MAX_ENTRY_COMPRESSION_RATIO", 2),
            mock.patch.object(receiver, "ENTRY_RATIO_SLACK_BYTES", 0),
            self.assertRaises(PartialBatch),
        ):
            ingest_file(self.db, archive)
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )

    def test_corrupt_ignored_zip_entry_rejects_without_committing_records(self):
        archive = Path(self.directory.name) / "corrupt-ignored.zip"
        marker = b"unique-ignored-payload"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr(
                "hozz-manifest.json",
                json.dumps(self.manifest(1)),
                compress_type=zipfile.ZIP_DEFLATED,
            )
            output.writestr(
                "records.ndjson",
                json.dumps(self.strict_record("strict")) + "\n",
                compress_type=zipfile.ZIP_DEFLATED,
            )
            output.writestr(
                "ignored.bin",
                marker,
                compress_type=zipfile.ZIP_STORED,
            )
        payload = archive.read_bytes()
        self.assertIn(marker, payload)
        archive.write_bytes(payload.replace(marker, b"X" + marker[1:], 1))

        with self.assertRaises(zipfile.BadZipFile):
            ingest_file(self.db, archive)
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )

    def test_zip_entry_count_is_rejected_before_zipfile_allocation(self):
        archive = Path(self.directory.name) / "many.zip"
        self.write_zip(
            archive,
            {
                "one.ndjson": "",
                "two.bin": "",
                "three.bin": "",
            },
        )

        with (
            mock.patch.object(receiver, "MAX_ZIP_ENTRIES", 2),
            mock.patch.object(
                receiver.zipfile,
                "ZipFile",
                side_effect=AssertionError("central directory was allocated"),
            ),
            self.assertRaises(PartialBatch),
        ):
            ingest_file(self.db, archive)

    def test_forged_eocd_entry_count_is_rejected_before_zipfile_allocation(self):
        archive = Path(self.directory.name) / "forged-count.zip"
        self.write_zip(
            archive,
            {
                "one.ndjson": "",
                "two.bin": "",
                "three.bin": "",
            },
        )
        payload = bytearray(archive.read_bytes())
        eocd = payload.rfind(b"PK\x05\x06")
        struct.pack_into("<H", payload, eocd + 8, 1)
        struct.pack_into("<H", payload, eocd + 10, 1)
        archive.write_bytes(payload)

        with (
            mock.patch.object(
                receiver.zipfile,
                "ZipFile",
                side_effect=AssertionError("central directory was allocated"),
            ),
            self.assertRaises(PartialBatch),
        ):
            ingest_file(self.db, archive)

    def test_unsupported_or_encrypted_zip_rejects_before_decompression(self):
        for name, offset, value in (
            ("unsupported", 10, 99),
            ("encrypted", 8, 1),
        ):
            archive = Path(self.directory.name) / f"{name}.zip"
            self.write_zip(archive, {"records.ndjson": ""})
            payload = bytearray(archive.read_bytes())
            central = payload.find(b"PK\x01\x02")
            struct.pack_into("<H", payload, central + offset, value)
            archive.write_bytes(payload)

            with (
                mock.patch.object(
                    receiver.zipfile,
                    "ZipFile",
                    side_effect=AssertionError("decompressor was constructed"),
                ),
                self.assertRaises(PartialBatch),
            ):
                ingest_file(self.db, archive)

    def test_zip64_directory_metadata_is_used_for_classic_sentinels(self):
        path = Path(self.directory.name) / "zip64-directory.zip"
        central = b"PK\x01\x02" + bytes(42)
        zip64_offset = len(central)
        zip64 = bytearray(56)
        zip64[:4] = b"PK\x06\x06"
        struct.pack_into("<Q", zip64, 4, 44)
        struct.pack_into("<Q", zip64, 24, 1)
        struct.pack_into("<Q", zip64, 32, 1)
        struct.pack_into("<Q", zip64, 40, len(central))
        struct.pack_into("<Q", zip64, 48, 0)
        locator = bytearray(20)
        locator[:4] = b"PK\x06\x07"
        struct.pack_into("<Q", locator, 8, zip64_offset)
        eocd = bytearray(22)
        eocd[:4] = b"PK\x05\x06"
        struct.pack_into("<H", eocd, 8, 1)
        struct.pack_into("<H", eocd, 10, 1)
        struct.pack_into("<I", eocd, 12, 0xFFFFFFFF)
        struct.pack_into("<I", eocd, 16, 0xFFFFFFFF)
        path.write_bytes(central + zip64 + locator + eocd)

        receiver.preflight_zip_entry_count(path)

    def test_strict_zip_rejects_non_rfc3339_timestamp(self):
        record = self.strict_record("naive-time")
        record["startDate"] = "20260101T000000+00:00"
        archive = Path(self.directory.name) / "naive.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": json.dumps(record) + "\n",
            },
        )

        with self.assertRaises(PartialBatch):
            ingest_file(self.db, archive)
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )

    def test_strict_zip_accepts_apple_manifest_without_record_count(self):
        manifest = self.manifest(1)
        manifest.pop("recordCount")
        archive = Path(self.directory.name) / "apple.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(manifest),
                "records.ndjson": json.dumps(self.strict_record("apple")) + "\n",
            },
        )

        self.assertEqual((1, 0), ingest_file(self.db, archive))

    def test_strict_run_record_preserves_exact_representation(self):
        run = (
            '  { "kind" : "typeSummary", "schemaVersion" : 1, '
            '"type" : "steps", "state" : "complete", "ratio" : 1.00 }  '
        )
        archive = Path(self.directory.name) / "verbatim-run.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(0)),
                "records.ndjson": run + "\r\n",
            },
        )

        self.assertEqual((0, 0), ingest_file(self.db, archive))
        self.assertEqual(
            run,
            self.db.execute(
                "SELECT raw FROM archive_run_records"
            ).fetchone()[0],
        )

    def test_plain_v1_run_record_preserves_exact_representation(self):
        run = (
            ' { "kind" : "typeSummary", "schemaVersion" : 1, '
            '"type" : "steps", "state" : "complete", "ratio" : 1.00 } '
        )
        path = Path(self.directory.name) / "plain-run.ndjson"
        path.write_text(run + "\n")

        self.assertEqual((0, 0), ingest_file(self.db, path))
        self.assertEqual(
            run,
            self.db.execute(
                "SELECT raw FROM archive_run_records"
            ).fetchone()[0],
        )

    def test_committed_zip_retry_survives_missing_watcher_receipt(self):
        archive = Path(self.directory.name) / "retry.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": (
                    json.dumps(self.strict_record("retry")) + "\n"
                ),
            },
        )

        self.assertEqual((1, 0), ingest_file(self.db, archive))
        self.assertEqual((0, 0), ingest_file(self.db, archive))

    def test_zip_rejects_undeclared_ndjson_without_committing(self):
        archive = Path(self.directory.name) / "extra-stream.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": json.dumps(self.strict_record("declared")) + "\n",
                "extra.ndjson": json.dumps(self.strict_record("hidden")) + "\n",
            },
        )

        with self.assertRaises(PartialBatch):
            ingest_file(self.db, archive)
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )

    def test_strict_zip_rejects_non_json_numeric_constants(self):
        raw = json.dumps(self.strict_record("constant"))[:-1] + (
            ', "metadata": {"bad": NaN}}'
        )
        archive = Path(self.directory.name) / "nan.zip"
        self.write_zip(
            archive,
            {
                "hozz-manifest.json": json.dumps(self.manifest(1)),
                "records.ndjson": raw + "\n",
            },
        )

        with self.assertRaises(PartialBatch):
            ingest_file(self.db, archive)
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )

    def test_run_and_coverage_records_are_preserved_per_run(self):
        summary = {
            "kind": "typeCoverage",
            "schemaVersion": 1,
            "type": "steps",
            "state": "anchorClosed",
            "complete": True,
            "observedAt": "2026-01-01T00:00:00Z",
        }
        for run in ("run-a", "run-b"):
            ingest_lines(self.db, [
                json.dumps({
                    "kind": "manifest",
                    "schemaVersion": 1,
                    "run": run,
                    "createdAt": "2026-01-01T00:00:00Z",
                }),
                json.dumps(summary),
            ])

        rows = self.db.execute(
            "SELECT kind, raw FROM archive_run_records ORDER BY rowid"
        ).fetchall()
        self.assertEqual(4, len(rows))
        self.assertEqual(2, sum(kind == "typeCoverage" for kind, _ in rows))

    def test_run_occurrence_keys_are_bounded_and_roll_back_atomically(self):
        lines = [
            json.dumps({
                "kind": "typeSummary",
                "schemaVersion": 1,
                "state": "one",
                "type": "steps",
            }),
            json.dumps({
                "kind": "typeSummary",
                "schemaVersion": 1,
                "state": "two",
                "type": "heart",
            }),
        ]

        with (
            mock.patch.object(receiver, "MAX_RUN_OCCURRENCE_KEYS", 1),
            self.assertRaises(PartialBatch),
        ):
            ingest_lines(self.db, lines)

        self.assertEqual(
            0,
            self.db.execute(
                "SELECT COUNT(*) FROM archive_run_records"
            ).fetchone()[0],
        )

    def test_split_batches_scope_identical_run_records_independently(self):
        summary = json.dumps({
            "kind": "typeSummary",
            "schemaVersion": 1,
            "state": "complete",
            "type": "steps",
        })

        ingest_lines(self.db, [summary], batch_key="part-a")
        ingest_lines(self.db, [summary], batch_key="part-b")
        ingest_lines(self.db, [summary], batch_key="part-a")

        count = self.db.execute(
            "SELECT COUNT(*) FROM archive_run_records"
        ).fetchone()[0]
        self.assertEqual(2, count)

    def test_reentered_explicit_run_across_batches_keeps_occurrences(self):
        summary = json.dumps({
            "kind": "typeSummary",
            "schemaVersion": 1,
            "state": "complete",
            "type": "steps",
        })
        ingest_lines(
            self.db,
            [
                json.dumps({
                    "createdAt": "2026-01-01T00:00:00Z",
                    "kind": "manifest",
                    "run": "shared-run",
                    "schemaVersion": 1,
                }),
                summary,
            ],
            batch_key="part-one",
        )
        ingest_lines(
            self.db,
            [
                json.dumps({
                    "kind": "resume",
                    "resumedAt": "2026-01-01T00:00:01Z",
                    "run": "shared-run",
                    "schemaVersion": 1,
                }),
                summary,
            ],
            batch_key="part-two",
        )

        self.assertEqual(
            4,
            self.db.execute(
                "SELECT COUNT(*) FROM archive_run_records"
            ).fetchone()[0],
        )

    def test_legacy_run_normalization_matches_android_form(self):
        legacy = json.dumps({
            "kind": "typeCoverage",
            "type": "steps",
            "state": "anchorClosed",
            "complete": True,
            "observedAt": "2026-01-01T00:00:00Z",
        })
        normalized = json.dumps(
            {
                **json.loads(legacy),
                "schemaVersion": 1,
            },
            sort_keys=True,
            separators=(",", ":"),
        )

        ingest_lines(self.db, [legacy])
        ingest_lines(self.db, [normalized])

        self.assertEqual(
            1,
            self.db.execute(
                "SELECT COUNT(*) FROM archive_run_records"
            ).fetchone()[0],
        )

    def test_canonical_retry_repairs_unknown_deletion_receipt(self):
        record = self.strict_record("legacy-receipt")
        ingest_lines(self.db, [json.dumps(record)])
        self.db.execute(
            """
            INSERT INTO batches (key, received_at, records, deletions)
            VALUES ('legacy-canonical', 0, 1, -1)
            """
        )
        self.db.commit()
        deletion = {
            **record,
            "deleted": True,
            "kind": "deletion",
            "recordVersion": 2,
        }

        result = ingest_lines(
            self.db,
            [json.dumps(deletion), json.dumps(record)],
            batch_key="legacy-canonical",
        )

        self.assertEqual((0, 1, True), result)
        stored = self.db.execute(
            """
            SELECT record_version, tombstone, kind
            FROM samples WHERE canonical_id = ?
            """,
            (record["canonicalId"],),
        ).fetchone()
        self.assertEqual((2, 1, "deletion"), stored)
        self.assertEqual(
            1,
            self.db.execute(
                "SELECT deletions FROM batches WHERE key = 'legacy-canonical'"
            ).fetchone()[0],
        )
        self.assertEqual(
            (0, 0, True),
            ingest_lines(
                self.db,
                [json.dumps(record)],
                batch_key="legacy-canonical",
            ),
        )

    def test_failed_canonical_legacy_retry_keeps_receipt_unknown(self):
        record = self.strict_record("legacy-rollback")
        ingest_lines(self.db, [json.dumps(record)])
        self.db.execute(
            """
            INSERT INTO batches (key, received_at, records, deletions)
            VALUES ('legacy-rollback', 0, 1, -1)
            """
        )
        self.db.commit()
        deletion = {
            **record,
            "kind": "deletion",
            "recordVersion": 2,
        }

        with self.assertRaises(PartialBatch):
            ingest_lines(
                self.db,
                [json.dumps(deletion), "not-json"],
                batch_key="legacy-rollback",
            )

        self.assertEqual(
            (1, 0),
            self.db.execute(
                """
                SELECT record_version, tombstone FROM samples
                WHERE canonical_id = ?
                """,
                (record["canonicalId"],),
            ).fetchone(),
        )
        self.assertEqual(
            -1,
            self.db.execute(
                "SELECT deletions FROM batches WHERE key = 'legacy-rollback'"
            ).fetchone()[0],
        )

    def test_plain_append_during_ingest_rolls_back_without_receipts(self):
        path = Path(self.directory.name) / "hozz-growing.ndjson"
        first = json.dumps(self.strict_record("first"))
        second = json.dumps(self.strict_record("second"))
        path.write_text(first + "\n")
        original = receiver.iter_ndjson_lines

        def append_after_first(stream):
            for index, line in enumerate(original(stream)):
                yield line
                if index == 0:
                    with path.open("a") as output:
                        output.write(second + "\n")

        with (
            mock.patch.object(receiver, "iter_ndjson_lines", append_after_first),
            self.assertRaises(PartialBatch),
        ):
            ingest_file(self.db, path, watch_receipt_name=path.name)

        self.assertEqual(0, self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0])
        self.assertEqual(0, self.db.execute("SELECT COUNT(*) FROM batches").fetchone()[0])
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM ingested_files").fetchone()[0],
        )

        self.assertEqual(
            (2, 0),
            ingest_file(self.db, path, watch_receipt_name=path.name),
        )
        self.assertEqual(
            1,
            self.db.execute("SELECT COUNT(*) FROM ingested_files").fetchone()[0],
        )

    def test_json_array_file_keeps_descriptor_open_for_snapshot_verification(self):
        path = Path(self.directory.name) / "hozz-array.json"
        path.write_text(json.dumps([
            self.strict_record("array-one"),
            self.strict_record("array-two"),
        ]))

        self.assertEqual(
            (2, 0),
            ingest_file(self.db, path, watch_receipt_name=path.name),
        )
        self.assertEqual(
            2,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )
        self.assertEqual(
            1,
            self.db.execute("SELECT COUNT(*) FROM ingested_files").fetchone()[0],
        )

    def test_metadata_only_rewrite_does_not_duplicate_run_records(self):
        path = Path(self.directory.name) / "hozz-run.ndjson"
        path.write_text(json.dumps({
            "kind": "typeSummary",
            "schemaVersion": 1,
            "type": "heart.rate",
            "state": "complete",
        }) + "\n")
        self.assertEqual(
            (0, 0),
            ingest_file(self.db, path, watch_receipt_name=path.name),
        )
        before = self.db.execute(
            "SELECT COUNT(*) FROM archive_run_records"
        ).fetchone()[0]

        stat = path.stat()
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000))
        self.assertEqual(
            (0, 0),
            ingest_file(self.db, path, watch_receipt_name=path.name),
        )

        self.assertEqual(
            before,
            self.db.execute(
                "SELECT COUNT(*) FROM archive_run_records"
            ).fetchone()[0],
        )

    def test_legacy_filename_receipt_does_not_bless_reused_name(self):
        path = Path(self.directory.name) / "hozz-old.ndjson"
        path.write_text(
            json.dumps(self.strict_record("already-received"))
            + "\n"
            + json.dumps({
                "kind": "typeSummary",
                "schemaVersion": 1,
                "type": "heart.rate",
                "state": "complete",
            })
            + "\n"
        )
        self.db.execute(
            """
            INSERT INTO batches (key, received_at, records, deletions)
            VALUES (?, 0, 1, 0)
            """,
            (f"file:{path.name}",),
        )
        self.db.commit()

        self.assertEqual(
            (1, 0),
            ingest_file(self.db, path, watch_receipt_name=path.name),
        )

        self.assertEqual(
            1,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )
        self.assertEqual(
            1,
            self.db.execute(
                "SELECT COUNT(*) FROM batches WHERE key LIKE 'file:v3:%'"
            ).fetchone()[0],
        )
        self.assertEqual(
            1,
            self.db.execute(
                "SELECT COUNT(*) FROM archive_run_records"
            ).fetchone()[0],
        )

    def test_legacy_filename_receipt_reuses_run_scope_without_duplication(self):
        path = Path(self.directory.name) / "hozz-old-run.ndjson"
        run = json.dumps({
            "kind": "typeSummary",
            "schemaVersion": 1,
            "type": "heart.rate",
            "state": "complete",
        })
        path.write_text(run + "\n")
        legacy_key = f"file:{path.name}"
        ingest_lines(self.db, [run], batch_key=legacy_key)
        receiver.record_file_receipt(
            self.db,
            path.name,
            receiver.file_snapshot(path.stat()),
        )
        self.db.commit()
        self.assertEqual(
            1,
            self.db.execute(
                "SELECT COUNT(*) FROM archive_run_records"
            ).fetchone()[0],
        )
        self.assertEqual(
            (0, 0),
            ingest_file(self.db, path, watch_receipt_name=path.name),
        )
        self.assertEqual(
            1,
            self.db.execute(
                "SELECT COUNT(*) FROM archive_run_records"
            ).fetchone()[0],
        )

    def test_null_snapshot_legacy_receipt_is_probed_without_run_duplication(self):
        path = Path(self.directory.name) / "hozz-upgraded-run.ndjson"
        run = json.dumps({
            "kind": "typeSummary",
            "schemaVersion": 1,
            "type": "heart.rate",
            "state": "complete",
        })
        path.write_text(run + "\n")
        legacy_key = f"file:{path.name}"
        ingest_lines(self.db, [run], batch_key=legacy_key)
        self.db.execute(
            """
            INSERT INTO ingested_files (name, ingested_at)
            VALUES (?, 0)
            """,
            (path.name,),
        )
        self.db.commit()

        self.assertEqual(
            (0, 0),
            ingest_file(self.db, path, watch_receipt_name=path.name),
        )

        self.assertEqual(
            1,
            self.db.execute(
                "SELECT COUNT(*) FROM archive_run_records"
            ).fetchone()[0],
        )
        self.assertEqual(
            1,
            self.db.execute(
                "SELECT COUNT(*) FROM batches WHERE key LIKE 'file:v3:%'"
            ).fetchone()[0],
        )
        self.assertIsNotNone(
            self.db.execute(
                """
                SELECT 1 FROM ingested_files
                WHERE name = ? AND device IS NOT NULL
                """,
                (path.name,),
            ).fetchone()
        )
        self.assertEqual(
            (0, 0),
            ingest_file(self.db, path, watch_receipt_name=path.name),
        )
        self.assertEqual(
            1,
            self.db.execute(
                "SELECT COUNT(*) FROM archive_run_records"
            ).fetchone()[0],
        )

    def test_file_verification_io_failure_is_transient(self):
        path = Path(self.directory.name) / "hozz-transient.ndjson"
        path.write_text(json.dumps(self.strict_record("transient")) + "\n")

        with (
            mock.patch.object(Path, "stat", side_effect=OSError("temporarily unavailable")),
            self.assertRaises(receiver.TransientFileError),
        ):
            ingest_file(self.db, path, watch_receipt_name=path.name)

        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )
        self.assertEqual(
            0,
            self.db.execute("SELECT COUNT(*) FROM ingested_files").fetchone()[0],
        )

        self.assertEqual(
            (1, 0),
            ingest_file(self.db, path, watch_receipt_name=path.name),
        )

        self.assertEqual(
            1,
            self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
        )

    def test_slow_header_does_not_block_healthy_request(self):
        server, thread = self.start_server(header_timeout=0.15)
        slow = socket.create_connection(server.server_address, timeout=1)
        try:
            slow.sendall(b"POST / HTTP/1.1\r\nHost: localhost\r\n")
            status, _ = self.healthy_post(server, "healthy-header")
            self.assertEqual(200, status)
            time.sleep(0.25)
            slow.settimeout(1)
            self.assertEqual(b"", slow.recv(1))
        finally:
            slow.close()
            self.stop_server(server, thread)

    def test_partial_body_times_out_without_receipt(self):
        server, thread = self.start_server(body_timeout=0.15)
        slow = socket.create_connection(server.server_address, timeout=1)
        try:
            slow.sendall(
                b"POST / HTTP/1.1\r\n"
                b"Host: localhost\r\n"
                b"Authorization: test-token\r\n"
                b"Idempotency-Key: partial-body\r\n"
                b"Content-Length: 100\r\n\r\n{"
            )
            time.sleep(0.25)
            slow.settimeout(1)
            self.assertEqual(b"", slow.recv(1))
            self.assertEqual(
                0,
                self.db.execute("SELECT COUNT(*) FROM batches").fetchone()[0],
            )
        finally:
            slow.close()
            self.stop_server(server, thread)

    def test_completed_body_is_not_timed_out_during_ingestion(self):
        server, thread = self.start_server(body_timeout=0.05)
        original = receiver.ingest_seekable_stream

        def slow_ingest(*args, **kwargs):
            time.sleep(0.15)
            return original(*args, **kwargs)

        try:
            with mock.patch.object(
                receiver,
                "ingest_seekable_stream",
                slow_ingest,
            ):
                status, _ = self.healthy_post(server, "slow-processing")
            self.assertEqual(200, status)
            self.assertEqual(
                1,
                self.db.execute(
                    "SELECT COUNT(*) FROM batches WHERE key = 'slow-processing'"
                ).fetchone()[0],
            )
        finally:
            self.stop_server(server, thread)

    def test_concurrent_requests_serialize_database_access(self):
        server, thread = self.start_server()
        original = receiver.ingest_seekable_stream
        active = maximum = 0
        lock = threading.Lock()

        def observed(*args, **kwargs):
            nonlocal active, maximum
            with lock:
                active += 1
                maximum = max(maximum, active)
            try:
                time.sleep(0.05)
                return original(*args, **kwargs)
            finally:
                with lock:
                    active -= 1

        results = []
        with mock.patch.object(receiver, "ingest_seekable_stream", observed):
            workers = [
                threading.Thread(
                    target=lambda key=key: results.append(
                        self.healthy_post(server, key)[0]
                    )
                )
                for key in ("concurrent-a", "concurrent-b")
            ]
            for worker in workers:
                worker.start()
            for worker in workers:
                worker.join(timeout=2)
        self.stop_server(server, thread)

        self.assertEqual([200, 200], sorted(results))
        self.assertEqual(1, maximum)

    def test_slow_tls_handshake_runs_outside_accept_loop(self):
        server, thread = self.start_server()
        started = threading.Event()

        class FakeTLSContext:
            calls = 0
            lock = threading.Lock()

            def wrap_socket(self, request, server_side):
                self.assert_server(server_side)
                with self.lock:
                    self.calls += 1
                    call = self.calls
                if call == 1:
                    started.set()
                    time.sleep(0.25)
                    raise socket.timeout("handshake deadline")
                return request

            def assert_server(self, server_side):
                if not server_side:
                    raise AssertionError("receiver TLS must use server mode")

        server.tls_context = FakeTLSContext()
        slow = socket.create_connection(server.server_address, timeout=1)
        try:
            self.assertTrue(started.wait(timeout=1))
            began = time.monotonic()
            status, _ = self.healthy_post(server, "healthy-during-tls")
            self.assertEqual(200, status)
            self.assertLess(time.monotonic() - began, 0.2)
        finally:
            slow.close()
            self.stop_server(server, thread)

    def start_server(
        self,
        header_timeout=1,
        body_timeout=1,
    ):
        args = SimpleNamespace(
            host="127.0.0.1",
            port=0,
            cert=None,
            key=None,
            database=str(self.database),
            token="test-token",
            allow_unauthenticated=False,
            tls_timeout=1,
            header_timeout=header_timeout,
            body_timeout=body_timeout,
            max_connections=4,
        )
        server = receiver.create_receiver_server(args, db=self.db)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        return server, thread

    def stop_server(self, server, thread):
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    def healthy_post(self, server, key):
        body = json.dumps(self.strict_record(key))
        connection = http.client.HTTPConnection(
            server.server_address[0],
            server.server_address[1],
            timeout=2,
        )
        connection.request(
            "POST",
            "/",
            body=body,
            headers={
                "Authorization": "test-token",
                "Idempotency-Key": key,
                "Content-Type": "application/json",
            },
        )
        response = connection.getresponse()
        payload = response.read()
        connection.close()
        return response.status, payload

    def manifest(self, record_count):
        return {
            "archiveId": "fixture",
            "createdAt": "2026-01-01T00:00:00Z",
            "format": "hozz-ndjson",
            "recordCount": record_count,
            "recordSchema": "hozz/v1/canonical-record",
            "recordsEntry": "records.ndjson",
            "schemaVersion": 1,
        }

    def strict_record(self, source_id):
        return {
            "canonicalId": f"apple.healthkit:{source_id}",
            "canonicalType": "activity.steps",
            "endDate": "2026-01-01T00:01:00Z",
            "id": source_id,
            "kind": "quantity",
            "lineage": [{
                "recordId": source_id,
                "store": "apple.healthkit",
            }],
            "quantity": {"unit": "count", "value": 1},
            "recordVersion": 1,
            "schemaVersion": 1,
            "sourceRecord": {
                "id": source_id,
                "store": "apple.healthkit",
                "type": "steps",
            },
            "startDate": "2026-01-01T00:00:00Z",
            "type": "steps",
        }

    def write_zip(self, path, entries):
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, value in entries.items():
                archive.writestr(name, value)


if __name__ == "__main__":
    unittest.main()
