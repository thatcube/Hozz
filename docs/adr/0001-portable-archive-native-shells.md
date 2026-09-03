---
status: accepted
---

# Keep a canonical Hozz archive behind native platform adapters

Hozz will keep one repository and one versioned, lossless archive contract.
HealthKit and Health Connect are platform adapters around that contract, not
competing sources of truth, and SwiftUI and Compose remain native shells.

Health Connect cannot be the archive. It has no generic record, cannot represent
ECGs, audiograms, State of Mind, medication-dose events, many categories, or all
Apple metadata, and always attributes an inserted record's `DataOrigin` to the
Android package. Hozz therefore preserves every source record and its lineage,
marks records without a faithful target as archive only, and records
machine-readable warnings for every lossy projection. A record whose lineage
already contains Hozz's Health Connect package is never projected back into that
store.

The Android v1 shell imports the existing NDJSON/ZIP archive through a
schema-driven Kotlin core and writes only an explicitly approved mapped subset.
The schema and mapping tables under `schema/hozz/v1/` generate both Swift and
Kotlin constants. This deliberately duplicates a small parser and storage
adapter, not Hozz's full acquisition, durability, or delivery engines.

## Considered options

- **Use Health Connect as the canonical Android store.** Rejected because it
  would discard unrepresentable records and original provenance, and would make
  a platform projection appear more authoritative than the lossless archive.
- **Reimplement the whole core in Kotlin.** Rejected because two independent
  implementations of cursor, tombstone, retry, and mapping semantics would
  drift at exactly the boundaries where Hozz can lose records.
- **Cross-compile the current Swift core and add JNI now.** Deferred. Mozz proves
  Swift can compile, link, and run on Android behind a small C ABI, but an APK
  must package the Swift runtime and `libc++_shared.so`, and a handwritten JNI
  shim still has to be proved. Hozz's archive encoding currently lives in
  `HozzHealth` beside HealthKit, while storage is coupled to the Apple SQLite
  wrapper. A local arm64 probe also found the installed Android Swift SDK at
  6.3.3 incompatible with the active Swift 6.4 compiler. Shipping a JNI bridge
  before extracting a genuinely portable archive core would add packaging risk
  without removing meaningful duplication.

## Consequences

The next shared-core step is a small portable `HozzArchiveCore` with a
length-delimited JSON-over-C façade for manifest validation, canonical record
normalization, merge decisions, and projection planning. Platform file pickers,
databases, permissions, HealthKit, Health Connect, and UI stay outside that
boundary. Until then, golden fixtures and generated contracts are the
cross-language authority.

Health Connect projection remains opt-in and pre-release. Google's write API
supports third-party-derived records and deterministic
`clientRecordId`/`clientRecordVersion` upserts, but current Google Play health
policy also warns against synchronizing health data between incompatible
platforms. Hozz must obtain policy clarification before distributing this
projection through Google Play.

Sources:
[Health Connect write data](https://developer.android.com/health-and-fitness/health-connect/write-data),
[availability](https://developer.android.com/health-and-fitness/health-connect/availability),
[permissions](https://developer.android.com/health-and-fitness/health-connect/get-started),
and [Google Play health guidance](https://support.google.com/googleplay/android-developer/answer/12991134).
