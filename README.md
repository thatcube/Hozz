# Hozz

**Export Apple Health data to destinations you own.**

Hozz is a free and open-source iPhone and iPad app for exporting the Health data
that Apple permits an app to read. It is being built without subscriptions,
accounts, analytics, advertising, or a developer-operated relay.

> [!IMPORTANT]
> Hozz is an early alpha. The current iPhone build creates a real, manual,
> historical NDJSON export for quantity, category, and basic workout records. It
> writes a standard `.zip` holding NDJSON, CSV, or JSON, so it opens with a
> double-click on any machine. The
> export is resumable: it survives the screen sleeping, the app being
> backgrounded, and the device being killed or rebooted, and it continues from
> its last durable checkpoint instead of starting over. Correlations, workout
> statistics, routes, ECG, audiograms, other series, and clinical records remain
> explicitly unsupported until their lossless encoders and device-validation
> gates pass.

## Automatic export

Add a destination once and new Health data flows to it on its own.

| Destination | What it is |
| --- | --- |
| Folder | Anywhere the Files app reaches — iCloud Drive, Dropbox, OneDrive, Google Drive, an SMB share |
| Home Assistant | A webhook or the REST API, with a long-lived token |
| Web address | Any endpoint you run, with idempotent batches |
| MQTT | A broker on your network, one retained topic per metric |

Each is offered as a named preset with its setup steps shown inline. Home
Assistant and MQTT default to a payload shape those ecosystems already parse, so
an existing dashboard or automation keeps working when pointed at Hozz.

`enableBackgroundDelivery` asks iOS to activate Hozz when Health records
something, which is what lets sync continue for months without the app being
opened. Four limits are real and are stated in the app rather than hidden: the
device must be unlocked for any app to read Health, iOS decides when background
work runs, most types are capped at hourly, and force-quitting stops it until
the app is opened again.

What Hozz guarantees regardless: **nothing is lost**. Each destination has its
own cursor and only advances it once that destination has accepted the data, so
a missed window is simply sent next time. Tools that export "the last hour"
cannot make that promise — a skipped window is gone and an overlapping one
duplicates.

A [receiver](receiver/) ships alongside: one dependency-free file that turns
batches into a SQLite database, over HTTP or by watching a synced folder. The
website repository also carries a browser viewer that turns an export into
charts without installing anything; it is static files with no backend, so
there is nowhere for the data to be sent even in principle.

## Product promise

- No subscription, paywall, account, analytics, or data collection.
- No maintainer-operated server, database, relay, or cloud dependency.
- Nothing leaves the device until you choose a destination and confirm it.
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
| `HozzDeliver` | Destinations, credentials, batches, retries, and receipts |
| `HozzUI` | Shared iconography and view helpers |
| `HozzFormats` | Explicitly lossy CSV and GPX projections (CSV shipped in `HozzHealth`) |
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
4. Finishing a run assembles its sealed parts into one Zip64 archive. Each part
   is a raw deflate stream ended with a sync flush rather than a final block, so
   the parts concatenate into a single valid deflate stream and the archive is
   written with no recompression.

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
| M6 — Background | Partial | Physical-device observer and task testing converges after lock, reboot, expiration, and network loss without overstating latency |
| M7 — Network delivery | Partial | TLS-first, idempotent batches and atomic replacement snapshots reconcile against the open-source reference receiver |
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
2. ~~Mark types dirty with `HKObserverQuery` and background delivery.~~
3. ~~Drain changes incrementally and deliver them in bounded batches.~~
4. ~~Deliver to user-configured folder and HTTPS destinations with idempotent
   batches.~~
5. ~~Ship a small open-source receiver that stores batches and reports counts.~~
6. ~~Report queued, waiting for iOS, delivered, blocked, and failed honestly.~~

Remaining for M6 and M7: multi-day endurance on a physical device, and
reconciliation counts surfaced in the app rather than only in the receiver.

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

Compressed exports are Zip64 archives, so they open
with a double-click on a stock Mac and with `unzip` everywhere else. ZIP rather
than gzip for two reasons: a resumable export produces several compressed
segments, and gzip's uncompressed-size field is 32 bits, which wraps on the
multi-gigabyte exports Health routinely produces. Both make a `.gz` unreadable
to Archive Utility even though the bytes are valid.

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

## Export formats

| Format | Shape | Notes |
| --- | --- | --- |
| NDJSON | One record per line | Default. Lossless, streams at any size, and assembled by copying compressed parts, so it costs nothing extra. |
| CSV | One spreadsheet per data type | Opens in Excel or Sheets. **Explicitly lossy**: metadata, device details, and nested workout events do not fit a grid. |
| JSON | A single array | Convenient for small exports and for feeding to other tools. A multi-million-record array is awkward for most parsers; prefer NDJSON at that size. |
| Raw | Uncompressed NDJSON | For piping straight into something else. |

The spool is always NDJSON, whichever format is chosen. That is deliberate: it
is the representation the durability machinery is built and tested around, and
a presentation choice should not reach into the part that has to survive a
reboot. CSV and JSON are produced by reading that stream once at the end, so
NDJSON keeps its zero-cost path and the other formats cost one extra pass.

## One manual step for the widget

The widget shows "Open Hozz for status" until the **App Groups** capability is
enabled for `com.thatcube.Hozz` in the Apple developer portal. An iOS extension
has its own data container, so without a shared group the widget cannot read the
app's database at all.

Once the capability exists, add to both the app and widget targets in
`project.yml`:

```yaml
        com.apple.security.application-groups:
          - group.com.thatcube.Hozz
```

The code already prefers that container and falls back to the app's own when it
is unavailable, so nothing else needs to change. It is left out of the committed
project because the current development profile lacks the capability, and
declaring an entitlement the profile does not carry fails every device build.
