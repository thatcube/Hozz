# Hozz receiver

A complete receiver in one file, with no dependencies beyond Python 3.9+.

It accepts Hozz batches over HTTP on loopback or HTTPS on a network, or watches a folder Hozz writes into, and
keeps a SQLite database you can query with anything — `sqlite3`, pandas, Grafana,
Datasette, or an AI tool pointed at the file.

## Use it

```bash
# Listen for a REST destination
python3 hozz_receiver.py serve --host 127.0.0.1 --port 8765 --token my-secret

# A LAN listener must use a certificate clients already trust.
python3 hozz_receiver.py serve --host 192.168.1.20 --port 8765 \
  --cert /path/to/fullchain.pem --key /path/to/private-key.pem \
  --token my-secret

# Or explicitly opt into an unauthenticated loopback listener
python3 hozz_receiver.py serve --allow-unauthenticated

# Or watch a folder that already syncs to this machine
python3 hozz_receiver.py watch ~/Dropbox/Health

# See what you have
python3 hozz_receiver.py stats
```

Then in Hozz, add a destination pointing at `https://your-computer:8765` with
`my-secret` as the authorization value and a certificate the phone trusts, or
at the folder — and tap **Send a test**. Use `http://127.0.0.1:8765` only from
software on the receiver machine itself.

Plain HTTP is restricted to loopback because a reusable bearer token and health
payload must not cross a LAN in cleartext. For a non-loopback bind, supply a
certificate and private key whose trust chain is already installed on the
phone, or expose the loopback listener through an authenticated TLS tunnel.
Hozz never generates or silently trusts a self-signed certificate.

Each connection has absolute TLS-handshake, header, and body deadlines, and the
listener serves a bounded number of connections concurrently. Complete bodies
are spooled before one serialized SQLite transaction begins, so a slow peer
cannot monopolize the receiver or overlap database commits.

## Why retries are safe

- Every record resolves to a stable Hozz canonical ID and monotonic version, so
  a retry updates the same row and an older replay cannot replace newer state.
  Two records at the same version must be semantically identical; a conflicting
  live record or deletion rejects the whole batch before compatibility
  deferrals are resolved. A legacy ID can map to only one stable ID.
- Every batch carries an `Idempotency-Key`, so a batch that arrives twice —
  which happens whenever a response is lost after the server already committed —
  is recognised and skipped.
- Deletions remain as tombstones and cascade to series/error children, so a
  later replay cannot resurrect removed data.

Together that means an interrupted sync may repeat work, but your database can
never end up with a gap or a duplicate.

## Formats it understands

NDJSON, a JSON array, a full `.zip` export, and the Health Auto Export shaped
payload. CSV entries inside a ZIP are skipped, since they are a lossy projection
of records already present losslessly. Run, coverage, and error lines are kept
verbatim rather than mistaken for measurements. ZIP imports enforce the Hozz v1
manifest and bounded entry, expansion, record, and compression-ratio limits
before any part of the archive commits. The preflight follows prepended-data
offsets to the exact central directory selected by Python's ZIP reader, rejects
an inconsistent final EOCD comment, and validates both ZIP64 record locations
used across supported Python versions before Python allocates the directory.
ZIP entries must use Stored or Deflate; encrypted, BZIP2, LZMA, and unknown
methods are rejected before decompression.
Network requests are capped and spooled, while NDJSON and JSON arrays are
decoded one record at a time. Folder candidates must be regular files and fit
the raw import limit before hashing begins.

Folder receipts persist the content digest with device, inode, size, and
nanosecond modification and change times. The no-hash generation shortcut is
used only when the runtime identifies a whitelisted filesystem with reliable
change-time semantics (currently APFS). On Darwin, a fixed `/sbin/mount` command
is invoked without a shell; mount types are matched by device identity and
cached per device. HFS+, Windows, and unknown filesystems rehash and compare the
persisted digest before skipping; that work is bounded by the raw file limit. A
file that needs ingestion is copied while its initial hash is computed, with
memory capped before the copy spills beside the receiver database. Parsing uses
that immutable, length-bounded copy, then the original is verified again before
its receipt commits. A growing, rewritten, or ABA-swapped file therefore cannot
extend work indefinitely or mix bytes under the wrong identity. Changing only
filesystem metadata does not duplicate archive run or coverage records.

Health Auto Export metric points must include their source record ID. Without
it, a later date-less deletion cannot identify the record it supersedes, so the
receiver rejects the whole batch instead of acknowledging an unrecoverable
partial history. Stable records received directly preserve the same alias
signature before deletion, so a delayed legacy replay cannot resurrect them.

Databases written by an older receiver mark prior batch receipts during
migration. A replay can repair a dated deletion against the old name-and-date
identity. A date-less deletion cannot be linked to an older synthesized row, so
that replay fails explicitly and requires a fresh full export rather than
creating an unrelated tombstone. Migration also preserves a conservative
type-scoped barrier for unresolved stable tombstones from versions that did not
store compatibility metadata, preventing delayed legacy records from reviving
them. Filename-only watcher receipts are compared using mutations to durable
receiver tables only, so temporary validation bookkeeping cannot make unchanged
content look new. Receipts with an unknown deletion count replay against their
original receipt and run scope before the content-digest receipt is recorded,
avoiding duplicate run and coverage history. Data backfills are versioned and
run once; normal batches reconcile only encoding errors related to IDs changed
by that batch.

## Ask it things

```sql
-- Daily step totals
SELECT substr(start_date, 1, 10) AS day, SUM(value) AS steps
FROM samples
WHERE type = 'HKQuantityTypeIdentifierStepCount' AND tombstone = 0
GROUP BY day ORDER BY day DESC LIMIT 30;

-- Resting heart rate trend
SELECT substr(start_date, 1, 7) AS month, ROUND(AVG(value), 1) AS bpm
FROM samples
WHERE type = 'HKQuantityTypeIdentifierRestingHeartRate' AND tombstone = 0
GROUP BY month ORDER BY month;
```
