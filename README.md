# Hozz

**Export Apple Health data to destinations you own.**

Hozz is a free and open-source iPhone and iPad app for exporting the Health data
that Apple permits an app to read. It is being built without subscriptions,
accounts, analytics, advertising, or a developer-operated relay.

> [!IMPORTANT]
> Hozz is an early alpha. The current iPhone build creates a real, manual,
> historical NDJSON export for quantity, category, and basic workout records. It
> streams a standard `.ndjson.gz` file by default to avoid a second
> uncompressed copy on the phone; raw `.ndjson` remains an advanced option. The
> export is resumable: it survives the screen sleeping, the app being
> backgrounded, and the device being killed or rebooted, and it continues from
> its last durable checkpoint instead of starting over. Correlations, workout
> statistics, routes, ECG, audiograms, other series, and clinical records remain
> explicitly unsupported until their lossless encoders and device-validation
> gates pass.

## Product promise

- No subscription, paywall, account, analytics, or data collection.
- No maintainer-operated server, database, relay, or cloud dependency.
- No Health data stored in iCloud by Hozz.
- Credentials remain device-only in Keychain.
- Export destinations belong to and are configured by the user.
- Canonical exports are versioned, streamable, and independently verifiable.
- Permissions, unsupported data, incomplete reads, background delays, and
  delivery failures are reported honestly.

Apple deliberately prevents apps from determining whether read access to a
Health data type was denied or whether no matching data exists. Hozz therefore
does not claim that an export is universally "complete." It reports
**anchor-closed, authorization-scoped, catalog-versioned coverage**: every
object and deletion that the public HealthKit APIs returned within the recorded
query range, plus explicit limitations for everything Hozz cannot prove.

## Architecture

Three independent reviews shaped the initial design: an Apple/HealthKit review,
a data-integrity review, and an adversarial privacy and App Review review.

The binding decisions are:

1. **No date-window backfill.** Each supported HealthKit type is drained from an
   opaque anchor with no date predicate until an empty page proves the stream is
   caught up. Observer queries only mark streams dirty.
2. **No permanent Health mirror by default.** Hozz does not keep a second,
   unbounded copy of the user's live Health history. It persists opaque cursors,
   staged pages, tombstones, coverage state, and a bounded canonical spool.
3. **Anchors advance conservatively.** A page is fully hydrated, encoded, and
   durably staged before its anchor can be committed. Crashes replay work rather
   than skip it.
4. **Destinations are isolated consumers.** Destinations share immutable spool
   segments only when their source cursor and format agree. A failed destination
   cannot corrupt another destination or advance its receipt cursor.
5. **Storage pressure is visible.** Hozz never silently drops queued data. If a
   destination exhausts the spool budget, acquisition pauses or the user
   explicitly chooses a verified replacement snapshot/rebaseline.
6. **The canonical model is a graph.** Samples are nodes; correlations, workout
   routes, series measurements, attachments, and other relationships are edges
   or lifecycle-bound children. CSV and GPX are labeled lossy projections.
7. **Background work is best effort.** Background delivery is requested, never
   promised. The app distinguishes queued, waiting for iOS, delivered, blocked,
   and failed states.
8. **One writer per destination.** iPhone is the default exporter. iPad takeover
   requires an explicit receiver-backed writer epoch; HealthKit anchors are
   never copied between devices.

The app is split along those boundaries:

| Module | Responsibility |
| --- | --- |
| `HozzCore` | Stable identifiers, opaque anchors, change batches, coverage, and protocols |
| `HozzCatalog` | Exhaustive, generated HealthKit type capabilities and canonical units |
| `HozzHealth` | The only production module that imports HealthKit |
| `HozzHealthFake` | Scriptable source for crashes, mutations, deletions, and scale tests |
| `HozzAcquire` | Resumable anchor draining and conservative commit coordination |
| `HozzStore` | Migrations, cursors, coverage, export runs, and sealed spool parts |
| `HozzCanonical` | Deterministic, versioned canonical envelopes |
| `HozzSpool` | Bounded, shared, immutable segments for multiple destinations |
| `HozzDeliver` | Destination generations, batches, retries, receipts, and reconciliation |
| `HozzFormats` | Explicitly lossy CSV and GPX projections |
| `HozzDiagnostics` | Local-only, redacted diagnostics |

### How an export survives being interrupted

A full export takes many minutes, so it is built to be resumed rather than
restarted:

1. Drained changes are appended to an **open part** — one gzip member in the
   private spool — and the anchors they advance are staged in memory only.
2. **Sealing** a part flushes it, closes it, and commits every staged anchor in
   a single store transaction. This is the only operation that may advance a
   durable cursor.
3. An open part is not durable. On relaunch it is deleted and the types it
   touched replay from their last sealed cursor.
4. Finishing a run appends its sealed parts into one artifact. Concatenated
   gzip members are a valid gzip stream, so joining is a byte copy with no
   recompression and no second full copy on disk.

The consequence is the property that matters: an interrupted export can repeat
work, but it can never skip a record and never emit one twice. Pausing, the
screen sleeping, backgrounding, a background-task expiry, a kill, and a reboot
all take the same path. `ExportEngineTests` asserts this directly, including
that an unsealed part never advances a cursor, that a type which failed is not
mistaken for one that finished, and that re-finishing a run cannot concatenate
its artifact onto itself.

A run has exactly one writer. The foreground UI and the background task hold the
same process-wide lease, so they cannot both drive the same run and fight over
the same part file.

Foreground exports hold an idle-timer disable and a background task assertion
for their duration and release both on every exit path; a paused run can also be
picked up by a `BGProcessingTask`, which resumes it in the format the run
already started with.

## Milestone gates

| Milestone | Status | Acceptance gate |
| --- | --- | --- |
| M0 — Contract | Done | Every known HealthKit family has a query, authorization, deletion, background, and limitation classification; privacy and threat models are documented |
| M1 — Foundation | Done | Swift 6 targets build; fake Health source and fault tests prove retries cannot over-advance an anchor |
| M2 — Catalog and authorization | Done | The SDK catalog diff is empty or acknowledged; special authorization flows are separated; zero-result types remain indeterminate |
| M3 — Canonical model | Partial | Golden fixtures are byte-deterministic across locale and timezone; every public field and child family is represented or explicitly unsupported |
| M4 — Acquisition | Partial | Millions of synthetic changes converge under cancellation and injected crashes with bounded memory and no date watermark |
| M5 — Files | Partial | Interrupted exports never appear complete; manifests verify every part and disclose every coverage limitation |
| M6 — Background | Next | Physical-device observer and task testing converges after lock, reboot, expiration, and network loss without overstating latency |
| M7 — Network delivery | Planned | TLS-first, idempotent batches and atomic replacement snapshots reconcile against the open-source reference receiver |
| M8 — Multi-device | Planned | Stale writer epochs are rejected and explicit takeover converges without copying device-local anchors |
| M9 — Release | Planned | Accessibility, localization, privacy disclosures, App Review checks, multi-year endurance, and physical-device reconciliation pass |

M3 and M5 are partial because the shipped exporter covers quantity, category,
and basic workout records with a run manifest, but not the special families or a
full reconciliation receipt. M4 is partial because durable cursors, sealed
parts, and crash replay are in place and tested against a scripted source, but
have not yet been driven at multi-million-record scale on a physical device.

## Next: automatic export

Automatic export is the point of the app, so the next milestone is one narrow
vertical slice rather than finishing every family first:

1. ~~Persist per-type anchors, tombstones, and coverage state across launches.~~
   Done: `HozzStore` persists opaque cursors, coverage, and run bookkeeping, and
   commits them only alongside durable data.
2. Mark types dirty with `HKObserverQuery` and background delivery.
3. Drain changes incrementally into a bounded, protected, backup-excluded spool.
4. Deliver to one user-configured HTTPS destination with a background
   `URLSession` and idempotent batches.
5. Ship a small open-source receiver that stores batches and reports counts.
6. Report queued, waiting for iOS, delivered, blocked, and failed honestly.

Its acceptance gate: add and delete Health data, force-quit and reboot the
phone, and let the receiver converge on the device's state with no gaps and no
duplicates.

## Build

Requirements:

- Xcode 27 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or newer

```bash
xcodegen generate
xcodebuild \
  -project Hozz.xcodeproj \
  -scheme Hozz \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

Run the unit tests with the same generated project:

```bash
xcodebuild \
  -project Hozz.xcodeproj \
  -scheme Hozz \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

## Privacy and security

Hozz sends nothing until the user configures and confirms a destination. Network
destinations will be TLS-first, credentials will be scoped per destination and
function, cross-host redirects will not receive credentials, and local Health
artifacts will be file-protected and excluded from device backups. Diagnostics
remain local and redact sample values, credentials, and destination secrets.

Security-sensitive behavior must be proven with tests, not policy text alone.
This includes backup exclusion for SQLite side files and spool files, Keychain
non-synchronization, redirect isolation, deterministic encoding, and log
redaction.

Compressed exports open directly with Finder's Archive Utility or:

```bash
gunzip hozz-health-export-*.ndjson.gz
```

## Support development

Hozz has no paid features. Donations are entirely optional and support continued
development of Hozz and Brandon's other free, open-source apps.

**[Donate via GitHub Sponsors](https://github.com/sponsors/thatcube)**

Other projects:

- [Plozz](https://github.com/thatcube/Plozz) — a native media player for
  Jellyfin, Plex, Emby, and network shares
- [Mozz](https://github.com/thatcube/Mozz) — music for Plex and Jellyfin
- [Twozz](https://github.com/thatcube/Twozz) — Twitch on Apple TV

## License

[GPL-3.0 with an App Store distribution exception](LICENSE) © 2026 Brandon Moore
