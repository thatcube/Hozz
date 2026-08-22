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

Why this is safe to retry against: every record carries HealthKit's own
identifier, so storing one twice is an INSERT OR REPLACE of identical data, and
every batch carries an Idempotency-Key, so a batch that arrives twice is
recognised and skipped. Deletions are explicit, so your copy stays in step when
something is removed from Health.
"""

import argparse
import json
import os
import sqlite3
import sys
import time
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
    id          TEXT PRIMARY KEY,
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

CREATE TABLE IF NOT EXISTS batches (
    key         TEXT PRIMARY KEY,
    received_at REAL NOT NULL,
    records     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS ingested_files (
    name        TEXT PRIMARY KEY,
    ingested_at REAL NOT NULL
);
"""


def connect(path):
    db = sqlite3.connect(path, check_same_thread=False)
    db.executescript(SCHEMA)
    return db


def ingest_lines(db, lines, batch_key=None):
    """Store one batch. Returns (stored, deleted, skipped_duplicate_batch)."""
    if batch_key:
        seen = db.execute(
            "SELECT 1 FROM batches WHERE key = ?", (batch_key,)
        ).fetchone()
        if seen:
            # Hozz resends a batch when a response was lost. The data is
            # already here, so acknowledging without storing it again is
            # exactly right.
            return 0, 0, True

    stored = deleted = 0
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue

        kind = record.get("kind")
        # Run bookkeeping, not health data.
        if kind in {
            "manifest", "completion", "typeSummary", "typeError",
            "resume", "hozzConnectionTest",
        }:
            continue

        identifier = record.get("id")
        if not identifier:
            continue

        if kind == "deletion":
            db.execute("DELETE FROM samples WHERE id = ?", (identifier,))
            deleted += 1
            continue

        quantity = record.get("quantity") or {}
        source = record.get("source") or {}
        db.execute(
            "INSERT OR REPLACE INTO samples "
            "(id, type, kind, start_date, end_date, value, unit, source, raw) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                identifier,
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
        stored += 1

    if batch_key:
        db.execute(
            "INSERT OR IGNORE INTO batches VALUES (?, ?, ?)",
            (batch_key, time.time(), stored),
        )
    db.commit()
    return stored, deleted, False


def ingest_payload(db, payload, batch_key=None):
    """Handle NDJSON, a JSON array, or the compatible envelope."""
    text = payload.decode("utf-8", errors="replace").strip()
    if not text:
        return 0, 0, False

    if text.startswith("["):
        try:
            return ingest_lines(
                db,
                [json.dumps(item) for item in json.loads(text)],
                batch_key,
            )
        except json.JSONDecodeError:
            pass

    if text.startswith("{") and '"data"' in text[:200]:
        try:
            envelope = json.loads(text)
            return ingest_compatible(db, envelope, batch_key)
        except json.JSONDecodeError:
            pass

    return ingest_lines(db, text.splitlines(), batch_key)


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
    for deletion in data.get("deletions", []):
        lines.append(json.dumps({"kind": "deletion", "id": deletion.get("id")}))
    return ingest_lines(db, lines, batch_key)


def serve(args):
    db = connect(args.database)

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            if args.token:
                supplied = self.headers.get("Authorization", "")
                if supplied != args.token:
                    return self.finish_with(401, {"error": "unauthorized"})

            length = int(self.headers.get("Content-Length", 0))
            payload = self.rfile.read(length)
            key = self.headers.get("Idempotency-Key")

            try:
                stored, deleted, duplicate = ingest_payload(db, payload, key)
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
    if path.suffix == ".zip":
        stored = deleted = 0
        with zipfile.ZipFile(path) as archive:
            for name in archive.namelist():
                if name.endswith(".csv"):
                    continue  # CSV is a lossy projection of the same records.
                added, removed, _ = ingest_payload(db, archive.read(name))
                stored += added
                deleted += removed
        return stored, deleted

    stored, deleted, _ = ingest_payload(db, path.read_bytes())
    return stored, deleted


def stats(args):
    db = connect(args.database)
    total = db.execute("SELECT COUNT(*) FROM samples").fetchone()[0]
    batches = db.execute("SELECT COUNT(*) FROM batches").fetchone()[0]
    print(f"{total:,} records from {batches:,} batches\n")

    rows = db.execute(
        "SELECT type, COUNT(*) c, MIN(start_date), MAX(start_date) "
        "FROM samples GROUP BY type ORDER BY c DESC LIMIT ?",
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
