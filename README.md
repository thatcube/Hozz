# Hozz

**Export Apple Health data to destinations you own.**

Hozz is a free, open-source iPhone app with a companion Mac receiver. The iPhone app reads the Health data Apple lets an app read, exports it on demand, and can keep user-configured destinations up to date in the background. The Mac app receives those deliveries, stores them in a local SQLite database, charts them, and can expose them to an MCP-capable assistant running against that local database.

There is no subscription, account, analytics, advertising, hosted relay, or default network destination. Nothing leaves the iPhone until you add a destination and confirm it.

Hozz is still early alpha. It currently exports quantity samples, category samples, workout records, workout routes, electrocardiograms, audiograms, State of Mind entries, historical deletions, and the six Health characteristics. Correlations, other series, documents, scored assessments, and clinical records are catalogued or acknowledged where relevant, but not claimed as exported coverage.

## What works today

The iPhone app has two paths: **Automatic** and **Export**.

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
| Raw NDJSON | `.ndjson` | Supported by the export engine for direct piping; the main picker exposes NDJSON, CSV, JSON, SQLite, and Markdown. |

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

## Health acquisition and durability

Hozz does not use date-window watermarks. Each HealthKit type has its own opaque, device-local anchor, drained with `HKAnchoredObjectQuery`. An anchor advances only after the records it covers have been durably staged.

For a manual export, records are written to an open spool part and anchors are only committed when that part is sealed in the same store transaction. An unsealed part is deleted on relaunch and replayed from the previous anchor. The result is the property that matters: interruption can repeat work, but it cannot skip records or publish a half-finished export as complete.

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

## Mac receiver

The Mac app is a local receiver and browser for data the phone sends. It starts an `NWListener` HTTP receiver, advertises `_hozz._tcp`, normally listens on port **54330**, accepts `/pair` without a token, and requires the token for deliveries. It stores accepted batches in `hozz-received.sqlite` with schema version 3, idempotent batch records, deletions, characteristics, and per-device “last heard from” state.

Setup is designed to avoid typing an address. The phone first browses Bonjour, also reads receiver records published through the user's own iCloud Keychain, then falls back to a private `/24` local-network sweep on port 54330. Every remembered address is probed before it is offered or reused, so a computer that does not answer is shown as offline instead of saved as a dead destination.

The Mac app also watches a folder for automatic batch files. Point the phone at a synced folder, pick the same folder on the Mac, and the Mac ingests new NDJSON, JSON, CSV, or Metrics JSON files as they arrive. This path works when the local network refuses inbound connections.

The Mac UI has four tabs:

- **Connect** shows the receiver, folder watcher, token, and honest per-device status based on when data last arrived.
- **Data** lists received Health types, charts numeric values by hour/day/week/month, and exports a type as CSV.
- **Assistant** shows the MCP configuration to copy into an assistant.
- **Activity** lists recent accepted, duplicate, paired, test, and rejected deliveries without logging sample values.

A small standalone Python receiver remains in `receiver/` for people who want a dependency-free script instead of the Mac app.

## MCP assistant access

The Mac app embeds a read-only MCP server at:

```text
Hozz.app/Contents/MacOS/hozz-mcp
```

It speaks JSON-RPC 2.0 over stdio, advertises protocol version `2024-11-05`, server name `hozz`, version `1.0.0`, and exposes four tools:

- `list_health_types`
- `summarise_health_data`
- `aggregate_health_data`
- `list_health_samples`

`summarise_health_data` also returns the person's own characteristics — age,
biological sex, blood type — where they have been shared. That is deliberately
part of the overview rather than a tool of its own: an assistant that is not
required to ask who "me" is will answer "is this normal for me" without ever
having found out, and reference ranges depend on exactly those facts. A date of
birth is reported with the age it implies, because age is what the ranges are
keyed to.

The tool must be given the Mac app's received-data directory. The Mac app is sandboxed, while the assistant launches `hozz-mcp` outside that sandbox; if the path is guessed, the tool opens an empty directory. Open the Mac app's **Assistant** tab and copy the generated configuration. It has this shape:

```json
{
  "mcpServers": {
    "hozz": {
      "command": "/Applications/Hozz.app/Contents/MacOS/hozz-mcp",
      "args": [
        "--data-dir",
        "/Users/you/Library/Containers/com.thatcube.Hozz.mac/Data/Library/Application Support/Hozz/Received"
      ]
    }
  }
}
```

The same path can be passed as `HOZZ_DATA_DIR` instead of `--data-dir`. The server can only read the received database; it cannot change or delete data. If you connect it to a cloud-hosted assistant, that assistant may upload whatever it reads. That is the assistant's behaviour, not Hozz's.

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

The current XCTest suite contains COUNT_PLACEHOLDER tests covering anchors, transaction boundaries, cancellation, retries, tombstones, deterministic encoding, characteristics, series streaming for routes and ECG, audiograms, State of Mind, aggregate sample counts, export formats, line protocol escaping, receiver ingestion and quarantine, delivery, MCP, widgets/storage migration, and privacy invariants.

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
