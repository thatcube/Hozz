# Hozz

**Export Apple Health data to destinations you own.**

Hozz is a free, open-source iPhone app with a companion Mac receiver. The iPhone app reads the Health data Apple lets an app read, exports it on demand, and can keep user-configured destinations up to date in the background. The Mac app receives those deliveries, stores them in a local SQLite database, charts them, and can expose them to an MCP-capable assistant running against that local database.

There is no subscription, account, analytics, advertising, hosted relay, or default network destination. Nothing leaves the iPhone until you add a destination and confirm it.

Hozz is still early alpha. It currently exports quantity samples, category samples, workout records, and historical deletions. Correlations, routes, ECG, audiograms, series, characteristics, documents, scored assessments, and clinical records are catalogued or acknowledged where relevant, but not claimed as exported coverage.

## What works today

The iPhone app has two paths: **Automatic** and **Export**.

Automatic export sends new Health records to destinations you configure. Destinations can be limited to selected Health types, turned off, set to run when data arrives, hourly, daily, or only manually, and tested before you trust them. The dashboard shows the last successful delivery, retry or attention states, and a one-tap **Sync now** action. Shortcuts expose **Sync Health Data** and **Check Health Sync Status**.

Supported automatic destinations are:

| Destination | What Hozz sends |
| --- | --- |
| This Mac | NDJSON batches to the Hozz Mac receiver over the local network, with token authentication. |
| Folder | Batch files written through the Files picker to iCloud Drive, Dropbox, OneDrive, Google Drive, SMB, or on-device storage. |
| Home Assistant | Metrics JSON to a webhook or REST endpoint. |
| Web address | NDJSON, JSON, CSV, or Metrics JSON POSTs to an endpoint you run. |
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
| Raw NDJSON | `.ndjson` | Supported by the export engine for direct piping; the main picker currently exposes NDJSON, CSV, and JSON. |

Automatic destinations use `DeliveryFormat`: NDJSON, JSON, CSV, or Metrics JSON. Metrics JSON groups points by metric name for Home Assistant, MQTT, and dashboards; deletions are carried alongside instead of silently dropped.

## Health acquisition and durability

Hozz does not use date-window watermarks. Each HealthKit type has its own opaque, device-local anchor, drained with `HKAnchoredObjectQuery`. An anchor advances only after the records it covers have been durably staged.

For a manual export, records are written to an open spool part and anchors are only committed when that part is sealed in the same store transaction. An unsealed part is deleted on relaunch and replayed from the previous anchor. The result is the property that matters: interruption can repeat work, but it cannot skip records or publish a half-finished export as complete.

Automatic sync uses the same anchor rule per destination. Each destination has its own cursor, so a failed destination cannot advance past data it did not accept, and one broken destination does not block a healthy one. Batches use stable content-derived identifiers and `Idempotency-Key` headers so a retry can be accepted safely.

Apple does not let apps distinguish “the user denied this Health type” from “there is no matching data.” Hozz therefore reports authorization-scoped coverage and keeps denied-or-empty, unavailable, unsupported, and failed states visible.

## Mac receiver

The Mac app is a local receiver and browser for data the phone sends. It starts an `NWListener` HTTP receiver, advertises `_hozz._tcp`, normally listens on port **54330**, accepts `/pair` without a token, and requires the token for deliveries. It stores accepted batches in `hozz-received.sqlite` with schema version 2, idempotent batch records, deletions, and per-device “last heard from” state.

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

The current XCTest suite contains 178 tests covering anchors, transaction boundaries, cancellation, retries, tombstones, deterministic encoding, receiver ingestion, delivery, MCP, widgets/storage migration, and privacy invariants.

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
