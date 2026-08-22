# Hozz receiver

A complete receiver in one file, with no dependencies beyond Python 3.9+.

It accepts Hozz batches over HTTP, or watches a folder Hozz writes into, and
keeps a SQLite database you can query with anything — `sqlite3`, pandas, Grafana,
Datasette, or an AI tool pointed at the file.

## Use it

```bash
# Listen for a REST destination
python3 hozz_receiver.py serve --port 8765 --token my-secret

# Or watch a folder that already syncs to this machine
python3 hozz_receiver.py watch ~/Dropbox/Health

# See what you have
python3 hozz_receiver.py stats
```

Then in Hozz, add a destination pointing at `http://your-computer:8765` with
`my-secret` as the authorization value, or at the folder — and tap **Send a
test**.

## Why retries are safe

- Every record carries HealthKit's own identifier, so storing one twice is an
  `INSERT OR REPLACE` of identical data.
- Every batch carries an `Idempotency-Key`, so a batch that arrives twice —
  which happens whenever a response is lost after the server already committed —
  is recognised and skipped.
- Deletions arrive as explicit records, so removing something in Health removes
  it here too.

Together that means an interrupted sync may repeat work, but your database can
never end up with a gap or a duplicate.

## Formats it understands

NDJSON, a JSON array, a full `.zip` export, and the Health Auto Export shaped
payload. CSV entries inside a ZIP are skipped, since they are a lossy projection
of records already present losslessly.

## Ask it things

```sql
-- Daily step totals
SELECT substr(start_date, 1, 10) AS day, SUM(value) AS steps
FROM samples
WHERE type = 'HKQuantityTypeIdentifierStepCount'
GROUP BY day ORDER BY day DESC LIMIT 30;

-- Resting heart rate trend
SELECT substr(start_date, 1, 7) AS month, ROUND(AVG(value), 1) AS bpm
FROM samples
WHERE type = 'HKQuantityTypeIdentifierRestingHeartRate'
GROUP BY month ORDER BY month;
```
