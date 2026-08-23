# Hozz

**Export Apple Health data to destinations you own.**

Hozz is a free, open-source iPhone app with a companion Mac receiver. The iPhone app reads the Health data Apple lets an app read, exports it on demand, and can keep user-configured destinations up to date in the background. The Mac app receives those deliveries, stores them in a local SQLite database, charts them, and can expose them to an MCP-capable assistant running against that local database.

There is no subscription, account, analytics, advertising, hosted relay, or default network destination. Nothing leaves the iPhone until you add a destination and confirm it.

Hozz is still early alpha. It currently exports quantity samples, category samples, workout records, workout routes, electrocardiograms, audiograms, State of Mind entries, medication doses, historical deletions, and the six Health characteristics. Correlations, other series, documents, scored assessments, and clinical records are catalogued or acknowledged where relevant, but not claimed as exported coverage.

## What works today

The iPhone app has two paths: **Automatic** and **Export**.

A first sync works through your history a bounded batch at a time, giving every type a share of each pass rather than draining one to exhaustion before starting the next. That ordering matters more than it sounds: taking types strictly in turn meant a phone with years of stand hours sent nothing else for days, which is a working sync that reads exactly like a broken one. The dashboard says how many types have been reached out of those selected, and the Mac says how many have arrived and how far back they reach. Neither shows a percentage or an estimated time: Health will not say how many records a type holds without reading all of them, so any fraction would be invented, and a progress bar is a promise about time remaining.

Automatic export sends new Health records to destinations you configure. Destinations can be limited to selected Health types, turned off, set to run when data arrives, hourly, daily, or only manually, and tested before you trust them. The dashboard shows the last successful delivery, retry or attention states, and a one-tap **Sync now** action. Shortcuts expose **Sync Health Data** and **Check Health Sync Status**.

Supported automatic destinations are:

| Destination | What Hozz sends |
| --- | --- |
| This Mac | NDJSON batches to the Hozz Mac receiver over the local network, with token authentication. |
| Folder | Batch files written through the Files picker to iCloud Drive, Dropbox, OneDrive, Google Drive, SMB, or on-device storage. |
| Home Assistant | Metrics JSON to a webhook or REST endpoint. |
| InfluxDB | Line protocol written straight to `/api/v2/write` or 1.8's `/write`, with a configurable measurement and timestamp precision. |
| Web address | NDJSON, JSON, CSV, Metrics JSON, or InfluxDB line protocol POSTs to an endpoint you run. |
| MQTT | MQTT 3.1.1 publishes to `mqtt://` or `mqtts://`, using retained QoS 0 topics. |

Background delivery is requested with `HKObserverQuery` and `enableBackgroundDelivery`, then coalesced into bounded sync passes. iOS still decides when background work runs, most Health types are capped at hourly delivery, Health cannot be read while the phone is locked, and force-quitting Hozz stops launches until the app is opened again. Hozz reports those states rather than calling them success.

Manual export creates a full historical export you can save or share from the phone. It is resumable: pausing, backgrounding, expiration, a kill, or a reboot resumes from the last durable checkpoint instead of starting over.

## Formats

Manual exports are built from a canonical NDJSON spool. That spool is the durable format because it streams, survives interruption, and can be assembled without recompressing. Presentation formats are produced from it at the end.

| Format | Output | Notes |
| --- | --- | --- |
| NDJSON | `.zip` containing one `.ndjson` member | Default. One record per line, streamable, and lossless for the fields Hozz currently encodes. |
| CSV | `.zip` with one CSV per Health type, plus deletion and export-log files when needed | Opens in spreadsheets. Explicitly lossy: metadata and nested workout details do not fit a grid. |
| JSON | `.zip` containing one JSON array | Convenient for smaller exports and tools that expect a single JSON value. |
| SQLite | `.sqlite` database | Query it in Datasette, DuckDB, pandas, Grafana, or `sqlite3` with no import step. Not lossy: every row keeps its original record in `raw`. |
| Markdown | `.zip` of one `YYYY-MM-DD.md` note per day | For Obsidian and journals, with YAML front matter Dataview can query. Explicitly lossy: a note keeps a day's totals, never the records behind them. |
| GPX | `.zip` of one GPX 1.1 track per workout with GPS | For maps, Strava-alikes, and anything that reads a track. Not a projection but a **filter**: it exports routes and nothing else. |
| Raw NDJSON | `.ndjson` | Supported by the export engine for direct piping; the main picker exposes NDJSON, CSV, JSON, SQLite, Markdown, and GPX. |

The SQLite file is built for asking questions rather than for mirroring the
JSON. Everything time-shaped except workouts goes into one wide `sample` table
with a `type` column, because the queries worth having — compare two types over
the same period, show everything that happened last Tuesday — are cross-type,
and a table per type turns them into a hundred-way union. Workouts, deletions
and characteristics have genuinely different shapes and get their own tables, a
`record` view puts the time-shaped ones back on one timeline, and a `daily` view
covers the aggregate most questions start from. Indexes cover one type over a
period, any type in a window, day-grouped totals, and filtering by source.

Because every row also stores the untouched export line in `raw`, anything the
columns leave out is still reachable with `json_extract`, which is why SQLite is
offered without the lossy label CSV carries. `meta` records when the export ran,
what it covered, and which time zone the `local_day` columns were bucketed in —
a UTC day would file an evening workout under the following morning.

The Markdown export is the opposite trade, made deliberately. Each note carries
YAML front matter for Dataview — steps, sleep hours, workout minutes, resting
heart rate — then the day in prose and small tables. It keeps a day's counts,
totals and extremes and throws the records themselves away, along with metadata,
sources, devices and sample identifiers, so the picker, a `README.md` in the
archive, and the foot of every single note all say so and point at the formats
that keep everything. Days are local days, and sleep is filed under the day it
ended, because last night's sleep belongs to the morning you woke up.

Automatic destinations use `DeliveryFormat`: NDJSON, JSON, CSV, Metrics JSON, or InfluxDB line protocol. Metrics JSON groups points by metric name for Home Assistant, MQTT, and dashboards; deletions are carried alongside instead of silently dropped. Neither SQLite nor Markdown is offered there: a delivery is an append of new records to an endpoint or a folder, a database file is not appendable over HTTP, and a day's note rewritten from one batch would replace a full day with a fraction of it.

**[`docs/delivery-schema.md`](docs/delivery-schema.md) documents every delivery format field by field**, with a worked example payload for each, the escaping rules, and the delivery headers — so something can be built against Hozz without reading the source.

Line protocol exists because the alternative was making people run a translator. The usual self-hosted setup is Health data in InfluxDB charted in Grafana, and reaching it meant deploying a container whose entire job was turning an exporter's JSON into the format InfluxDB already wanted. It is deliberately not offered for folder destinations: the Mac app watches a folder for NDJSON, JSON, and CSV, so a folder writing line protocol would look like it was working while nothing was ingested.

The Home Assistant, MQTT, and web address destinations also have an **opt-in** compatibility mode that emits Health Auto Export's published field names, for people arriving with automations and scripts already keyed to them. It matches what that format documents and says plainly what it does not: Hozz sends individual samples rather than rollups, so a heart rate point carries the same number in `Min`, `Avg`, and `Max`, and blood pressure stays split rather than guessing which two samples pair. Hozz's own schema remains the default and the recommended one.

The GPX export is the odd one out, and the interface says so before it is
chosen. Every other format takes everything in the export and keeps less of each
record; this one takes almost nothing in the export and keeps all of what it
takes. A GPX file is a track, with nowhere to put a heart rate or a body weight,
so a workout recorded without GPS produces no file — a treadmill run has no
route, and that is not an error. It exists because GPX is what every mapping and
fitness tool reads, and a route delivered as JSON is of no use to someone moving
their rides to something they host themselves.

Routes arrive as pages at fixed absolute offsets, so a sync that was interrupted
leaves a hole of a known size rather than a shorter list. That is what makes it
possible to be honest about a gap instead of quietly closing it, and closing it
is the real hazard: a GPX that joins the two sides of a missing page draws a
straight line across a mile of city and looks completely correct. So a gap
becomes a separate `<trkseg>` on each side — which is what a track segment means
in GPX and what every renderer already honours — the track's `<desc>` says how
many points are missing and where, and the archive's `README.md` lists every
affected file. A route whose pages never arrived at all produces no file rather
than an empty track, because an empty track is a claim that the ride had no
points. Speed, course, and Core Location's accuracies have no element in base
GPX and are published under Hozz's own namespace in `<extensions>` rather than
invented as bare elements that would fail validation.

## What each format reads

Most formats present the whole of Health, so a run reads everything Hozz can read. GPX is different: it is a filter rather than a projection, since a GPX file holds a route and nothing else. A GPX run therefore reads only workouts and their routes.

That is a speed difference measured in hours for someone with years of history — reading two hundred types to write out a handful of tracks produces a file that could not have contained the difference. It is safe as well as faster because a manual export keeps its cursors under its own run, so a narrowed run cannot advance a cursor that a full export or an automatic destination depends on.

Progress is reported out of what the run actually reads. A run covering two types says two, rather than appearing stuck at one percent of the catalogue.

## Health acquisition and durability

Hozz does not use date-window watermarks. Each HealthKit type has its own opaque, device-local anchor, drained with `HKAnchoredObjectQuery`. An anchor advances only after the records it covers have been durably staged.

For a manual export, records are written to an open spool part and anchors are only committed when that part is sealed in the same store transaction. An unsealed part is deleted on relaunch and replayed from the previous anchor. The result is the property that matters: interruption can repeat work, but it cannot skip records or publish a half-finished export as complete.

A pass gives every type a small share before spending what is left on whatever has the most to send, and the order rotates hourly. Draining strictly in catalogue order meant the first type with a backlog took the whole pass and everything behind it waited — someone with years of stand hours saw no step count for weeks. A type is recorded as caught up only when Health returns an empty page; one the budget cut short stays `draining`, so the store never claims a type is finished when it is not.

Automatic sync uses the same anchor rule per destination. Each destination has its own cursor, so a failed destination cannot advance past data it did not accept, and one broken destination does not block a healthy one. Batches use stable content-derived identifiers and `Idempotency-Key` headers so a retry can be accepted safely.

Apple does not let apps distinguish “the user denied this Health type” from “there is no matching data.” Hozz therefore reports authorization-scoped coverage and keeps denied-or-empty, unavailable, unsupported, and failed states visible.

## Characteristics

Date of birth, biological sex, blood type, Fitzpatrick skin type, wheelchair use, and activity move mode are not samples. They have no UUID, no dates, no source, and no anchor, so they cannot travel through the anchored-query path. Hozz reads them whole and writes one `characteristics` record per export attempt, ahead of the measurements.

They are worth the separate path because they are what makes the rest interpretable. A resting heart rate of 48 reads differently depending on age and sex, and without them an assistant reading the export cannot answer “is this normal for me”.

Each characteristic carries its own state rather than a blank:

| State | Meaning |
| --- | --- |
| `known` | Health returned a value the person set. |
| `notSet` | Health answered, and the person never entered one. An unknown fact, not a failure. |
| `unrecognised` | Health returned a value this build has no name for. The raw number is kept, so the fact survives. |
| `unavailable` | The characteristic does not exist on this OS, or Health is unavailable here. |
| `unreadable` | Health refused or could not answer, with the coverage state and reason. |

Unlike sample types, these four situations really are distinguishable: HealthKit throws a distinct authorization error when a characteristic was refused and a distinct no-data error when it was simply never set, so Hozz reports refusal and absence apart instead of flattening both.

The record is written on every export attempt, including resumed ones, because the part holding an earlier copy may have been discarded unsealed. Each carries its own `readAt`. In a CSV export they are also flattened into `characteristics.csv`, one row per characteristic including the unset ones, while the lossless copy stays in `export-log.ndjson`.

## Workouts

A workout used to export as an activity type and a duration: you could tell that a run happened, and nothing about how it went.

Health computes its own aggregates for a workout and carries them on the sample, so they cost no extra query. Each is written with the unit that type's individual samples use, so a workout's average heart rate can be compared with the heart rate samples without converting anything. Only the aggregates Health actually offers are written — a discrete type like heart rate has an average, minimum, and maximum but no total; a cumulative one like energy has a total and none of the others — and an aggregate it does not offer is left out rather than written as zero.

A workout made of several efforts, like a triathlon, also carries each leg with its own figures, because an average across all three describes none of them.

These are **summaries of samples that are exported separately**, not copies of them. Every reading appears exactly once in an export, as itself; nothing here repeats one.

**Hozz does not export which individual samples belonged to a workout.** HealthKit will list the objects belonging to a workout, but offers nothing in the other direction — a sample does not know its workout, and no workout identifier appears in its metadata — so recording the link would mean a query per workout per type, tens of thousands of them for a real history.

Matching by time range is therefore an approximation, and worth knowing you are making one. It is a good approximation for most workouts and wrong in two situations: workouts that overlap in time, and samples recorded inside the window by something other than the workout — a phone counting steps in a pocket during a ride, for instance. The workout's own statistics above are exact, because Health computed them; a time-range join is your reconstruction, not Health's answer.

## Series types: routes and electrocardiograms

A workout route and an electrocardiogram are the same shape of problem. Each is one Health sample whose real content is somewhere else: a route's GPS points and an ECG's voltage readings arrive as separate streams, and a long ride holds hundreds of thousands of points where a thirty-second ECG holds around fifteen thousand readings. Both go through one implementation, so the part that could lose or duplicate data is written and tested once.

Each sample is written as three kinds of record:

| Kind | What it holds |
| --- | --- |
| header | The sample itself — for a route, the workout it belongs to; for an ECG, its classification, average heart rate, sampling frequency, and symptoms status. |
| elements | 500 points or readings, addressed by their absolute offset in the sample. |
| end | The final element count, so a whole sample is distinguishable from a truncated one. |

**Streaming.** The cursor for a series type records which sample is half-written and how far into it Hozz has got, so a ride or a recording is never held in memory whole. The element stream stays open between pages, which keeps the ordinary path to a single read of each element; a relaunch has no stream to continue, so it re-opens the sample and skips what is already durable, paying that re-read once after an interruption rather than on every page.

Pages are split at fixed offsets rather than at wherever a pass happened to stop, and each page's identifier is derived from the sample and that offset. A replayed page is therefore identical to the page it replaces, so a receiver recognises it as the same record instead of storing it twice.

**Routes** are drained as their own anchored type rather than fetched per workout. That is not a stylistic choice: a route is attached after its workout has already been saved, so a workout read before its route existed would never gain one, and the trace would be lost permanently.

HealthKit has no back-pointer from a route to its workout, so Hozz takes the workouts that overlap the route in time and asks each one whether this route is actually its own. Only a confirmed answer is written. Overlap alone would attach a ride to whatever else happened to be recorded at the same moment, so an unconfirmed route says `"state": "unresolved"` with a reason rather than naming a workout it guessed.

**Electrocardiograms** carry the reading that makes them interpretable — `sinusRhythm`, `atrialFibrillation`, one of the inconclusive results — alongside the raw enumeration value, so a classification from a later OS is still readable rather than becoming a gap. A reading the lead did not report is written as a gap rather than as zero volts, an absent average heart rate is left out rather than written as zero, and the number of readings Health said the recording holds is kept beside the number actually exported, so a short read is visible instead of looking complete.

In a CSV export these become `WorkoutRoutes.csv`, `WorkoutRouteLocations.csv`, `Electrocardiograms.csv`, and `ElectrocardiogramVoltages.csv` — one row per sample and one row per element, because a recording collapsed into a single cell would not be data any more.

## Audiograms

A hearing test is not a series: its sensitivity readings sit on the sample itself, at most thirty of them, so it travels the ordinary anchored path.

Two things a flat reading would throw away are kept. An ear with nothing recorded produces no reading at all, rather than a zero — 0 dBHL is perfect hearing, so writing it for an ear that was never measured would be a claim rather than a gap. And a reading Health marks as clamped is written with its bound, because a clamped 90 dBHL means "at least 90", not "90". Where the OS supports it, conduction type and whether the test was masked are carried too.

In a CSV export a hearing test becomes `Audiograms.csv`, one row per ear reading.

## Quantity series

HealthKit stores some readings — a workout's power, cadence, or speed — as a *series*: one sample whose quantity is an aggregate over `count` individual values, reachable only through `HKQuantitySeriesSampleQuery`.

Hozz does not expand those series yet. What it does do is say so: every quantity record carries its `count`, and one standing for more than a single reading is marked `aggregatesSeries`. Without that, an average of three hundred readings is indistinguishable from one measurement, which understates nothing and overstates everything.

## State of Mind

Mood entries logged in Health on iOS 18 and newer: a valence from -1 to 1, the classification Health derives from it, whether the entry was a momentary feeling or a whole day's mood, and the labels and life associations the person chose.

The care here is about what a blank would mean. **Zero valence is a neutral mood, not a missing reading**, so it is always written and never omitted — the same trap as 0 dBHL in a hearing test. An empty list of labels means the person picked none, which is a fact rather than an absence, so the list is written empty rather than left out.

Every label, association, classification, and entry kind is written as a name *and* the number behind it, so a feeling Apple adds in a later release still arrives as something instead of becoming a gap in someone's mood history.

In a CSV export mood entries become `StateOfMind.csv`, and in the SQLite export valence is the value a mood can be charted on over time.

## Medication doses

Doses logged in Health on iOS 26 and newer. This is the dose-logging API, not the clinical `MedicationRecord`, and it needs no special entitlement.

A dose event names its medication only through an opaque concept identifier — HealthKit exposes no stable string for it — so the name, form, and codings are fetched separately and matched up. That list is read once per drain rather than once per dose, because a course of tablets is thousands of events pointing at the same handful of medicines. A dose whose medication cannot be found is still exported, and says the medication is `unresolved` rather than being dropped or given a name it does not have.

The log status is the whole meaning of a dose: `taken`, `skipped`, `snoozed`, and `notInteracted` are different facts about someone's treatment, and only the first means the medicine was used. Each is written with its name and the number behind it.

Quantities stay optional. A dose nobody logged is absent rather than zero, because "took none" and "logged nothing" are different, and only one of them is a dose of zero. A recorded dose of zero is kept as the reading it is.

In a CSV export doses become `MedicationDoses.csv`, one row per dose.

## Health records (clinical records)

Lab results, conditions, medications, immunisations and the rest, as FHIR resources from a connected provider.

**These are not in the released build, and the code that would read them is compiled out.** Reading them needs `com.apple.developer.healthkit.access` carrying `health-records`, which Apple grants by application, and submitting a binary that carries it before approval is an automatic rejection. The entitlement array in `project.yml` therefore ships empty and the Swift flag that enables the code is undefined by default.

Turning it on once approval lands takes two deliberate steps:

1. Build with `HOZZ_CLINICAL_FLAG=HOZZ_CLINICAL_RECORDS`, on the `xcodebuild` command line or in the gitignored `Local.xcconfig`. This changes no entitlement, so on its own it cannot cause a rejection — the code simply compiles and reports that the entitlement is missing.
2. Change `com.apple.developer.healthkit.access` in `project.yml` from `[]` to `[health-records]`. This is the step with consequences, which is why it is a visible edit to a tracked file rather than a switch.

Both build configurations are tested, so the flag cannot rot while it is switched off.

When it is off — which is every released build today — the app says health records are **not available in this build**, and says explicitly that this is not a statement about whether you have any. Someone with a hospital connected to Health being told their records are empty would be the worst version of this feature.

Three things about the data itself:

- **Consent is per record.** Health asks which records to share, one by one, and Hozz cannot see what was withheld. Partial access is the normal case, not a failure, so nothing treats a small result as an error. It is asked for in its own prompt: someone exporting step counts is never asked for their lab results as a side effect.
- **The FHIR resource is carried through as the provider sent it**, not reshaped into Hozz's vocabulary. A result's units, reference ranges and coding systems *are* the clinical meaning, and any projection would lose some of it while looking complete. A resource Hozz cannot parse is kept as bytes rather than dropped.
- **A clinical record's identity is not its HealthKit UUID.** Apple states the UUID is not stable for these records and that source, resource type, and FHIR identifier should be used instead. Since every destination deduplicates on the identifier, keying on the UUID would file the same lab result again on every sync — a growing pile of identical results, which in a medical record is misleading rather than merely untidy. Hozz derives the identity from the three stable fields and keeps the UUID alongside, labelled, for tracing.

## Mac receiver

The Mac app is a local receiver and browser for data the phone sends. It starts an `NWListener` HTTP receiver, advertises `_hozz._tcp`, normally listens on port **54330**, accepts `/pair` without a token, and requires the token for deliveries. It stores accepted batches in `hozz-received.sqlite` with schema version 6, idempotent batch records, deletions, characteristics, and per-device “last heard from” state.

Setup is designed to avoid typing an address. The phone first browses Bonjour, also reads receiver records published through the user's own iCloud Keychain, then falls back to a private `/24` local-network sweep on port 54330. Every remembered address is probed before it is offered or reused, so a computer that does not answer is shown as offline instead of saved as a dead destination.

The Mac app also watches a folder for automatic batch files. Point the phone at a synced folder, pick the same folder on the Mac, and the Mac ingests new NDJSON, JSON, CSV, or Metrics JSON files as they arrive. This path works when the local network refuses inbound connections.

The Mac UI has four tabs:

- **Connect** shows the receiver, folder watcher, token, and honest per-device status based on when data last arrived.
- **Data** lists what has arrived and how far back it reaches, shows the person's own characteristics above the measurements, charts numeric values by hour/day/week/month, exports a type as CSV, and names anything received in a form this version cannot read yet.
- **Assistant** shows the MCP configuration to copy into an assistant.
- **Activity** lists recent accepted, duplicate, paired, test, and rejected deliveries without logging sample values.

A small standalone Python receiver remains in `receiver/` for people who want a dependency-free script instead of the Mac app.

## MCP assistant access

The Mac app embeds a read-only MCP server at:

```text
Hozz.app/Contents/MacOS/hozz-mcp
```

It speaks JSON-RPC 2.0 over stdio, advertises protocol version `2024-11-05`, server name `hozz`, version `1.0.0`, and exposes ten tools. They are documented in **[docs/mcp.md](docs/mcp.md)**, which covers what each one answers, a copy-pasteable client configuration, and what the analysis tools will and will not claim:

- `list_health_types`
- `summarise_health_data`
- `aggregate_health_data`
- `list_health_samples`
- `list_electrocardiograms`
- `get_electrocardiogram_voltages`
- `list_audiograms`
- `analyse_health_trend`
- `compare_health_types`
- `find_health_anomalies`

Most Apple Health MCP servers read the bulk XML export, which is a snapshot: correct the day you make it and stale the next morning. Hozz queries a local database the phone keeps current in the background, so a question costs an indexed lookup rather than a re-parse of hundreds of megabytes. That is the main reason to choose it.

The three analysis tools are built to be hard to overstate, because their output goes straight to a language model that will narrate a story around any number. A trend reports "no detectable change" when a flat line fits as well as a sloped one, and refuses below two weeks of days. A correlation puts its interval on an autocorrelation-adjusted sample size, since consecutive days are not independent evidence, and warns when both series are trending. Anomalies use the median and median absolute deviation, and a day with too few records is reported as *the device was not worn* rather than as a low reading. **[docs/mcp.md](docs/mcp.md)** sets out exactly what each tool will and will not claim, and carries the client configuration to copy.

The tool must be given the Mac app's received-data directory, and the Mac app is sandboxed while the assistant launches `hozz-mcp` outside that sandbox — so a guessed path opens an empty directory and every tool truthfully reports no data. Open the Mac app's **Assistant** tab and copy the configuration it generates. The server can only read; it has no code path that writes. If you connect it to a cloud-hosted assistant, that assistant may upload whatever it reads. That is the assistant's behaviour, not Hozz's.

## Why Hozz does not write back into Apple Health

This gets asked, so: it is a decision, not an oversight, and not something waiting on time.

Health permanently attributes every sample to the app that wrote it. Anything Hozz imported would be stamped as Hozz's data forever, so a heart rate your Watch recorded in 2019 and Hozz restored in 2027 would be indistinguishable from one Hozz invented. That destroys exactly the provenance an archive exists to preserve.

HealthKit also has no upsert. There is no way to say "store this sample unless it is already there", so importing the same export twice silently doubles it, and there is no reliable way afterwards to tell the copies apart or remove only one. A tool whose whole argument is that it never loses or duplicates a record cannot ship an operation that duplicates records by design.

And it could not be complete in any case: characteristics and clinical records cannot be written by an app at all, so even a perfect importer would restore some of your data and quietly skip the rest.

Exporting somewhere you own has none of these problems. That is the direction Hozz works in.

## Storage, privacy, and security

On the phone, Hozz stores cursors, coverage state, destination configuration, delivery receipts, and bounded spool artifacts. It does not keep a permanent local mirror of Health history by default. Health-derived files are protected with complete-unless-open file protection and excluded from device backups, including SQLite side files and spool files.

Destination credentials are kept in the device Keychain with `ThisDeviceOnly` accessibility and are not synchronised. The Mac receiver token is different: it is intentionally shared through the user's own iCloud Keychain access group so a phone and Mac signed into the same Apple ID can find each other without a manual token copy. If that entitlement or iCloud path is unavailable, the app falls back to pairing over the local network.

Logs and diagnostics must not include Health sample values, credentials, or secret destination details. Network errors record statuses and human-readable failure states, not response bodies that might echo data back.

## Build and test

Requirements:

- Xcode 27 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or newer (`brew install xcodegen`)

`Hozz.xcodeproj` is generated from `project.yml` and is not committed. Signing lives in gitignored `Local.xcconfig`, usually just:

```xcconfig
DEVELOPMENT_TEAM = YOURTEAMID
```

Both helper scripts create `Local.xcconfig` if it is missing. The app and widget targets declare `group.com.thatcube.Hozz`; your Apple developer profile must carry that App Group or device builds with the widget will fail. The widget reads the shared store and shows the last sync state, record count, and attention status. If it cannot reach the shared store, it says **Open Hozz for status** rather than inventing a state.

Build the Mac app:

```bash
tools/mac-build.sh
```

That regenerates the project, builds `HozzMac`, signs it, registers the Mac and refreshes profiles when needed, and launches the app unless an existing copy is already running. Use `HOZZ_MAC_RUN=1 tools/mac-build.sh` to replace a running copy, and `HOZZ_TEAM=XXXXXXXXXX` to override the signing team.

Build and install the iPhone app on a connected device:

```bash
tools/device-build.sh
```

Use `HOZZ_DEVICE=<udid>` to choose a device and `HOZZ_TEAM=XXXXXXXXXX` to override the signing team.

Simulator build and tests:

```bash
xcodegen generate
xcodebuild -project Hozz.xcodeproj -scheme Hozz \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project Hozz.xcodeproj -scheme Hozz \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The current XCTest suite contains 468 tests covering anchors, transaction boundaries, cancellation, retries, tombstones, deterministic encoding, characteristics, series streaming for routes and ECG, audiograms, State of Mind, medications, workout statistics, aggregate sample counts, fair-share acquisition, restricted exports, export formats, GPX track assembly, line protocol escaping, receiver ingestion, quarantine and promotion, backfill progress, MCP analysis, delivery, widgets/storage migration, and privacy invariants.

## Notes for anyone working on the Mac app

Two macOS behaviours cost a lot of time to diagnose. Both look like network faults and are not.

A sandboxed app needs `com.apple.security.network.client` to answer, not just `com.apple.security.network.server` to listen. A reply travels to the phone's ephemeral port, which the sandbox classifies as outbound. With only the server entitlement, the listener accepts a connection and is then silently forbidden from writing the response, so the request hangs and times out exactly as though the Mac were switched off. The kernel says so plainly:

```bash
log show --last 5m --predicate 'eventMessage CONTAINS "deny("' --info \
  | grep -i hozz
# Sandbox: Hozz(2625) deny(1) network-outbound remote:*:60607
```

macOS 15+ Local Network authorisation is keyed to the executable's UUID, and cannot be reset. It is not TCC, so `tccutil reset LocalNetwork` fails, and Apple documents that there is no way to return the state to undetermined. Every rebuild produces a new UUID, so a grant can go stale while System Settings still shows the app as allowed. Listening does not require this grant, but advertising over Bonjour does. While developing, exempt the subnet rather than fighting it:

```bash
sudo defaults write com.apple.network.local-network \
  AllowedWiFiLocalNetworkAddresses -array "192.168.0.0/16"
sudo reboot
```

Remove that before testing what a real user would experience.

One more trap: Bonjour resolution must ask for IPv4. Network.framework otherwise tends to hand back an IPv6 link-local `fe80::` address. That address only works with its interface scope, and the scope is lost when the address is saved as a string for a later `URLSession` request. The saved destination parses fine and connects to nothing forever.

## Support development

Hozz has no paid features. Donations are optional and support continued development of Hozz and Brandon's other free, open-source apps.

**[Donate via GitHub Sponsors](https://github.com/sponsors/thatcube)**

Other projects:

- [Plozz](https://github.com/thatcube/Plozz) — a native media player for Jellyfin, Plex, Emby, and network shares
- [Mozz](https://github.com/thatcube/Mozz) — music for Plex and Jellyfin
- [Twozz](https://github.com/thatcube/Twozz) — Twitch on Apple TV

## License

[GPL-3.0 with an App Store distribution exception](LICENSE) © 2026 Brandon Moore
