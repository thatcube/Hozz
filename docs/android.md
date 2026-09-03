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

## Health Connect projection

Projection is always initiated by the person using Hozz. Before requesting
permission, the UI shows exact, lossy, and archive-only counts. It requests only
the write permissions represented by the current plan and does not request
read, history, or background-read access.

| Hozz canonical type | Apple source | Health Connect target | Fidelity |
| --- | --- | --- | --- |
| `activity.steps` | Step Count | `StepsRecord` | Exact for integral counts in range |
| `vitals.heart-rate` | Heart Rate | `HeartRateRecord` | Exact for one reading; aggregate-only samples stay in the archive |
| `body.weight` | Body Mass | `WeightRecord` | Exact in kilograms |
| `body.height` | Height | `HeightRecord` | Exact in metres |
| `sleep.stage` | Sleep Analysis | `SleepSessionRecord` | Unspecified asleep, awake, deep, and REM are exact; Core becomes Light with a warning; In Bed stays archive only |
| `activity.distance` | Walking + Running Distance | `DistanceRecord` | Exact in metres |
| `energy.active` | Active Energy Burned | `ActiveCaloriesBurnedRecord` | Exact in kilocalories |
| `activity.exercise-session` | Workout | `ExerciseSessionRecord` | Basic mapped activity and interval are exact; unknown activities and unrepresented rich details are lossy |

ECGs and waveform pages, audiograms, State of Mind, medication doses,
characteristics, clinical records, quantity-series pages, and workout routes
remain visible and exportable as archive-only records. Hozz never relabels them
as a different Health Connect type.

Every inserted record uses its deterministic canonical ID as
`Metadata.clientRecordId` and its canonical version as
`Metadata.clientRecordVersion`. Retrying the same version is idempotent and a
higher version replaces it. Records whose lineage already includes Health
Connect package `com.thatcube.hozz` are excluded from projection.

## Platform requirements

The app's minimum is Android 9/API 28. Health Connect is a system module on
Android 14 and newer and uses the separate
`com.google.android.apps.healthdata` provider on Android 9 through 13. The
project uses the stable `androidx.health.connect:connect-client:1.1.0` library.

Google's write documentation permits correctly attributed imported data, while
current Google Play health guidance also restricts synchronizing data between
otherwise incompatible devices or platforms. The Health Connect action remains
an unreleased, opt-in capability until Google provides policy clarification for
user-initiated Apple Health migration.

First-party references:

- [Health Connect availability](https://developer.android.com/health-and-fitness/health-connect/availability)
- [Get started with Health Connect](https://developer.android.com/health-and-fitness/health-connect/get-started)
- [Write data](https://developer.android.com/health-and-fitness/health-connect/write-data)
- [Sleep sessions](https://developer.android.com/health-and-fitness/health-connect/features/sleep-sessions)
- [Google Play health guidance](https://support.google.com/googleplay/android-developer/answer/12991134)
