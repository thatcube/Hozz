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
before any part of the archive commits. ZIP entries must use Stored or Deflate;
encrypted, BZIP2, LZMA, and unknown methods are rejected before decompression.
Network requests are capped and spooled, while NDJSON and JSON arrays are
decoded one record at a time.

Folder imports open each candidate once and use its content digest as the
idempotent batch identity. Device, inode, size, and nanosecond modification time
form a freshness snapshot recorded in the same transaction as its records. If
either the descriptor or pathname changes before commit, the import rolls back
and the next scan retries the completed file. Changing only filesystem metadata
does not duplicate archive run or coverage records.

Health Auto Export metric points must include their source record ID. Without
it, a later date-less deletion cannot identify the record it supersedes, so the
receiver rejects the whole batch instead of acknowledging an unrecoverable
partial history.

Databases written by an older receiver mark prior batch receipts during
migration. A replay can repair a dated deletion against the old name-and-date
identity. A date-less deletion cannot be linked to an older synthesized row, so
that replay fails explicitly and requires a fresh full export rather than
creating an unrelated tombstone.

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
