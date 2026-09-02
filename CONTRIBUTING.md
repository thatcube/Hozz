# Contributing to Hozz

Thanks for your interest in Hozz. This document covers building, testing, and the
deeper design and durability details that used to live in the README. For what
Hozz is and does as a user, see the [README](README.md). For the exact wire
format of every delivery, see [`docs/delivery-schema.md`](docs/delivery-schema.md);
for the MCP tools, see [`docs/mcp.md`](docs/mcp.md).

Hozz is an early-alpha project. Issues and pull requests are welcome, but
reviews and merges may take a while.

## Guiding principles

Almost everything that matters in Hozz follows from two rules:

- **Tell the truth about what happened.** If a read failed, a type is
  unavailable, or permission was refused, say so plainly rather than reporting
  success. Equally, don't manufacture alarm: a type with no records exported
  nothing, which is a complete and successful export, not a warning.
- **Do not lose records.** Acquisition uses opaque, type-scoped, device-local
  anchors, never date windows, and an anchor only advances after the records it
  covers are durably staged.

If something here makes the app worse, change it and say why in the commit.

## Reporting bugs & requesting features

Please open a [GitHub issue](https://github.com/thatcube/hozz/issues). Because
Hozz never sends Health values anywhere you didn't configure, bug reports won't
contain your data unless you add it — please don't paste Health sample values
into an issue.

## Build and test

Requirements:

- Xcode 27 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or newer
  (`brew install xcodegen`)

`Hozz.xcodeproj` is generated from `project.yml` and is not committed. Signing
lives in gitignored `Local.xcconfig`, usually just:

```xcconfig
DEVELOPMENT_TEAM = YOURTEAMID
```

Both helper scripts create `Local.xcconfig` if it is missing. The app and widget
targets declare `group.com.thatcube.Hozz`; your Apple developer profile must
carry that App Group or device builds with the widget will fail. The widget reads
the shared store and shows the last sync state, record count, and attention
status. If it cannot reach the shared store, it says **Open Hozz for status**
rather than inventing a state.

Build the Mac app:

```bash
tools/mac-build.sh
```

That regenerates the project, builds `HozzMac`, signs it, registers the Mac and
refreshes profiles when needed, and launches the app unless an existing copy is
already running. Use `HOZZ_MAC_RUN=1 tools/mac-build.sh` to replace a running
copy, and `HOZZ_TEAM=XXXXXXXXXX` to override the signing team.

Build and install the iPhone app on a connected device:

```bash
tools/device-build.sh
```

Use `HOZZ_DEVICE=<udid>` to choose a device and `HOZZ_TEAM=XXXXXXXXXX` to
override the signing team.

Simulator build and tests:

```bash
xcodegen generate
xcodebuild -project Hozz.xcodeproj -scheme Hozz \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project Hozz.xcodeproj -scheme Hozz \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The XCTest suite runs over a thousand tests covering anchors, transaction
boundaries, cancellation, retries, tombstones, deterministic encoding, the
export writer lease, characteristics, series streaming for routes and ECG,
audiograms, State of Mind, medications, workout statistics, clinical records,
aggregate sample counts, fair-share acquisition, the recent-first prime and its
separation from the anchors, restricted exports, export formats, GPX track
assembly, line protocol escaping, receiver ingestion, quarantine and promotion,
backfill progress, MCP analysis, delivery, unrecognised stored settings,
unfinished-export recovery, widgets/storage migration, and privacy invariants.

## Health data coverage

| Area | What Hozz keeps | Important limits |
| --- | --- | --- |
| Quantity and category samples | Values, units, dates, source, device, metadata, and deletion tombstones. | The app asks for the types it reads. If Health cannot distinguish denied from empty, Hozz says so. |
| Workouts | Activity type, duration, events, and Health's `allStatistics` aggregates, including per-leg figures for multi-sport workouts. | These are summaries of samples exported separately, not duplicate samples. |
| Workout routes | The route sample, confirmed workout relationship when Health can prove it, 500-point location pages, and an end marker with the final point count. | Hozz does not guess a workout from time overlap alone. Unresolved routes say why. |
| Electrocardiograms | Classification, raw classification value, symptoms status, average heart rate, sampling frequency, expected waveform count, and 500-reading voltage pages. | Missing voltage readings stay gaps, not zeros, and partial waveforms are never presented as whole. |
| Audiograms | One row per hearing threshold, with ear, frequency, sensitivity, clamping bounds, and where supported, conduction and masking. | An unmeasured ear is absent, not written as 0 dBHL. |
| State of Mind | Valence, Health's classification, momentary emotion versus daily mood, labels, associations, and raw enum values. | iOS 18+. Zero valence is neutral, not missing. |
| Medication doses | Dose status, schedule type, optional dose quantities, medication resolution state, form, nickname, archived/schedule flags, and codings. | iOS 26+. This is the dose-logging API, not the clinical `MedicationRecord`. Only `taken` means taken. |
| Health characteristics | Date of birth, biological sex, blood type, Fitzpatrick skin type, wheelchair use, and activity move mode, with a `known`/`notSet`/`unrecognised`/`unavailable`/`unreadable` state. | These are facts about the person, not samples; they have no UUID, source, dates, or anchor. |
| Quantity series | The aggregate sample is kept with its `count` and marked `aggregatesSeries` when it stands for more than one reading. | Hozz does not expand quantity series yet. |

## Health acquisition and durability

Hozz does not use date-window watermarks. Each HealthKit type has its own opaque,
device-local anchor, drained with `HKAnchoredObjectQuery`. An anchor advances
only after the records it covers have been durably staged.

For a manual export, records are written to an open spool part and anchors are
only committed when that part is sealed in the same store transaction. An
unsealed part is deleted on relaunch and replayed from the previous anchor. The
result is the property that matters: interruption can repeat work, but it cannot
skip records or publish a half-finished export as complete.

One thing writes an export's spool at a time, because two writers would pick the
same next part sequence and unlink each other's open file. An automatic sync
takes that same writer, and one starts whenever the app is opened, so pressing
**Export now** a moment later finds it busy. Hozz waits for it and says which
activity it is waiting for, rather than refusing with a message naming an export
that is not running.

An automatic sync pass gives every selected type a small share before spending
what is left on whatever still has the most to send, trims each HealthKit page to
the share, and rotates the order hourly. A type is recorded as caught up only
when Health returns an empty page; one the budget cut short stays `draining`, so
the store never claims a type is finished when it is not.

Automatic sync uses the same anchor rule per destination. Each destination has
its own cursor, so a failed destination cannot advance past data it did not
accept, and one broken destination does not block a healthy one. Batches use
stable content-derived identifiers and `Idempotency-Key` headers so a retry can
be accepted safely.

Apple does not let apps distinguish "the user denied this Health type" from
"there is no matching data." Hozz therefore reports authorization-scoped coverage
and keeps denied-or-empty, unavailable, unsupported, and failed states visible.

### The recent-first prime

An anchored sweep returns records in the order Health *stored* them, which is not
the order they happened. Two consequences follow: a phone part-way through a
large archive holds an arbitrary subset by date, and data recorded *this morning*
sits at the end of the queue behind the entire backlog.

So a second reader runs alongside it. `HKSampleQuery` over a bounded date window —
ninety days by default — feeds the same delivery path, walking a window in chunks
whose length adapts to how dense the type turns out to be. It keeps two cursors:
a frontier walking back towards the oldest instant aimed at, and a covered edge
walking forward towards now. Between them lies one contiguous stretch, every
second of which has been delivered and accepted.

It never touches an anchor — if it did, every record older than the primed
window would be skipped by the sweep permanently. The separation is structural:
the dated protocol has no anchor in it, the frontier lives in its own table, and
cursors move only inside the transaction that records the delivery, so an
interrupted prime repeats a chunk rather than skipping one. A prime never sees a
deletion (a dated query has no tombstone channel) and delivers a series sample's
aggregate without the readings inside it, so it marks those records accordingly;
series types are not primed at all. The result is data with a hole in the
middle — recent months, a gap, then however far the sweep has walked — carried as
the real state it is rather than dressed up as a continuous history.

### Route pages and gaps

Routes arrive as pages at fixed absolute offsets, so an interrupted sync leaves a
hole of a known size rather than a shorter list. Joining the two sides of a
missing page would draw a straight line across a mile of city and look correct,
so a gap becomes a separate `<trkseg>` on each side, the track's `<desc>` says
how many points are missing and where, and the archive's `README.md` lists every
affected file. Speed, course, and Core Location's accuracies have no element in
base GPX and are published under Hozz's own namespace in `<extensions>`.

### Workout sample linking is an approximation

**Hozz does not export which individual samples belonged to a workout.**
HealthKit will list the objects belonging to a workout, but offers nothing in the
other direction — a sample does not know its workout, and no workout identifier
appears in its metadata — so recording the link would mean a query per workout
per type, tens of thousands of them for a real history.

Matching by time range is therefore an approximation. It is good for most
workouts and wrong in two situations: workouts that overlap in time, and samples
recorded inside the window by something other than the workout (a phone counting
steps in a pocket during a ride, for instance). The workout's own statistics are
exact, because Health computed them; a time-range join is a reconstruction, not
Health's answer.

## A stored setting this build does not recognise

A destination is stored as JSON and read back with a decoder that tolerates
missing keys, because destinations are loaded with `try?` and a decoder that
threw would have emptied someone's list on upgrade without saying anything.
Missing keys were only half of it: `decodeIfPresent` returns nil for an absent
key but *throws* for a value the enum does not know, so a destination written by
a newer build — or by one whose vocabulary later changed — vanished just as
silently.

There were three ways to answer that, and two of them are worse than they look.
Failing closed is what already nearly happened: the destination disappears and
nothing is said. Falling back to a default is quieter still and worse, because
Hozz would then send Health data to a real endpoint in a shape, on a schedule, or
at a timestamp precision nobody chose, and report it as a success — and the first
re-save would write that default over the user's actual setting.

So Hozz keeps the record and refuses to use it. The unrecognised word is held
as-is and written back out untouched, so a build that cannot read a setting
cannot erode it either. The destination stays in the list, marked as needing
attention, saying which setting and which value it did not understand. Nothing is
delivered to it, not even when the user taps Sync now, and the connection test
refuses. Editing and saving is the escape hatch, and the editor says plainly that
saving is also the moment the original setting is replaced.

## Enabling clinical (health) records

Clinical records are FHIR resources from a connected provider: lab results,
conditions, clinical medications, immunisations, procedures, vital signs,
coverage records, allergies, and notes. They are **not** in the default build,
and the code that would read them is compiled out.

Reading them needs the `com.apple.developer.healthkit.access` entitlement with
`health-records` — the "Clinical Health Records" checkbox on the HealthKit
capability. There is no request form for it and no approval to wait for; App
Review judges whether an app has a reason to hold these records when the app is
submitted. The entitlement array in `project.yml` ships empty and the Swift flag
that enables the code is undefined by default, so shipping them stays a
deliberate decision.

Turning clinical records on takes two deliberate steps:

1. Build with `HOZZ_CLINICAL_FLAG=HOZZ_CLINICAL_RECORDS`, on the `xcodebuild`
   command line or in the gitignored `Local.xcconfig`. This changes no
   entitlement — the code compiles and reports honestly that the entitlement is
   missing.
2. Change `com.apple.developer.healthkit.access` in `project.yml` from `[]` to
   `[health-records]`. This is the step App Review sees, which is why it is a
   visible edit to a tracked file rather than a switch.

Both build configurations are tested, and a test asserts the flag actually
reaches the framework it gates. The build flag and the entitlement are separate
switches, so a build with one and not the other is a crash rather than a disabled
feature, and that gate is what makes the mismatch harmless. Clinical records are
read with `HKSampleQuery`, not the anchored drain, because HealthKit does not
support anchored queries for clinical types. There is no cursor: every record is
read every time, and the stable identity makes a re-read byte-identical to what a
receiver already holds.

Three things about the data itself:

- **Consent is per record.** Health asks which records to share, one by one, and
  Hozz cannot see what was withheld. Partial access is the normal case, not a
  failure.
- **The FHIR resource is carried through as the provider sent it**, not reshaped
  into Hozz's vocabulary. A resource Hozz cannot parse is kept as bytes rather
  than dropped.
- **A clinical record's identity is not its HealthKit UUID.** Apple says the UUID
  is not stable for these records; Hozz derives identity from source, resource
  type, and FHIR identifier, and keeps the UUID alongside, labelled, for tracing.

## The Mac receiver

The Mac app is a local receiver and browser for data the phone sends. It starts
an `NWListener` HTTP receiver, advertises `_hozz._tcp`, normally listens on port
**54330**, accepts `/pair` without a token, and requires the token for
deliveries. It stores accepted batches in `hozz-received.sqlite` with idempotent
batch records, deletions, characteristics, per-device "last heard from" state,
dedicated tables for ECGs, audiograms, State of Mind, medication doses, and
workout statistics, and a quarantine for records this parser cannot read yet.

Setup avoids typing an address: the phone browses Bonjour, reads receiver records
published through the user's own iCloud Keychain, then falls back to a private
`/24` local-network sweep on port 54330. Every remembered address is probed
before it is offered or reused, so a computer that does not answer is shown as
offline instead of saved as a dead destination. The Mac app also watches a folder
for automatic batch files, which works when the local network refuses inbound
connections.

## Storage, privacy, and security

On the phone, Hozz stores cursors, coverage state, destination configuration,
delivery receipts, and bounded spool artifacts. It does not keep a permanent
local mirror of Health history by default. Health-derived files are protected
with complete-unless-open file protection and excluded from device backups,
including SQLite side files and spool files.

Destination secrets are kept in the device Keychain with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and are not synchronised:
`ThisDeviceOnly` keeps the secret off every other device, and `AfterFirstUnlock`
lets a background sync read it while the phone is locked. Non-secret settings (an
MQTT username, say) are stored with the rest of a destination's configuration,
not in the Keychain.

The Mac receiver token is different: `kSecAttrSynchronizable` carries it through
the user's own iCloud Keychain so a phone and Mac on the same Apple ID pair
without copying a token by hand, while a shared access group is what stops other
applications reading it. If the entitlement or the iCloud path is unavailable,
the app falls back to pairing over the local network.

Logs and diagnostics must not include Health sample values, credentials, or
secret destination details. Network errors record statuses and human-readable
failure states, not response bodies that might echo data back.

## MCP assistant access

The Mac app embeds a read-only MCP server at
`Hozz.app/Contents/MacOS/hozz-mcp`. It speaks JSON-RPC 2.0 over stdio, advertises
protocol version `2024-11-05`, server name `hozz`, and version `1.0.0`. Its tools
cover overview and type listing, aggregate buckets, individual samples, ECG
waveform access, audiograms, mood entries, medication adherence, workouts, trend
analysis, type comparison, and anomaly checks, and are documented in
[`docs/mcp.md`](docs/mcp.md).

The tool must be given the Mac app's received-data directory, and the Mac app is
sandboxed while the assistant launches `hozz-mcp` outside that sandbox — so a
guessed path opens an empty directory and every tool truthfully reports no data.
Open the Mac app's **Assistant** tab and copy the configuration it generates. The
server can only read; it has no code path that writes. If you connect it to a
cloud-hosted assistant, that assistant may upload whatever it reads. That is the
assistant's behaviour, not Hozz's.

## Notes for anyone working on the Mac app

Two macOS behaviours cost a lot of time to diagnose. Both look like network
faults and are not.

A sandboxed app needs `com.apple.security.network.client` to answer, not just
`com.apple.security.network.server` to listen. A reply travels to the phone's
ephemeral port, which the sandbox classifies as outbound. With only the server
entitlement, the listener accepts a connection and is then silently forbidden
from writing the response, so the request hangs and times out exactly as though
the Mac were switched off. The kernel says so plainly:

```bash
log show --last 5m --predicate 'eventMessage CONTAINS "deny("' --info \
  | grep -i hozz
# Sandbox: Hozz(2625) deny(1) network-outbound remote:*:60607
```

macOS 15+ Local Network authorisation is keyed to the executable's UUID, and
cannot be reset. It is not TCC, so `tccutil reset LocalNetwork` fails, and Apple
documents that there is no way to return the state to undetermined. Every rebuild
produces a new UUID, so a grant can go stale while System Settings still shows
the app as allowed. Listening does not require this grant, but advertising over
Bonjour does. While developing, exempt the subnet rather than fighting it:

```bash
sudo defaults write com.apple.network.local-network \
  AllowedWiFiLocalNetworkAddresses -array "192.168.0.0/16"
sudo reboot
```

Remove that before testing what a real user would experience.

One more trap: Bonjour resolution must ask for IPv4. Network.framework otherwise
tends to hand back an IPv6 link-local `fe80::` address. That address only works
with its interface scope, and the scope is lost when the address is saved as a
string for a later `URLSession` request. The saved destination parses fine and
connects to nothing forever.

## The standalone Python receiver

A small dependency-free Python receiver lives in [`receiver/`](receiver/) for
people who want a script instead of the Mac app. It accepts Hozz batches over
HTTP or watches a folder, and keeps a SQLite database you can query with
anything. See [`receiver/README.md`](receiver/README.md).
