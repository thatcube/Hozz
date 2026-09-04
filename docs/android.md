# Android foundation

Android support is not shipped. The project under `Android/` is the first
working foundation for a native Hozz shell and the cross-platform archive
contract it consumes.

## Data flow

```text
platform health store
        ↓ platform adapter
versioned Hozz archive
        ↓ user-controlled transport
local canonical store
        ├─ timeline and coverage/mapping view
        ├─ lossless Hozz archive export
        └─ explicit, possibly lossy projection
                    ↓
              Health Connect
```

Android cannot read Apple Health. For Apple-originated data, extraction remains
on an Apple device and Android receives a Hozz archive through the Storage
Access Framework. The archive, not Health Connect, remains the complete copy.

## Archive compatibility

The importer accepts:

- raw Hozz NDJSON;
- legacy Hozz ZIP exports containing one NDJSON member; and
- versioned Hozz ZIP exports with `hozz-manifest.json` and the declared NDJSON
  member.

An import is staged and committed only after the whole archive validates. A
malformed late record, missing member, duplicate NDJSON stream, or bad ZIP does
not leave a partial import behind. Stable canonical IDs and monotonic versions
make a repeated import idempotent. Tombstones remain in the local store and in
subsequent exports.

A sidecar-declared v1 archive is strict: canonical health records must provide
identity, type, version, source provenance, and lineage. Only raw NDJSON or a
ZIP without a sidecar receives legacy normalization. Run manifest, resume,
coverage, error, and completion lines are retained verbatim. Imports also bound
entry count, total inflated bytes, record count, record size, and per-entry and
global compression ratios; ignored ZIP entries are drained through the same
limits before the staged import can commit.

## Health Connect projection

Projection requires Android 14/API 34 or newer and is always initiated by the
person using Hozz. On Android 9 through 13 the shell reports projection as
unavailable, even when the standalone Health Connect provider is installed.
Before requesting permission on a supported device, the UI shows exact, lossy,
and archive-only counts. It requests only the write permissions represented by
the current plan and does not request read, history, or background-read access.
The pre-release manifest still declares write permissions for steps, distance,
active energy, and sleep solely to remove a ledger-backed record written before
those mappings were disabled; new records of those types are not projected
while their mappings remain unsafe. Android has not shipped, so there is no
supported migration that guesses at untracked prototype writes: deleting an
unknown Health Connect record would violate the same idempotency rule this
foundation is establishing.

Sidecar-declared v1 archives are intentionally strict. Archives produced before
the canonical identity/provenance contract must be imported through the
sidecar-less legacy path; Hozz does not silently reinterpret a malformed v1
sidecar as legacy.

Android stages a complete export in app-private storage before touching the SAF
document. The final write uses explicit truncate mode and verifies byte count
and SHA-256. Generic document providers cannot promise atomic replacement of an
existing document from an `ACTION_CREATE_DOCUMENT` URI, so Hozz refuses to
overwrite non-empty documents unless a destination implementation can guarantee
safe replacement.

Canonical import staging is connection-local and disappears only with its
owning database connection. Export digest, manifest, count, and payload are read
inside one SQLite snapshot. Individual NDJSON records are limited to 512 KiB so
the full canonical row remains below API 28 CursorWindow limits. Timeline and
export pages also stop at a 512 KiB cumulative raw-record budget; callers keep
paging until an empty result rather than treating a short page as end-of-data.
The Compose timeline retains that cursor and appends the next bounded page near
the end of a scroll, with an explicit load-more control as an accessible fallback.
SQLite stores a fixed-width, full-precision timeline key and indexes it with the
canonical ID tie-breaker, so fractional timestamps page in true `Instant` order
without sorting the complete archive.

| Hozz canonical type | Apple source | Health Connect target | Fidelity |
| --- | --- | --- | --- |
| `activity.steps` | Step Count | — | Archive-only until overlapping Apple sources can be resolved without inflating totals |
| `vitals.heart-rate` | Heart Rate | `HeartRateRecord` | Exact for one reading; aggregate-only samples stay in the archive |
| `body.weight` | Body Mass | `WeightRecord` | Exact in kilograms |
| `body.height` | Height | `HeightRecord` | Exact in metres |
| `sleep.stage` | Sleep Analysis | — | Archive-only until complete, non-overlapping sessions can be assembled |
| `activity.distance` | Walking + Running Distance | — | Archive-only until overlapping Apple sources can be resolved |
| `energy.active` | Active Energy Burned | — | Archive-only until overlapping Apple sources can be resolved |
| `activity.exercise-session` | Workout | `ExerciseSessionRecord` | Basic mapped activity and interval are exact; unknown activities and unrepresented rich details are lossy |

ECGs and waveform pages, audiograms, State of Mind, medication doses,
characteristics, clinical records, quantity-series pages, and workout routes
remain visible and exportable as archive-only records. Hozz never relabels them
as a different Health Connect type.

Clinical records imported from an existing file are retained, but Apple-side
clinical extraction is not complete coverage yet: HealthKit requires a full
scan and Hozz does not yet reconcile disappearing records into canonical
tombstones.

Every inserted record uses its deterministic canonical ID as
`Metadata.clientRecordId` and its canonical version as
`Metadata.clientRecordVersion`. Retrying the same version is idempotent and a
higher version replaces it. Records whose lineage already includes Health
Connect package `com.thatcube.hozz` are excluded from projection.

Hozz records a durable pending operation before calling Health Connect. A
successful upsert commits the returned record ID and clears that journal entry
in one transaction; a crash after the platform write therefore retries safely
through deterministic `clientRecordId`. Tombstones delete by that client
identity even when the returned platform ID was never committed locally. This
recovery relies on the Android 14+ system module accepting an already-absent
identifier as a completed delete. The preview distinguishes inserts, updates,
and deletes, and deletion still requires separate confirmation.

## Platform requirements

The app's minimum is Android 9/API 28, where archive import, viewing, and export
remain available. Health Connect projection requires the system module on
Android 14/API 34 or newer. The separate
`com.google.android.apps.healthdata` provider used on Android 9 through 13 is
explicitly gated off: `androidx.health.connect:connect-client:1.1.0` documents
deleting an absent identifier or repeating a deletion as an IPC failure. If the
provider deletes a record and the process dies before the local ledger commit,
Hozz cannot distinguish that completed deletion from a provider failure without
broad historical read access. Hozz keeps the archive available instead of
claiming a projection it cannot recover truthfully.

Google's write documentation permits correctly attributed imported data, while
current Google Play health guidance also restricts synchronizing data between
otherwise incompatible devices or platforms. That policy review is separate
from the API 34 correctness gate. On supported devices the Health Connect action
remains an unreleased, opt-in capability until Google provides policy
clarification for user-initiated Apple Health migration.

First-party references:

- [Health Connect availability](https://developer.android.com/health-and-fitness/health-connect/availability)
- [Get started with Health Connect](https://developer.android.com/health-and-fitness/health-connect/get-started)
- [Write data](https://developer.android.com/health-and-fitness/health-connect/write-data)
- [Sleep sessions](https://developer.android.com/health-and-fitness/health-connect/features/sleep-sessions)
- [Google Play health guidance](https://support.google.com/googleplay/android-developer/answer/12991134)
