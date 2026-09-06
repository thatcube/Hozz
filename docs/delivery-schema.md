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
- [Delivery mechanics](#delivery-mechanics) — where to start, units, timeouts,
  headers, idempotency, retries

## Conventions

**Timestamps** are ISO 8601 in UTC with fractional seconds and a `Z` suffix:
`2026-08-22T21:10:46.500Z`. The one exception is the optional Health Auto Export
compatibility mode, which uses local time in that app's format.

**Units** are HealthKit's own unit strings, untranslated. A heart rate arrives
as `count/min`, not `bpm`; energy as `kcal`; distance in whatever unit Hozz's
type catalogue declares canonical for that type. This is deliberate — a unit
Hozz invented a nicer name for is a unit you cannot map back.

A destination may ask for different units (see [Units](#units)). When it does,
**the value and its unit always move together**, and the record additionally
carries `convertedFrom` naming the unit it held before. So a value can never be
read as something it is not, and a receiver comparing an old batch with a new one
can tell that the meaning of a column changed rather than having to infer it from
the numbers.

**Source identifiers** are normally lowercase HealthKit UUID strings.
`canonicalId` is exactly `sourceRecord.store + ":" + id`; receivers reject a
record that tries to substitute another canonical identity. Parented series
records bind `parentCanonicalId` to `sourceRecord.store + ":" +
sourceRecord.id`. This namespaces identity for cross-platform merge and projection;
synthetic detail/error records have their own deterministic ID and retain the
source record under `sourceRecord`.

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
| `canonicalId` | String | Stable Hozz identity across imports and projection retries. |
| `canonicalType` | String | Source-neutral Hozz type, e.g. `vitals.heart-rate`. |
| `recordVersion` | Integer | Monotonic Hozz version. Higher versions replace lower ones. |
| `id` | String | Original or deterministic record identifier. |
| `type` | String | Original platform type identifier, e.g. `HKQuantityTypeIdentifierHeartRate`. |
| `kind` | String | See below. |
| `startDate` | String | ISO 8601 UTC. |
| `endDate` | String | ISO 8601 UTC. Equals `startDate` for instantaneous samples. |
| `source` | Object | Where the sample came from. |
| `device` | Object | Optional. The hardware, when HealthKit named one. |
| `metadata` | Object | Optional. HealthKit metadata, type-tagged. |
| `sourceRecord` | Object | Original store, record ID/type, and source version when that platform exposes one. |
| `lineage` | Array | Stores/adapters this record has traversed. |

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
| `deletion` | — | A versioned tombstone with the same canonical identity as the removed record. |
| `sampleEncodingError` | `message`, optional `resolutionCanonicalId` | A sample Hozz could not encode, written in its place so the batch never silently omits it. A continuation failure resolves only when its deterministic end marker arrives or its parent is deleted. |
| `sample` | — | An `HKSample` subclass this build has no specific handling for. |
| `typeCoverage` | `state`, `complete`, `deliveredCount`, `primedFrom`, `primedThrough`, `observedAt` | Not a measurement: how completely Hozz has read one type. See below. |

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
(whose `value` is an array of tagged values), `nonFiniteNumber` (whose `value`
is `"nan"`, `"infinity"` or `"-infinity"`), or `unsupported` (with a `class`
naming what it was).

`nonFiniteNumber` exists because JSON has no way to write those three, and
handing one to a JSON encoder does not fail for that value alone — it makes the
whole record unwritable. A sample carrying one could not be encoded at all, and
for a series type that was permanent: the reader takes one sample per page, so
the cursor never advanced past it and the stream stopped for good. Reported as
what it is rather than dropped or rounded to something finite, because a number
that is not a number is a fact about the record.

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

### `typeCoverage`

How completely Hozz has read one type. Not a measurement, and never to be
stored as one: it carries no `id` and no `startDate`, deliberately, because it
describes a type rather than a moment.

```json
{
  "kind": "typeCoverage",
  "schemaVersion": 1,
  "type": "HKQuantityTypeIdentifierStepCount",
  "state": "anchorClosed",
  "complete": true,
  "deliveredCount": 147330,
  "observedAt": "2026-03-04T05:06:07.500Z"
}
```

This exists because a receiver cannot work it out. Hozz reads Health through
`HKAnchoredObjectQuery`, which returns samples in the order Health *stored*
them, not the order they happened. So for a type whose sweep is unfinished,
what has arrived is an arbitrary subset by date: the newest record delivered is
the newest record *delivered*, and says nothing about the newest record that
exists. A receiver shown only the records will read the first as the second —
one did, and told someone who wears a watch daily that they had not walked in
three years.

| Field | Meaning |
| --- | --- |
| `state` | Hozz's own word for how this type is being read. `draining`, `anchorClosed`, `authorizationIndeterminate`, `limitedAuthorizationWindow`, `deviceLockedDeferred`, `tombstoneGapSuspected`, `unsupported`, `unverifiedOnDevice`, `unknown`. |
| `complete` | `true` only when `state` is `anchorClosed`. **The one field that licenses presenting a date as the person's own most recent.** |
| `deliveredCount` | Records sent for this type so far, as Hozz counts them. Informational. Do not compare it against your own count to decide completeness; the two can differ legitimately. |
| `primedFrom`, `primedThrough` | A stretch filled by a dated query rather than the sweep, so everything in it is present. Both are achievements, never intentions. Absent when there is no such stretch. |
| `observedAt` | When Hozz observed all of the above — that is, when this coverage last *changed*, not when it was last confirmed. Use it to decide whether an arriving report is newer than one you hold; deliveries can be retried and a folder of exports can be read in any order. |

There is deliberately **no "swept through &lt;date&gt;" field**. That number
would be easy to compute and would look authoritative, and the sweep's ordering
cannot support it.

Two things a report does not claim, both worth knowing before writing a
sentence about one:

- `anchorClosed` after a stream that never returned an object is reported as
  `authorizationIndeterminate` instead, because HealthKit answers identically
  for a type you have no records of and one Hozz was never granted. Treating it
  as complete would present a type nobody has permission to read as a type the
  person genuinely has nothing for.
- A primed window means every *sample* Health holds in it is present. A dated
  read has no tombstone channel, so deletions arrive only through the sweep,
  and the expanded readings inside a high-frequency series sample are not part
  of a prime — only the sample itself.

Absence of a report is not evidence of completeness. A receiver that has never
been told anything about a type knows nothing about it, which is a third state
and not a quieter version of either of the other two.

Reports are attached to every lossless batch, so any batch brings a receiver
fully up to date; a batch carrying nothing else is delivered when coverage
changes and nothing new was read. They are omitted from CSV, Metrics JSON and
line protocol, which have no shape that could carry one without it arriving as
a row of blanks or as a metric named after a type.

## NDJSON
Default. One record per line, `\n` terminated, `application/x-ndjson`. Lossless.
ZIP exports also carry `hozz-manifest.json`, which declares schema v1 and the
NDJSON member name. Raw NDJSON and older one-member ZIPs remain legacy inputs;
sidecar-declared v1 records are validated strictly.

```
{"canonicalId":"apple.healthkit:2f1a…","canonicalType":"vitals.heart-rate","catalogVersion":6,"endDate":"2026-08-22T21:10:46.500Z","id":"2f1a…","kind":"quantity","lineage":[{"recordId":"2f1a…","store":"apple.healthkit"}],"metadata":{},"quantity":{"canonical":{"unit":"count/min","value":62.5},"description":"62.5 count/min","original":{"description":"62.5 count/min"},"unit":"count/min","value":62.5},"recordVersion":1,"schemaVersion":1,"source":{"bundleIdentifier":"com.apple.health.ABC","name":"Apple Watch","operatingSystem":{"major":26,"minor":5,"patch":0}},"sourceRecord":{"id":"2f1a…","store":"apple.healthkit","type":"HKQuantityTypeIdentifierHeartRate"},"startDate":"2026-08-22T21:10:46.500Z","type":"HKQuantityTypeIdentifierHeartRate"}
{"canonicalId":"apple.healthkit:9c40…","canonicalType":"activity.steps","id":"9c40…","kind":"deletion","lineage":[{"recordId":"9c40…","store":"apple.healthkit"}],"recordVersion":2,"schemaVersion":1,"sourceRecord":{"id":"9c40…","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
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

An explicit `sampleEncodingError` has no numeric point to publish, so Metrics
JSON omits it rather than inventing a value. Hozz records that omission
durably with the destination cursor. If the same destination is later changed
to NDJSON or JSON, its sweep and recent-history prime replay so the lossless
format receives the error record and every other record that was passed under
the narrower format. Destination settings carry a persisted revision; a sync
that started under an older format cannot commit its cursor after that edit.
The element pages and end markers that expand high-frequency series are treated
the same way: Metrics JSON and line protocol omit those detail records, seal
that omission with the cursor, and replay them if the destination later becomes
lossless.

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
| `metrics[].data[].qty` | Number | Always present. Metrics JSON carries quantity and category samples; types without a defensible numeric value are not drained for this destination, so their anchors remain available if the destination is changed to a lossless format. |
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

### Where to start

Each destination has a **starting point**, which is separate from how often it
syncs. The default, "Everything not yet sent", applies no date filter at all.

That name matches a setting in other exporters which means something weaker, so
it is worth being precise. Hozz reads Health through opaque, type-scoped anchors
rather than date windows, because Health accepts samples written retroactively —
a workout imported this morning can carry yesterday's date. A cursor of
"everything since the last run" never sees those. An anchor does: a record that
appears is a record Hozz has not read before, whenever it claims to have
happened. So the default is not a date range, it is the *absence* of one.

Every other choice resolves, once, to a single date:

| Setting | Resolves to |
| --- | --- |
| Everything not yet sent | No date. Nothing is excluded. |
| Start from today | Local midnight on the day it was chosen. |
| Start from yesterday | Local midnight the day before it was chosen. |
| Start from 7 days ago | Local midnight seven days before it was chosen. |
| Start from 30 days ago | Local midnight thirty days before it was chosen. |

Readings dated before that date are not delivered. Everything from it onwards is,
with **no upper bound** and **no movement of the date afterwards**. Both of those
are correctness requirements rather than conveniences.

An upper bound loses records twice over. A sample HealthKit gains while a sync is
already running comes back dated after the pass began, so a bound at "now"
excludes it and the cursor commits past it. And a range ending before today — a
"Yesterday only" — rejects everything dated today, which is exactly when today's
readings are drained; the steady state is a destination receiving nothing while
reporting success. Neither is offered.

A date that moved with the clock would be worse still, because sleep is dated
from bedtime. A line at "midnight this morning", evaluated when the 07:00 sync
runs, throws away every night's sleep, every night. A daily destination running
at 02:00 drains twenty-five hours and discards twenty-three. An endpoint down for
ten minutes at 23:55 has its retry judged against the next day's line, so an
outage erases a day. Resolving the date once removes all three: it recedes into
the past and never excludes anything again.

What remains is one deliberate exclusion — a reading dated before the day the
user picked, including one Health files retroactively — and it is made safe by
two things:

- **It is counted.** Receipts carry "3 readings were older than this
  destination's limit and were not sent", including on a pass where everything
  was excluded. Nothing arriving and nothing arriving *because you asked to start
  from today* look identical from the receiving end, and only one is worth
  investigating.
- **Moving the starting point earlier replays the whole history.** That clears
  the destination's cursors and re-reads Health from the beginning. Every record
  carries the identifier HealthKit gave it, so a receiver that stores by
  identifier keeps one copy of each. A reading can be excluded; no reading is
  unreachable for ever.

Moving it later does not replay, because it excludes nothing already delivered.

### Units

A destination can ask for values in units of its choosing, per group:

| Group | Choices |
| --- | --- |
| Distance | `km`, `mi`, `m` |
| Height and body measurements | `cm`, `in`, `ft` |
| Weight | `kg`, `lb`, `st` |
| Energy | `kcal`, `kJ` |
| Temperature | `degC`, `degF` |
| Speed | `km/hr`, `mi/hr`, `m/s` |
| Volume | `L`, `mL`, `fl_oz_us` |
| Blood pressure | `mmHg`, `kPa` |

Groups rather than individual metrics, because a person has one opinion about
distance and one about weight, not a hundred. Distance and body measurements are
separate although both are lengths: somebody who runs in miles does not want
their height in miles.

Every conversion factor is a defined value rather than a rounded one — an inch is
exactly 0.0254 m, a pound exactly 0.45359237 kg, a thermochemical kilocalorie
exactly 4184 J — so a marathon is 42.195 km and 26.219 miles either way round.
Temperature uses its offset rather than a factor, because 38 °C is 100.4 °F and
not 38 °F.

Anything with no conversion is left exactly as Health gave it: a count, a
percentage, a heart rate in `count/min`. So is any reading whose unit Hozz does
not recognise. That is safe rather than a gap, because the payload always carries
the unit next to the value — a reading that was not converted is still labelled
correctly, and nothing is ever mislabelled.

Where the converted unit appears, by format:

| Format | Value | Unit |
| --- | --- | --- |
| NDJSON, JSON | `quantity.value` | `quantity.unit`, plus `quantity.convertedFrom` |
| CSV | `value` column | `unit` column |
| Metrics JSON | each point's `qty` | the metric's `units`, plus `convertedFrom` |
| InfluxDB line protocol | *not converted* | — |

Line protocol is deliberately excluded, and the setting is not offered for it.
The unit is a tag inside a line whose escaping rules differ by position, and
rewriting one in place is the kind of edit that silently corrupts a batch
InfluxDB then rejects whole. Not offering the setting is better than offering it
and quietly not applying it.

Changing a destination's units does not rewrite anything already delivered. A
receiver keeping a long history will hold both, each correctly labelled — which
is why `convertedFrom` exists.

### Timeout

REST destinations carry a request timeout, chosen per destination, defaulting to
the 60 seconds `URLSession` would use anyway. A large batch posted to a small
computer — a Home Assistant on a Raspberry Pi writing to an SD card — can take
minutes to be accepted, and giving up early reports a working server as a broken
one. The batch is retried either way, so a long timeout costs time rather than
data.

### Endpoints

Every POST carries:

| Header | Meaning |
| --- | --- |
| `Content-Type` | The format's media type. |
| `Idempotency-Key` | Identifies these exact bytes. A repeat means the same bytes. |
| `Hozz-Batch-Id` | The batch this body belongs to. Shared by every part of a split batch. |
| `Hozz-Batch-Sequence` | Batch number for this destination. |
| `Hozz-Record-Count` | How many records **this body** holds. |
| `Hozz-Destination-Id` | Which configured destination this is for. |
| `Hozz-Destination-Name` | Its name, percent-encoded. Absent if empty. |
| `Hozz-Format` | `ndjson`, `json`, `csv`, `metrics`, or `influx`. |
| `Hozz-Schema` | `hozz` or `healthAutoExport`. |
| `Hozz-Window` | The starting point in force, e.g. `sinceLastDelivery`. |
| `Hozz-Part` / `Hozz-Part-Count` | Present only on a batch split across requests. |
| `X-Hozz-Device` | What this phone calls itself, percent-encoded. |
| *(configured)* | The destination's authorization header, read from the Keychain. |

Enough to route a payload without opening it. Every one of these is
configuration: **no header carries a reading, a value, or a credential** — except
the authorization header the user named themselves, which carries only that.

`Hozz-Destination-Name` and `X-Hozz-Device` are percent-encoded, because a header
value is defined as ASCII and iOS names a phone with a typographic apostrophe by
default. Sent raw, "Brandon’s iPhone" is bytes a server may refuse and that most
frameworks decode as Latin-1 into nonsense. A name that is already ASCII is sent
unchanged, so nothing changes for anyone whose headers were already correct.
Decode with any standard percent-decoder; the percent sign itself is encoded, so
a name containing one round-trips.

There is deliberately no equivalent of another exporter's `automation-aggregation`
header. Hozz never aggregates — it sends the individual samples HealthKit
returned — so the field would have exactly one value for ever.

#### Split batches

A destination can cap how large a single request may be. Anything bigger is sent
as several sequential POSTs, each a complete, valid payload of the same format.

Every part shares `Hozz-Batch-Id` and carries `Hozz-Part` (1-based) and
`Hozz-Part-Count`. **Each part has its own `Idempotency-Key`**, derived from its
own bytes — giving every part the batch's key would make a correct receiver treat
parts two onwards as repeats of part one and discard them, so the batch would
arrive a fraction complete and look perfect from both ends.

If a part fails, Hozz stops there rather than sending the rest: a gap in the
middle is one the receiving end has no way to notice. None of the batch is
counted as delivered, the acquisition cursor does not move, and the whole batch
is sent again from the first part on the next attempt. The parts that already
landed carry the same bytes, and therefore the same key, so a receiver that
honours it stores each reading once.

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
