import contextlib
import io
import json
import sqlite3
import struct
import tempfile
import tracemalloc
import unittest
import zipfile
from pathlib import Path
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
                    "name": "steps",
                    "units": "count",
                    "data": [{
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

    def test_compatible_deletion_before_metric_prevents_resurrection(self):
        date = "2026-01-01T00:00:00Z"
        ingest_compatible(self.db, {
            "data": {
                "deletions": [{"name": "steps", "date": date}],
            },
        })
        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [{"date": date, "qty": 100}],
                }],
            },
        })

        row = self.db.execute(
            "SELECT record_version, tombstone FROM samples"
        ).fetchone()
        self.assertEqual((2, 1), row)

    def test_duplicate_legacy_deletion_batch_repairs_missing_tombstone(self):
        date = "2026-01-01T00:00:00Z"
        self.db.execute(
            "INSERT INTO batches VALUES (?, ?, ?)",
            ("legacy-deletion", 0, 0),
        )
        self.db.commit()

        stored, deleted, duplicate = ingest_compatible(
            self.db,
            {
                "data": {
                    "deletions": [{"name": "steps", "date": date}],
                },
            },
            batch_key="legacy-deletion",
        )
        ingest_compatible(self.db, {
            "data": {
                "metrics": [{
                    "name": "steps",
                    "units": "count",
                    "data": [{"date": date, "qty": 100}],
                }],
            },
        })

        self.assertTrue(duplicate)
        self.assertEqual(0, stored)
        self.assertEqual(1, deleted)
        self.assertEqual(
            (2, 1),
            self.db.execute(
                "SELECT record_version, tombstone FROM samples"
            ).fetchone(),
        )

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
