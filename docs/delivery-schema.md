# Hozz delivery schema

This is what Hozz sends to an automatic destination, field by field. It exists
so you can build against Hozz without reading the source.

Everything here describes **automatic delivery** — the batches sent to a folder,
an endpoint, or a broker. Manual exports use the same record shape packaged
differently; the [README](../README.md#formats) covers those.

- [The record](#the-record) — the canonical shape everything else is derived
  from
- [NDJSON](#ndjson) · [JSON](#json) · [CSV](#csv) ·
  [Metrics JSON](#metrics-json) · [InfluxDB line protocol](#influxdb-line-protocol)
- [Health Auto Export compatibility](#health-auto-export-compatibility)
- [Delivery mechanics](#delivery-mechanics) — date range, headers, idempotency,
  retries

## Conventions

**Timestamps** are ISO 8601 in UTC with fractional seconds and a `Z` suffix:
`2026-08-22T21:10:46.500Z`. The one exception is the optional Health Auto Export
compatibility mode, which uses local time in that app's format.

**Units** are HealthKit's own unit strings, untranslated. A heart rate arrives
as `count/min`, not `bpm`; energy as `kcal`; distance in whatever unit Hozz's
type catalogue declares canonical for that type. This is deliberate — a unit
Hozz invented a nicer name for is a unit you cannot map back.

**Identifiers** are lowercase UUID strings. A sample keeps the UUID HealthKit
gave it, so the same record delivered twice is recognisably the same record.

**Nothing is null.** A field Hozz has no value for is absent rather than present
and empty. An absent `device` means HealthKit reported no device, not that Hozz
dropped it.

## The record

NDJSON and JSON deliver this shape unchanged. CSV, Metrics JSON, and line
protocol are projections of it. Every record has these fields:

| Field | Type | Notes |
| --- | --- | --- |
| `schemaVersion` | Integer | Currently `1`. |
| `catalogVersion` | Integer | Version of Hozz's Health type catalogue. |
| `id` | String | Lowercase UUID. Stable across redeliveries. |
| `type` | String | HealthKit type identifier, e.g. `HKQuantityTypeIdentifierHeartRate`. |
| `kind` | String | See below. |
| `startDate` | String | ISO 8601 UTC. |
| `endDate` | String | ISO 8601 UTC. Equals `startDate` for instantaneous samples. |
| `source` | Object | Where the sample came from. |
| `device` | Object | Optional. The hardware, when HealthKit named one. |
| `metadata` | Object | Optional. HealthKit metadata, type-tagged. |

### `kind`

| `kind` | Extra fields | What it is |
| --- | --- | --- |
| `quantity` | `quantity` | A measurement — steps, heart rate, weight. |
| `category` | `value` (Integer) | A classified event — a sleep stage, a stand hour. |
| `workout` | `activityType`, `duration`, `events` | One workout. |
| `correlation` | `members` | A grouping, such as a blood pressure reading. |
| `workoutRoute` | `workout` | A GPS route's own record. |
| `workoutRouteLocations` | `route`, `sequence`, `offset`, `count`, `locations` | One page of route points. |
| `workoutRouteEnd` | `route`, `locations` | Marks a route as completely written. |
| `deletion` | — | A tombstone. Carries only `kind`, `id`, `type`, `schemaVersion`. |
| `sampleEncodingError` | `message` | A sample Hozz could not encode, written in its place so the batch never silently omits it. |
| `sample` | — | An `HKSample` subclass this build has no specific handling for. |

### `quantity`

```json
{ "unit": "count/min", "value": 62.5, "description": "62.5 count/min" }
```

`value` is a `Double` in `unit`. `description` is HealthKit's own rendering,
kept because it is the only thing that survives a unit Hozz cannot express.

### `source`

```json
{
  "name": "Brandon's Apple Watch",
  "bundleIdentifier": "com.apple.health.ABC123",
  "version": "11.2",
  "productType": "Watch7,1",
  "operatingSystem": { "major": 26, "minor": 5, "patch": 0 }
}
```

`name` and `bundleIdentifier` are always present. The rest appear when HealthKit
provides them.

### `device`

```json
{
  "name": "Apple Watch",
  "manufacturer": "Apple Inc.",
  "model": "Watch",
  "hardwareVersion": "Watch7,1",
  "softwareVersion": "26.5",
  "localIdentifier": "ABC",
  "udiDeviceIdentifier": "…"
}
```

Every key is optional, and the object is omitted entirely when HealthKit reports
no device.

### `metadata`

Each value is tagged with its own type, because HealthKit metadata is
`[String: Any]` and an untagged value cannot be read back reliably.

```json
{
  "HKWasUserEntered": { "type": "bool", "value": true },
  "HKTimeZone": { "type": "string", "value": "Europe/London" },
  "HKMetadataKeyHeartRateMotionContext": { "type": "number", "value": 1 }
}
```

`type` is one of `string`, `number`, `bool`, `date`, `data` (base64),
`quantity` (which carries a `description` string rather than a `value`), `array`
(whose `value` is an array of tagged values), or `unsupported` (with a `class`
naming what it was).

### Workouts

```json
{
  "kind": "workout",
  "activityType": 37,
  "duration": 1800.0,
  "events": [
    {
      "type": 1,
      "startDate": "2026-08-22T07:10:00.000Z",
      "endDate": "2026-08-22T07:10:00.000Z",
      "metadata": {}
    }
  ]
}
```

`activityType` is the raw `HKWorkoutActivityType` value — 37 is Running.
`duration` is seconds.

### Workout routes

A route arrives as three record kinds, because a long ride holds hundreds of
thousands of points and cannot be one record.

```json
{
  "kind": "workoutRoute",
  "id": "…",
  "type": "HKWorkoutRouteTypeIdentifier",
  "workout": {
    "state": "resolved",
    "id": "…",
    "activityType": 37,
    "startDate": "2026-08-22T07:00:00.000Z",
    "endDate": "2026-08-22T07:30:00.000Z"
  }
}
```

`workout.state` is `resolved` or `unresolved`. An unresolved route carries a
`reason` instead of a workout, because a route attached to a workout Hozz only
guessed at is worse than one that says it does not know.

```json
{
  "kind": "workoutRouteLocations",
  "route": "…",
  "sequence": 0,
  "offset": 0,
  "count": 500,
  "startDate": "…",
  "endDate": "…",
  "locations": [
    {
      "timestamp": "2026-08-22T07:00:00.000Z",
      "latitude": 51.5007,
      "longitude": -0.1246,
      "altitude": 11.2,
      "verticalAccuracy": 3.0,
      "horizontalAccuracy": 4.1,
      "course": 182.0,
      "courseAccuracy": 5.0,
      "speed": 3.1,
      "speedAccuracy": 0.4
    }
  ]
}
```

Pages are 500 points, split at fixed offsets so a replayed page is byte
identical to the one it replaces. Core Location reports "unknown" as a negative
accuracy, course, or speed, and those keys are omitted rather than written as
negative numbers that look like measurements. `workoutRouteEnd` carries the
final `locations` count, so a complete route is distinguishable from a truncated
one.

## NDJSON

Default. One record per line, `\n` terminated, `application/x-ndjson`. Lossless.

```
{"catalogVersion":6,"endDate":"2026-08-22T21:10:46.500Z","id":"2f1a…","kind":"quantity","metadata":{},"quantity":{"description":"62.5 count/min","unit":"count/min","value":62.5},"schemaVersion":1,"source":{"bundleIdentifier":"com.apple.health.ABC","name":"Apple Watch","operatingSystem":{"major":26,"minor":5,"patch":0}},"startDate":"2026-08-22T21:10:46.500Z","type":"HKQuantityTypeIdentifierHeartRate"}
{"id":"9c40…","kind":"deletion","schemaVersion":1,"type":"HKQuantityTypeIdentifierStepCount"}
```

Keys within a record are sorted, so the same records always produce the same
bytes. That is what lets the batch identifier be derived from the payload.

## JSON

The same records as one array, `application/json`. Lossless. Convenient for
tools that want a single JSON value; NDJSON is better for anything streaming.

```json
[
{"catalogVersion":6,"id":"2f1a…","kind":"quantity","…":"…"},
{"id":"9c40…","kind":"deletion","schemaVersion":1,"type":"HKQuantityTypeIdentifierStepCount"}
]
```

## CSV

One flat table, `text/csv`, with a header row. **Lossy**: metadata, device,
workout detail, and route points do not fit a grid and are not included.

```csv
id,type,kind,startDate,endDate,value,unit,sourceName,deleted
2f1a…,HKQuantityTypeIdentifierHeartRate,quantity,2026-08-22T21:10:46.500Z,2026-08-22T21:10:46.500Z,62.5,count/min,Apple Watch,false
9c40…,HKQuantityTypeIdentifierStepCount,deletion,,,,,,true
```

| Column | Notes |
| --- | --- |
| `value` | Whole numbers are written without a decimal point. |
| `deleted` | `true` only for `kind` `deletion`. |

A batch spans several Health types, so this is one table rather than a file per
type. Splitting it would defeat appending on the receiving end.

## Metrics JSON

Grouped by metric rather than by sample, `application/json`. What Home
Assistant, MQTT subscribers, and most dashboards want. **Lossy**: metadata,
device, and workout detail are dropped.

```json
{
  "data": {
    "metrics": [
      {
        "name": "heart_rate",
        "units": "count/min",
        "data": [
          {
            "date": "2026-08-22T21:10:46.500Z",
            "qty": 62.5,
            "units": "count/min",
            "source": "Apple Watch"
          }
        ]
      },
      {
        "name": "sleep_analysis",
        "units": "count",
        "data": [
          {
            "date": "2026-08-22T22:00:00.000Z",
            "endDate": "2026-08-22T22:30:00.000Z",
            "qty": 3,
            "units": "count",
            "source": "Apple Watch"
          }
        ]
      }
    ],
    "workouts": [
      {
        "id": "7b21…",
        "name": "Workout",
        "start": "2026-08-22T07:00:00.000Z",
        "end": "2026-08-22T07:30:00.000Z"
      }
    ],
    "deletions": [
      {
        "id": "9c40…",
        "name": "step_count",
        "type": "HKQuantityTypeIdentifierStepCount",
        "date": ""
      }
    ]
  }
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `metrics[].name` | String | Short snake_case name — see [metric names](#metric-names). |
| `metrics[].units` | String | HealthKit's unit string, or `count` when the type has none. |
| `metrics[].data[].date` | String | ISO 8601 UTC. The sample's `startDate`. |
| `metrics[].data[].qty` | Number | Absent when the record has no numeric value. |
| `metrics[].data[].units` | String | Repeated per point. |
| `metrics[].data[].source` | String | Absent when HealthKit named no source. |
| `metrics[].data[].endDate` | String | **Present only when the sample covers an interval.** |
| `workouts[]` | Array | Absent when the batch has none. |
| `deletions[]` | Array | Absent when the batch has none. |

Two things to know.

**`endDate` is a Hozz addition.** Hozz sends the individual samples HealthKit
returned rather than hourly or daily rollups, because that is the only shape
that can honestly claim no gaps and no duplicates. Sleep and exercise samples
are intervals, and flattening one to an instant loses the span it covered.

**`deletions` is a Hozz addition too**, and a tombstone carries no date — Health
does not tell an app when a record was removed, only that it was. A receiver
that ignores the key behaves exactly as though it were not there.

### Metric names

Names are lowercase snake_case. A curated name is used where one exists:
`HKQuantityTypeIdentifierStepCount` becomes `step_count`,
`HKQuantityTypeIdentifierActiveEnergyBurned` becomes `active_energy`,
`HKQuantityTypeIdentifierOxygenSaturation` becomes `blood_oxygen_saturation`.
Anything uncurated has its `HKQuantityTypeIdentifier` or
`HKCategoryTypeIdentifier` prefix removed and the rest snake cased, so a type
Hozz has never heard of still gets a stable, predictable name instead of being
dropped. The full table is
[`MetricNameMap.swift`](../Sources/HozzDeliver/MetricNameMap.swift).

## InfluxDB line protocol

`text/plain; charset=utf-8`. One line per record, `\n` terminated, ready for
InfluxDB's `/api/v2/write` or for Telegraf with no translator in between.
**Lossy**: metadata, device detail beyond its name, and workout detail are
dropped.

```
health,type=heart_rate,source=Apple\ Watch,device=Apple\ Watch,unit=count/min value=62.5 1787433046500000000
health,type=sleep_analysis,source=Apple\ Watch value=3.0,duration=1800.0 1787436000000000000
health_workouts,type=workout,activity=Running,source=Apple\ Watch duration=1800.0,id="7b21c0de-0000-4000-8000-000000000001" 1787382000000000000
health_deletions,type=step_count,id=9c40c0de-0000-4000-8000-000000000002 deleted=true
```

Those four lines are asserted verbatim in `InfluxLineProtocolTests`, so this
document cannot drift from what Hozz actually writes.

### Measurements

| Measurement | Holds |
| --- | --- |
| `<measurement>` | Every sample with a numeric value. |
| `<measurement>_workouts` | Workouts. |
| `<measurement>_events` | Records with no numeric value at all, such as a correlation. |
| `<measurement>_deletions` | Tombstones. |

`<measurement>` defaults to `health` and is set per destination.

### Tags and fields

| Tag | Value |
| --- | --- |
| `type` | The metric name, e.g. `heart_rate`. `workout` for a workout. |
| `source` | The app or device that recorded it. Omitted when unknown. |
| `device` | The hardware name. Omitted when unknown. |
| `unit` | HealthKit's unit string. Omitted for types without one. |
| `activity` | Workouts only — `Running`, `Cycling`, and so on. |

| Field | Type | Where |
| --- | --- | --- |
| `value` | Float | Samples. |
| `duration` | Float | Seconds. Present when the record covers an interval. |
| `id` | String | Workouts and events, for tracing a point back to a record. |
| `deleted` | Boolean | Tombstones. |

Tags are the things worth grouping by, and every one of them is low cardinality:
a handful of sources, a handful of devices, a bounded set of types and units.
Record identifiers are deliberately **not** tags — a UUID in a tag is the
canonical way to ruin an InfluxDB instance — with one exception explained below.

### Timestamps

A point is timestamped with the sample's `startDate`, written in the precision
configured on the destination. **The precision has to match the `precision`
parameter on your write request.** InfluxDB does not report a mismatch; it
silently files every point in 1970 or in the far future.

Nanoseconds is the default and the recommendation. The conversion reads the
fractional digits out of the timestamp string rather than out of a parsed
`Date`, because a `Date` is a 64-bit float and near 2026 it has only about 400ns
of resolution — enough to collapse two samples a millisecond apart onto
timestamps that are not a millisecond apart.

Because InfluxDB will not tell you about a mismatch, Hozz reads the `precision`
parameter back out of the address and warns in the destination editor when it
disagrees with the precision selected there.

### Escaping

Hozz escapes exactly what InfluxDB requires, and no more:

| Element | Escaped |
| --- | --- |
| Measurement | Comma, space |
| Tag key, tag value, field key | Comma, equals sign, space |
| String field value | Double quote, backslash |

Every backslash is doubled in every position, because InfluxDB reads two
contiguous backslashes as one. That also removes the case that genuinely
corrupts a line: a tag value ending in a single backslash would escape the space
separating the tag set from the field set, and the write would fail.

Line protocol has no escape for a newline, so a newline or a null in any tag or
value is flattened to a space rather than being allowed to split the line in
two. An empty tag value is omitted, because InfluxDB rejects `source=`. A
measurement name beginning with `#` or `_` has that character removed — a
leading `#` makes InfluxDB read the whole line as a comment and discard it
without an error, and `_` is reserved for InfluxDB's own use.

Non-finite values never reach the wire as numbers. One `NaN` rejects the write
and takes every line that travelled with it, so a sample carrying one goes to
`<measurement>_events` rather than being invented or dropped.

### Two honest limitations

**InfluxDB deduplicates.** A point is identified by measurement, tag set, and
timestamp. Two samples of the same type, from the same source, at the same
instant become one point. Line protocol has no way to express otherwise without
putting a unique identifier in a tag, which would make the database unusable.
The lossless formats do not have this property, so if you need every sample kept
separately, send NDJSON somewhere alongside.

**A deletion is recorded, not applied.** Line protocol cannot retract a point.
Tombstones go to `<measurement>_deletions` so you can reconcile them yourself.
That measurement is the one place Hozz puts a record identifier in a tag, and it
is deliberate: a tombstone has no timestamp, so as a field every deletion in a
batch would land on the same series at the same instant and overwrite the one
before it. Not losing records is worth spending cardinality on, and it is spent
in a measurement nothing else queries.

### Sending it to InfluxDB

InfluxDB 2.x and 3.x:

```
POST http://influxdb.local:8086/api/v2/write?org=YOURORG&bucket=health&precision=ns
Authorization: Token YOUR_API_TOKEN
Content-Type: text/plain; charset=utf-8
```

InfluxDB 1.8:

```
POST http://influxdb.local:8086/write?db=health&precision=ns
```

Put the whole URL, query string included, in the destination's address field,
and the authorization value in the secret field below it. Hozz sends that secret
in the `Authorization` header, so for 2.x and 3.x it has to be written as
`Token ` followed by the token itself.

## Health Auto Export compatibility

An **opt-in** mode on the Home Assistant, MQTT, and web address destinations,
offered when the format is Metrics JSON. It emits the field names published by
Health Auto Export, so an automation or dashboard already built against that app
keeps working when pointed at Hozz. Hozz's own schema stays the default and is
the one to build anything new against.

```json
{
  "data": {
    "metrics": [
      {
        "name": "heart_rate",
        "units": "bpm",
        "data": [
          {
            "date": "2026-02-06 14:30:00 -0800",
            "Min": 62,
            "Avg": 62,
            "Max": 62,
            "source": "Apple Watch"
          }
        ]
      },
      {
        "name": "sleep_analysis",
        "units": "hr",
        "data": [
          {
            "startDate": "2026-02-05 23:00:00 -0800",
            "endDate": "2026-02-06 00:30:00 -0800",
            "qty": 1.5,
            "value": "Core",
            "source": "Apple Watch"
          }
        ]
      }
    ],
    "workouts": [
      {
        "id": "7b21…",
        "name": "Running",
        "start": "2026-02-06 07:00:00 -0800",
        "end": "2026-02-06 07:30:00 -0800",
        "duration": 1800
      }
    ]
  }
}
```

What changes from Hozz's own Metrics JSON:

| | Hozz | Compatibility mode |
| --- | --- | --- |
| Date format | `2026-02-06T22:30:00.000Z` | `2026-02-06 14:30:00 -0800` — local time, space separated, numeric offset, **not ISO 8601** |
| Heart rate points | `qty` | `Min`, `Avg`, `Max`, capitalised, with no `qty` |
| Heart rate units | `count/min` | `bpm` |
| Sleep points | `date`, `qty` as a raw stage number | `startDate`, `endDate`, `qty` in hours, `value` as a stage name |
| Sleep units | `count` | `hr` |
| Sleep stage | `0`–`5` | `In Bed`, `Asleep`, `Awake`, `Core`, `Deep`, `REM` |
| Workout `name` | `Workout` | The activity, e.g. `Running` |
| Workout `duration` | absent | Seconds |
| Per-point `units` | present | absent |

### What this mode does not claim

Hozz sends individual samples rather than rollups, so a heart rate point carries
the **same number in `Min`, `Avg`, and `Max`**. That is what one sample means.
The aggregated sleep shape, which only exists for summarised exports, is not
produced at all.

**Blood pressure stays split** into `blood_pressure_systolic` and
`blood_pressure_diastolic` rather than being paired as `systolic` and
`diastolic` on one point. Pairing them would mean guessing which two samples
belong together, and a wrong pair is worse than an unpaired one.

**Metadata-derived point fields are not emitted** — `mealTime` on blood glucose,
`reason` on insulin delivery, the sexual activity keys — because Hozz's delivery
batches do not carry that metadata.

**Deletions are still included**, under the `deletions` key. That app's format
has no tombstone, so this is an addition; a consumer written for their format
ignores a key it does not know, and dropping tombstones would leave a receiver
showing data the user deliberately removed.

Everything the mode does match is taken from the published format at
[help.healthyapps.dev](https://help.healthyapps.dev/en/health-auto-export/export-format/):
the `data.metrics[].{name, units, data}` envelope, the `yyyy-MM-dd HH:mm:ss Z`
timestamp, `qty`, the capitalised `Min`/`Avg`/`Max`, and the sleep point's
`startDate`/`endDate`/`value`. Hozz claims no compatibility with anything that
format does not document.

## Delivery mechanics

### Date range

Each destination has a **delivery window**, which is separate from how often it
syncs. The default, "Everything not yet sent", applies no date filter at all.

This is worth being precise about, because the name matches a setting in other
exporters that means something weaker. Hozz reads Health through opaque,
type-scoped anchors rather than date windows, because Health accepts samples
written retroactively — a workout imported this morning can carry yesterday's
date. A cursor of "everything since the last run" never sees those. An anchor
does: a record that appears is a record Hozz has not read before, whenever it
claims to have happened. So the default window is not a date range, it is the
*absence* of one.

The bounded ranges — Today, Yesterday, Yesterday and today, The last 7 days —
are a filter over records that have already been read, applied when the batch is
built. Days are the user's own calendar days, not UTC's. A record dated outside
the range is not delivered, and the acquisition cursor moves past it, so it does
not come round again on its own.

That has one safeguard, and it is the reason a bounded range is offered at all:
**widening a destination's range replays its whole history.** Going from Today to
The last 7 days, or from Today to Yesterday, clears that destination's cursors
and re-reads Health from the start. Every record carries the identifier HealthKit
gave it, so a receiver that stores by identifier keeps one copy of each. A
reading can therefore be excluded, but no reading is unreachable for ever.

Narrowing a range does not replay, because it excludes nothing that was already
delivered.

Records the range left out are counted on the receipt — "3 readings were outside
this destination's date range and were not sent" — including on a pass where
every record was excluded. Nothing arriving and nothing arriving *because you
asked for today only* look identical from the receiving end, and only one of them
is worth investigating.

### Endpoints

Every POST carries:

| Header | Meaning |
| --- | --- |
| `Content-Type` | The format's media type. |
| `Idempotency-Key` | The batch identifier. A repeat means the same bytes. |
| `Hozz-Batch-Id` | The same value, under a Hozz-specific name. |
| `Hozz-Batch-Sequence` | Batch number for this destination. |
| `Hozz-Record-Count` | How many records the payload holds. |
| `X-Hozz-Device` | What this phone calls itself. |
| *(configured)* | The destination's authorization header, read from the Keychain. |

Answer `2xx` to accept. Hozz treats `408`, `429`, and `5xx` as "try again" and
retries with backoff; anything else stops and asks the user to fix it. Response
bodies are discarded rather than logged, because a server rejecting a batch
frequently echoes the offending record back, and a Health value must not end up
in a log.

**The batch identifier is derived from the payload bytes.** A retry of the same
data reuses it, so you can safely discard a repeat. A retry that picked up newer
records gets a different identifier and has to be stored — reusing a key for
changed contents is how a correct receiver ends up discarding records it has
never seen.

### Folders

Files are named `hozz-<timestamp>-<destination>-<sequence>.<ext>`, which sorts
chronologically and cannot collide when two destinations share a folder. Line
protocol is not offered for folder destinations: Hozz's own Mac app watches a
folder for `ndjson`, `json`, and `csv` and ignores anything else, so a folder
writing line protocol would look like it was working while nothing was ingested.

### MQTT

The whole batch goes to `<root>/batch`, and — for Metrics JSON only — the latest
point of each metric goes to `<root>/<metric>`, retained at QoS 0. `<root>`
defaults to `hozz`. Other formats publish only `<root>/batch`, because there is
nothing to split per metric.

### Connection tests

A test sends a small probe in the destination's own format and reports what came
back. The format matters: a JSON probe posted to InfluxDB is rejected as
unparseable, which would report a correctly configured database as broken. For
line protocol the probe is a single point in `<measurement>_events` tagged
`type=hozz_connection_test`. No Health data is included in a probe.
