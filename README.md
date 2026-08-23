# Hozz

**Export Apple Health data to destinations you own.**

Hozz is a free, open-source iPhone app with a companion Mac receiver. The phone reads the Health data Apple lets an app read, exports it on demand, and can keep user-configured destinations up to date in the background. The Mac app receives those deliveries, stores them in a local SQLite database, charts them, and can expose them to an MCP-capable assistant running against that local database.

There is no subscription, account, analytics, advertising, hosted relay, or default network destination. Nothing leaves the iPhone until you add a destination and confirm it.

Hozz is still early alpha. It currently exports quantity samples, category samples, workout records and Health's workout statistics, paged workout routes, electrocardiograms with voltage waveforms, audiograms, State of Mind entries, medication dose events, historical deletions, and the six Health characteristics. Correlations, documents, scored assessments, and most other series are catalogued or reported as unsupported, not silently claimed as exported coverage. Clinical-record code exists, but it is off in the default build; see [Health records](#health-records-clinical-records).

## What works today

The iPhone app has two paths: **Automatic** and **Export**.

A first automatic sync works through your history a bounded batch at a time, giving every selected type a share of each pass rather than draining one to exhaustion before starting the next. That ordering matters more than it sounds: taking types strictly in turn meant a phone with years of stand hours could send nothing else for days, which is a working sync that reads exactly like a broken one. The phone says how many selected health types are complete, and the Mac says how many types have arrived and how far back they reach. Neither shows a percentage or an estimated time: Health will not say how many records a type holds without reading all of them, so any fraction would be invented.

Automatic export sends new Health records to destinations you configure. Destinations can be limited to selected Health types, turned off, set to run when data arrives, hourly, daily, or only manually, and tested before you trust them. The dashboard shows the last successful delivery, retry or attention states, and a one-tap **Sync now** action. Shortcuts expose **Sync Health Data** and **Check Health Sync Status**.

Supported automatic destinations and compatibility modes are:

| Destination or mode | What Hozz sends |
| --- | --- |
| This Mac | NDJSON batches to the Hozz Mac receiver over the local network, with token authentication. |
| Folder | Batch files written through the Files picker to iCloud Drive, Dropbox, OneDrive, Google Drive, SMB, or on-device storage. |
| Home Assistant | Metrics JSON to a webhook or REST endpoint. |
| InfluxDB | Line protocol written straight to `/api/v2/write` or 1.8's `/write`, with a configurable measurement and timestamp precision. |
| Web address | NDJSON, JSON, CSV, Metrics JSON, or InfluxDB line protocol POSTs to an endpoint you run. |
| MQTT | MQTT 3.1.1 publishes to `mqtt://` or `mqtts://`, using retained QoS 0 topics. |
| Health Auto Export compatibility | An opt-in field-name mode for Home Assistant, web, and MQTT Metrics JSON deliveries. Hozz's own schema remains the default. |

Background delivery is requested with `HKObserverQuery` and `enableBackgroundDelivery`, then coalesced into bounded sync passes. iOS still decides when background work runs, most Health types are capped at hourly delivery, Health cannot be read while the phone is locked, and force-quitting Hozz stops launches until the app is opened again. Hozz reports those states rather than calling them success.

Manual export creates a full historical export you can save or share from the phone. It is resumable: pausing, backgrounding, expiration, a kill, or a reboot resumes from the last durable checkpoint instead of starting over.

An unfinished export that this build cannot continue — one written by a later version whose stored words it does not recognise — is still shown, with the reason, and can be discarded. Hiding it would leave someone's export simply gone; offering to continue it would promise something that fails on the tap.

## Formats

Manual exports are built from a canonical NDJSON spool. That spool is the durable format because it streams, survives interruption, and can be assembled without recompressing. Presentation formats are produced from it at the end.

| Format | Output | Notes |
| --- | --- | --- |
| NDJSON | `.zip` containing one `.ndjson` member | Default. One record per line, streamable, and lossless for the fields Hozz currently encodes. |
| CSV | `.zip` with one CSV per Health type, plus deletion and export-log files when needed | Opens in spreadsheets. Explicitly lossy: metadata and nested workout details do not fit a grid. |
| JSON | `.zip` containing one JSON array | Lossless and convenient for smaller exports and tools that expect a single JSON value. |
| SQLite | `.sqlite` database | Query it in Datasette, DuckDB, pandas, Grafana, or `sqlite3` with no import step. Not lossy: every row keeps its original record in `raw`. |
| Markdown | `.zip` of one `YYYY-MM-DD.md` note per day | For Obsidian and journals, with YAML front matter Dataview can query. Explicitly lossy: a note keeps a day's totals, never the records behind them. |
| GPX | `.zip` of one GPX 1.1 track per workout with GPS | For maps and fitness tools. This is a filter, not a projection: a GPX run drains only workouts and workout routes. |
| Raw NDJSON | `.ndjson` | Supported by the export engine for direct piping; the main picker exposes NDJSON, CSV, JSON, SQLite, Markdown, and GPX. |

The SQLite file is built for asking questions rather than for mirroring the JSON. Everything time-shaped except workouts goes into one wide `sample` table with a `type` column, because the queries worth having — compare two types over the same period, show everything that happened last Tuesday — are cross-type, and a table per type turns them into a hundred-way union. Workouts, deletions, and characteristics have genuinely different shapes and get their own tables, a `record` view puts the time-shaped ones back on one timeline, and a `daily` view covers the aggregate most questions start from.

Because every row also stores the untouched export line in `raw`, anything the columns leave out is still reachable with `json_extract`, which is why SQLite is offered without the lossy label CSV carries. `meta` records when the export ran, what it covered, and which time zone the `local_day` columns were bucketed in — a UTC day would file an evening workout under the following morning.

The Markdown export is the opposite trade, made deliberately. Each note carries YAML front matter for Dataview — steps, sleep hours, workout minutes, resting heart rate — then the day in prose and small tables. It keeps a day's counts, totals and extremes and throws the records themselves away, along with metadata, sources, devices and sample identifiers, so the picker, a `README.md` in the archive, and the foot of every single note all say so and point at the formats that keep everything. Days are local days, and sleep is filed under the day it ended, because last night's sleep belongs to the morning you woke up.

Automatic destinations use `DeliveryFormat`: NDJSON, JSON, CSV, Metrics JSON, or InfluxDB line protocol. Metrics JSON groups points by metric name for Home Assistant, MQTT, and dashboards; deletions are carried alongside instead of silently dropped. Neither SQLite nor Markdown is offered there: a delivery is an append of new records to an endpoint or a folder, a database file is not appendable over HTTP, and a day's note rewritten from one batch would replace a full day with a fraction of it.

**[`docs/delivery-schema.md`](docs/delivery-schema.md) documents every delivery format field by field**, with a worked example payload for each, the escaping rules, and the delivery headers — so something can be built against Hozz without reading the source.

Line protocol exists because the alternative was making people run a translator. The usual self-hosted setup is Health data in InfluxDB charted in Grafana, and reaching it meant deploying a container whose entire job was turning an exporter's JSON into the format InfluxDB already wanted. It is deliberately not offered for folder destinations: the Mac app watches a folder for NDJSON, JSON, and CSV, so a folder writing line protocol would look like it was working while nothing was ingested.

The Home Assistant, MQTT, and web address destinations also have an **opt-in** compatibility mode that emits Health Auto Export's published field names, for people arriving with automations and scripts already keyed to them. It matches what that format documents and says plainly what it does not: Hozz sends individual samples rather than rollups, so a heart rate point carries the same number in `Min`, `Avg`, and `Max`, and blood pressure stays split rather than guessing which two samples pair. Hozz's own schema remains the default and the recommended one.

GPX is the odd one out, and the interface says so before it is chosen. Every other format takes everything in the export and keeps less of each record; GPX takes almost nothing in the export and keeps all of what it takes. A GPX file is a track, with nowhere to put a heart rate or a body weight, so a workout recorded without GPS produces no file — a treadmill run has no route, and that is not an error. Because a GPX run drains only workouts and workout routes, it avoids spending hours reading types that could not appear in the output and cannot advance a cursor a full export or automatic destination depends on.

Routes arrive as pages at fixed absolute offsets, so an interrupted sync leaves a hole of a known size rather than a shorter list. Joining the two sides of a missing page would draw a straight line across a mile of city and look correct, so a gap becomes a separate `<trkseg>` on each side, the track's `<desc>` says how many points are missing and where, and the archive's `README.md` lists every affected file. Speed, course, and Core Location's accuracies have no element in base GPX and are published under Hozz's own namespace in `<extensions>`.

## Health acquisition and durability

Hozz does not use date-window watermarks. Each HealthKit type has its own opaque, device-local anchor, drained with `HKAnchoredObjectQuery`. An anchor advances only after the records it covers have been durably staged.

For a manual export, records are written to an open spool part and anchors are only committed when that part is sealed in the same store transaction. An unsealed part is deleted on relaunch and replayed from the previous anchor. The result is the property that matters: interruption can repeat work, but it cannot skip records or publish a half-finished export as complete.

One thing writes an export's spool at a time, because two writers would pick the same next part sequence and unlink each other's open file. An automatic sync takes that same writer, and one starts whenever the app is opened, so pressing **Export now** a moment later finds it busy. Hozz waits for it and says which activity it is waiting for, rather than refusing with a message naming an export that is not running.

An automatic sync pass gives every selected type a small share before spending what is left on whatever still has the most to send, trims each HealthKit page to the share, and rotates the order hourly. A type is recorded as caught up only when Health returns an empty page; one the budget cut short stays `draining`, so the store never claims a type is finished when it is not.

Automatic sync uses the same anchor rule per destination. Each destination has its own cursor, so a failed destination cannot advance past data it did not accept, and one broken destination does not block a healthy one. Batches use stable content-derived identifiers and `Idempotency-Key` headers so a retry can be accepted safely.

Apple does not let apps distinguish “the user denied this Health type” from “there is no matching data.” Hozz therefore reports authorization-scoped coverage and keeps denied-or-empty, unavailable, unsupported, and failed states visible.

## Health data coverage

| Area | What Hozz keeps | Important limits |
| --- | --- | --- |
| Quantity and category samples | Values, units, dates, source, device, metadata, and deletion tombstones. | The app asks for the types it reads. If Health cannot distinguish denied from empty, Hozz says so. |
| Workouts | Activity type, duration, events, and Health's `allStatistics` aggregates, including per-leg figures for multi-sport workouts. | These are summaries of samples exported separately, not duplicate samples. |
| Workout routes | The route sample, confirmed workout relationship when Health can prove it, 500-point location pages, and an end marker with the final point count. | Hozz does not guess a workout from time overlap alone. Unresolved routes say why. |
| Electrocardiograms | Classification, raw classification value, symptoms status, average heart rate, sampling frequency, expected waveform count, and 500-reading voltage pages. | Missing voltage readings stay gaps, not zeros, and partial waveforms are never presented as whole. |
| Audiograms | One row per hearing threshold, with ear, frequency, sensitivity, clamping bounds, and where supported, conduction and masking. | An unmeasured ear is absent, not written as 0 dBHL. |
| State of Mind | Valence, Health's classification, momentary emotion versus daily mood, labels, associations, and raw enum values. | iOS 18+. Zero valence is neutral, not missing. Empty label lists mean none were chosen. |
| Medication doses | Dose status, schedule type, optional dose quantities, medication resolution state, form, nickname, archived/schedule flags, and codings. | iOS 26+. This is the dose-logging API, not the clinical `MedicationRecord`, and it needs no special entitlement. Only `taken` means taken. |
| Health characteristics | Date of birth, biological sex, blood type, Fitzpatrick skin type, wheelchair use, and activity move mode, with `known`, `notSet`, `unrecognised`, `unavailable`, or `unreadable` state. | These are facts about the person, not samples; they have no UUID, source, dates, or anchor. |
| Quantity series | The aggregate sample is kept with its `count` and marked `aggregatesSeries` when it stands for more than one reading. | Hozz does not expand quantity series yet. |

**Hozz does not export which individual samples belonged to a workout.** HealthKit will list the objects belonging to a workout, but offers nothing in the other direction — a sample does not know its workout, and no workout identifier appears in its metadata — so recording the link would mean a query per workout per type, tens of thousands of them for a real history.

Matching by time range is therefore an approximation, and worth knowing you are making one. It is a good approximation for most workouts and wrong in two situations: workouts that overlap in time, and samples recorded inside the window by something other than the workout — a phone counting steps in a pocket during a ride, for instance. The workout's own statistics above are exact, because Health computed them; a time-range join is your reconstruction, not Health's answer.

## Health records (clinical records)

Clinical records are FHIR resources from a connected provider: lab results, conditions, clinical medications, immunisations, procedures, vital signs, coverage records, allergies, and notes.

These are not in the default build, and the code that would read them is compiled out. Reading them needs the `com.apple.developer.healthkit.access` entitlement with `health-records` — the "Clinical Health Records" checkbox on the HealthKit capability. There is no request form for it and no approval to wait for; App Review judges whether an app has a reason to hold these records when the app is submitted. The entitlement array in `project.yml` ships empty and the Swift flag that enables the code is undefined by default, so shipping them stays a deliberate decision rather than a default.

Turning clinical records on takes two deliberate steps:

1. Build with `HOZZ_CLINICAL_FLAG=HOZZ_CLINICAL_RECORDS`, on the `xcodebuild` command line or in the gitignored `Local.xcconfig`. This changes no entitlement — the code compiles and reports honestly that the entitlement is missing.
2. Change `com.apple.developer.healthkit.access` in `project.yml` from `[]` to `[health-records]`. This is the step App Review sees, which is why it is a visible edit to a tracked file rather than a switch.

Both build configurations are tested, and a test asserts the flag actually reaches the framework it gates — it was once set on the app target alone, where it compiled nothing differently, so every run claiming to cover both configurations was the same build twice.

Nothing asks HealthKit about a clinical type unless `supportsHealthRecords()` says it may. Without the entitlement, asking does not fail — it raises, and the app is gone before it can report anything. The build flag and the entitlement are separate switches, so a build with one and not the other is a crash rather than a disabled feature, and that gate is what makes the mismatch harmless.

Clinical records are read with `HKSampleQuery`, not the anchored drain. HealthKit does not support anchored queries for clinical types, so they are kept out of the drained list structurally rather than skipped inside it: a clinical type reaching that list is a query that cannot run, not a slow path.

There is no cursor. A date window is the obvious substitute and is the one thing Hozz's design exists to avoid — Health accepts backdated records, and a provider import arrives in bulk carrying results dated months earlier, which a cursor set to "now" would skip silently. So every record is read every time, and the stable identity does the work: re-reading produces byte-identical records a receiver already holds. That is only sound because the volume is small, and if it stops being small the answer is still not a date cursor. When it is off — which is every default build today — the app says health records are **not available in this build**, and says explicitly that this is not a statement about whether you have any.

Three things about the data itself:

- **Consent is per record.** Health asks which records to share, one by one, and Hozz cannot see what was withheld. Partial access is the normal case, not a failure, so nothing treats a small result as an error.
- **The FHIR resource is carried through as the provider sent it**, not reshaped into Hozz's vocabulary. A result's units, reference ranges, and coding systems *are* the clinical meaning. A resource Hozz cannot parse is kept as bytes rather than dropped.
- **A clinical record's identity is not its HealthKit UUID.** Apple says the UUID is not stable for these records and that source, resource type, and FHIR identifier should be used instead. Hozz derives the identity from those stable fields and keeps the UUID alongside, labelled, for tracing.

## Mac receiver

The Mac app is a local receiver and browser for data the phone sends. It starts an `NWListener` HTTP receiver, advertises `_hozz._tcp`, normally listens on port **54330**, accepts `/pair` without a token, and requires the token for deliveries. It stores accepted batches in `hozz-received.sqlite` with schema version 7, idempotent batch records, deletions, characteristics, per-device “last heard from” state, dedicated tables for ECGs, audiograms, State of Mind, medication doses, workout statistics, and a quarantine for records this parser cannot read yet.

Setup is designed to avoid typing an address. The phone first browses Bonjour, also reads receiver records published through the user's own iCloud Keychain, then falls back to a private `/24` local-network sweep on port 54330. Every remembered address is probed before it is offered or reused, so a computer that does not answer is shown as offline instead of saved as a dead destination.

The Mac app also watches a folder for automatic batch files. Point the phone at a synced folder, pick the same folder on the Mac, and the Mac ingests new NDJSON, JSON, CSV, or Metrics JSON files as they arrive. This path works when the local network refuses inbound connections.

The Mac UI has four tabs:

- **Connect** shows the receiver, folder watcher, token, and honest per-device status based on when data last arrived.
- **Data** lists what has arrived and how far back it reaches, shows the person's own characteristics above the measurements, charts numeric values by hour/day/week/month, exports a type as CSV, and names anything received in a form this version cannot read yet. When a newer parser can read quarantined records, a promotion pass adds them and the UI says so.
- **Assistant** shows the MCP configuration to copy into an assistant.
- **Activity** lists recent accepted, duplicate, paired, test, and rejected deliveries without logging sample values.

A small standalone Python receiver remains in `receiver/` for people who want a dependency-free script instead of the Mac app.

## MCP assistant access

The Mac app embeds a read-only MCP server at:

```text
Hozz.app/Contents/MacOS/hozz-mcp
```

It speaks JSON-RPC 2.0 over stdio, advertises protocol version `2024-11-05`, server name `hozz`, and version `1.0.0`. Its tools are documented in **[docs/mcp.md](docs/mcp.md)**; today they cover overview and type listing, aggregate buckets, individual samples, ECG waveform access, audiograms, mood entries, medication adherence, workouts, trend analysis, type comparison, and anomaly checks.

Most Apple Health MCP servers read the bulk XML export, which is a snapshot: correct the day you make it and stale the next morning. Hozz queries a local database the phone keeps current in the background, so a question costs an indexed lookup rather than a re-parse of hundreds of megabytes.

The analysis tools are built to be hard to overstate, because their output goes straight to a language model that will narrate a story around any number. A trend reports "no detectable change" when a flat line fits as well as a sloped one, and refuses below two weeks of days. A correlation puts its interval on an autocorrelation-adjusted sample size, since consecutive days are not independent evidence, and warns when both series are trending. Anomalies use the median and median absolute deviation, and a day with too few records is reported as *the device was not worn* rather than as a low reading. **[docs/mcp.md](docs/mcp.md)** sets out exactly what each tool will and will not claim, and carries the client configuration to copy.

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

### A stored setting this build does not recognise

A destination is stored as JSON and read back with a decoder that tolerates missing keys, because destinations are loaded with `try?` and a decoder that threw would have emptied someone's list on upgrade without saying anything. Missing keys were only half of it: `decodeIfPresent` returns nil for an absent key but *throws* for a value the enum does not know, so a destination written by a newer build — or by one whose vocabulary later changed — vanished just as silently.

There were three ways to answer that, and two of them are worse than they look. Failing closed is what already nearly happened: the destination disappears and nothing is said. Falling back to a default is quieter still and worse, because Hozz would then send Health data to a real endpoint in a shape, on a schedule, or at a timestamp precision nobody chose, and report it as a success — and the first re-save would write that default over the user's actual setting, so the update that could have understood it would arrive too late.

So Hozz keeps the record and refuses to use it. The unrecognised word is held as-is and written back out untouched, so a build that cannot read a setting cannot erode it either. The destination stays in the list, marked as needing attention, saying which setting and which value it did not understand. Nothing is delivered to it, not even when the user taps Sync now, and the connection test refuses rather than reporting a destination Hozz cannot use as working. Editing and saving is the escape hatch, and the editor says plainly that saving is also the moment the original setting is replaced.

The tests for this are built from hand-written stored payloads rather than by encoding today's types, because a round trip can only ever contain values this build already understands — which is exactly the case that was never in doubt.

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

The current XCTest suite contains 520 tests covering anchors, transaction boundaries, cancellation, retries, tombstones, deterministic encoding, the export writer lease, characteristics, series streaming for routes and ECG, audiograms, State of Mind, medications, workout statistics, clinical records, aggregate sample counts, fair-share acquisition, restricted exports, export formats, GPX track assembly, line protocol escaping, receiver ingestion, quarantine and promotion, backfill progress, MCP analysis, delivery, unrecognised stored settings, unfinished-export recovery, widgets/storage migration, and privacy invariants.

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
