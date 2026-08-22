# Hozz

**Export Apple Health data to destinations you own.**

Hozz is a free and open-source iPhone and iPad app for exporting the Health data
that Apple permits an app to read. It is being built without subscriptions,
accounts, analytics, advertising, or a developer-operated relay.

> [!IMPORTANT]
> Hozz is an early alpha. The current iPhone build creates a real, manual,
> historical NDJSON export for quantity, category, correlation, and basic
> workout records. Workout statistics, routes, ECG, audiograms, other series,
> and clinical records remain explicitly unsupported until their lossless
> encoders and device-validation gates pass.

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
| `HozzCanonical` | Deterministic, versioned canonical envelopes |
| `HozzStore` / `HozzSpool` | Migrations, cursors, staged pages, tombstones, and bounded files |
| `HozzDeliver` | Destination generations, batches, retries, receipts, and reconciliation |
| `HozzFormats` | Explicitly lossy CSV and GPX projections |
| `HozzDiagnostics` | Local-only, redacted diagnostics |

## Milestone gates

| Milestone | Acceptance gate |
| --- | --- |
| M0 — Contract | Every known HealthKit family has a query, authorization, deletion, background, and limitation classification; privacy and threat models are documented |
| M1 — Foundation | Swift 6 targets build; fake Health source and fault tests prove retries cannot over-advance an anchor |
| M2 — Catalog and authorization | The SDK catalog diff is empty or acknowledged; special authorization flows are separated; zero-result types remain indeterminate |
| M3 — Canonical model | Golden fixtures are byte-deterministic across locale and timezone; every public field and child family is represented or explicitly unsupported |
| M4 — Acquisition | Millions of synthetic changes converge under cancellation and injected crashes with bounded memory and no date watermark |
| M5 — Files | Interrupted exports never appear complete; manifests verify every part and disclose every coverage limitation |
| M6 — Background | Physical-device observer and task testing converges after lock, reboot, expiration, and network loss without overstating latency |
| M7 — Network delivery | TLS-first, idempotent batches and atomic replacement snapshots reconcile against the open-source reference receiver |
| M8 — Multi-device | Stale writer epochs are rejected and explicit takeover converges without copying device-local anchors |
| M9 — Release | Accessibility, localization, privacy disclosures, App Review checks, multi-year endurance, and physical-device reconciliation pass |

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
