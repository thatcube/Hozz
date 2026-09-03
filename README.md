<p align="center">
  <img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/hozz.svg" alt="Hozz logo" width="128" />
</p>

<h1 align="center">Hozz</h1>

<p align="center">
  Move your health data to the places you use — your Mac, files, home systems, and more. No accounts, no analytics, no server in the middle.
</p>

<p align="center">
  <a href="https://hozz.brando.page"><b>hozz.brando.page</b></a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue.svg" alt="License: GPL-3.0" /></a>
  <img src="https://img.shields.io/badge/Platform-iOS%2017%20%2B%20macOS%2014-black.svg?logo=apple" alt="Platform: iOS 17 + macOS 14" />
  <a href="https://github.com/sponsors/thatcube"><img src="https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white" alt="Sponsor" /></a>
</p>

Hozz is an open-source health data tool. Today, its **iPhone** app reads Apple
Health and sends a copy — on demand or automatically — to places **you**
control: your **Mac**, a folder, Home Assistant, InfluxDB, MQTT, or any endpoint
you run. The Mac app stores and charts those deliveries and can answer questions
about them through an AI assistant.

There is no account, analytics, advertising, or hosted relay.
**Nothing leaves your iPhone until you add a destination and confirm it** — Hozz
ships with no default destination and never picks one for you.

> **Early alpha.** Hozz is honest about what it does and doesn't do yet. Where a
> Health data type isn't supported, it says so plainly rather than quietly
> pretending it was exported. See
> [What Hozz keeps, and its limits](#what-hozz-keeps-and-its-limits) below.

## Features

### On your iPhone

- **Automatic background sync.** Turn it on and Hozz keeps your destinations up
  to date as new Health data arrives — when data comes in, hourly, daily, or
  only when you ask.
- **Fair first sync.** The first sync works through your history a bit of every
  selected type at a time, so a phone with years of stand hours doesn't sit on
  everything else for days.
- **One-tap manual export.** Build a full historical export you can save or
  share from the phone. It's resumable: a pause, a reboot, or a force-quit picks
  up from the last checkpoint instead of starting over.
- **Honest progress.** The phone tells you how many selected types are complete
  and the Mac tells you how far back the data reaches — never a fake percentage,
  because Health won't say how many records a type holds without reading them
  all.
- **Shortcuts & Siri.** *Sync Health Data* and *Check Health Sync Status* are
  exposed as Shortcuts actions.

### Where it can send

- **Your Mac.** The companion Hozz Mac app receives deliveries over your local
  network, with token authentication and automatic discovery — no typing an IP
  address.
- **A folder.** Write batch files through the Files picker into iCloud Drive,
  Dropbox, OneDrive, Google Drive, an SMB share, or on-device storage.
- **Home Assistant.** Post metrics to a webhook or REST endpoint.
- **InfluxDB.** Write line protocol straight to InfluxDB (2.x or 1.8) for
  charting in Grafana, with no translator container in between.
- **Any web endpoint.** POST NDJSON, JSON, CSV, metrics JSON, or InfluxDB line
  protocol to a server you run.
- **MQTT.** Publish to an `mqtt://` or `mqtts://` broker.
- **Test before you trust it.** Every destination can be limited to selected
  Health types, turned off, and tested before you rely on it, and each shows its
  last successful delivery and any attention state.
- **Health Auto Export compatibility.** An opt-in field-name mode for the Home
  Assistant, web, and MQTT metrics-JSON deliveries, for arriving with automations
  already keyed to those names. Hozz's own schema stays the default.

### Export formats

Manual exports come in the shape that suits what you want to do with them:

- **NDJSON** — the default: one record per line, streamable and lossless.
- **JSON** — a single array, handy for smaller exports and tools that want one
  JSON value.
- **CSV** — one file per Health type, opens in any spreadsheet (lossy by nature —
  a grid can't hold nested details).
- **SQLite** — a ready-to-query database for Datasette, DuckDB, pandas, Grafana,
  or `sqlite3`, with every original record preserved in a `raw` column.
- **Markdown** — one note per day with YAML front matter for Obsidian/Dataview
  (keeps a day's totals, not the raw records).
- **GPX** — one track per workout that has GPS, for maps and fitness tools.

Every delivery format is documented field by field, with example payloads, in
**[`docs/delivery-schema.md`](docs/delivery-schema.md)** — so you can build
against Hozz without reading the source.

### On your Mac

- **A local receiver and browser.** The Mac app stores accepted deliveries in a
  local SQLite database, dedupes them, and never phones home.
- **See what's arrived.** Browse what's been received and how far back it
  reaches, with your own characteristics shown above the measurements.
- **Charts.** Plot any numeric type by hour, day, week, or month, and export a
  type as CSV.
- **Folder watching.** Point the phone at a synced folder and the Mac at the
  same folder, and it ingests new files automatically — handy when the local
  network refuses inbound connections.
- **A dependency-free script, too.** A single-file Python receiver lives in
  [`receiver/`](receiver/) for anyone who'd rather run a script than the app.

### Ask your Health data questions (MCP)

- **A read-only assistant.** The Mac app embeds a local, read-only MCP server, so
  an AI assistant can answer questions against a database that's always current —
  no re-parsing a giant XML export each time.
- **Built not to overstate.** Trends report "no detectable change" when the data
  doesn't support one and refuse below two weeks; correlations show their
  uncertainty; anomaly checks report "the device wasn't worn" rather than calling
  a gap a low reading. The full list of what each tool will and won't claim is in
  **[`docs/mcp.md`](docs/mcp.md)**.

### Private by design

- **Nothing leaves without your say-so.** No default destination, no telemetry,
  no relay the maintainer runs.
- **Credentials stay on your device.** Destination secrets live in the device
  Keychain and are not synced.
- **Health files are protected.** Health-derived files use complete-unless-open
  file protection and are excluded from device backups.
- **Logs never contain your data.** Diagnostics record statuses and failure
  states, never Health values, credentials, or response bodies.

## Getting started

Hozz is an early alpha and isn't on the App Store yet, so today you build it
yourself from source with Xcode. See
**[CONTRIBUTING.md](CONTRIBUTING.md)** for setup.

You'll want:

- An **iPhone running iOS 17 or newer** for the app.
- Optionally, a **Mac running macOS 14 or newer** for the companion receiver,
  browser, charts, and assistant — or any of the other destinations above
  instead.

### Android foundation

This repository also contains an **unreleased Android foundation** under
[`Android/`](Android/). It can import a lossless Hozz NDJSON/ZIP archive into a
local canonical store, show archive-only records, preview Health Connect mapping
loss, and explicitly write the mapped subset. Apple Health extraction still
happens on an Apple device; Android support is not a shipped product yet.

## What Hozz keeps, and its limits

Hozz's honesty is a feature. It currently exports quantity and category samples,
workouts and Health's workout statistics, paged workout routes, ECGs with
voltage waveforms, audiograms, State of Mind entries, medication dose events,
historical deletions, and the six Health characteristics. Some things it
catalogues or reports as unsupported rather than silently claiming as coverage:

- **Background delivery is limited by iOS, and Hozz says so.** iOS decides when
  background work runs, most Health types are capped at hourly delivery, Health
  can't be read while the phone is locked, and force-quitting Hozz stops
  launches until you reopen it. Hozz reports those states instead of calling them
  success.
- **Workout ↔ sample links are an approximation.** HealthKit can't tell a sample
  which workout it belonged to, so Hozz matches by time range and is upfront that
  overlapping workouts and stray background samples can be misattributed. A
  workout's own statistics are exact.
- **Clinical (health) records are off by default.** The code to read FHIR
  records from a connected provider is compiled out of the default build, on
  purpose. That reader is a development spike and does not yet reconcile
  disappearing records into tombstones, so clinical export is not supported
  coverage. Its build gates are documented for testing — see
  [CONTRIBUTING.md](CONTRIBUTING.md#enabling-clinical-health-records).
- **Hozz doesn't write back into Apple Health.** That's a decision, not an
  oversight: Health would permanently stamp restored data as Hozz's, has no way
  to avoid duplicating on re-import, and can't accept characteristics or clinical
  records at all. Exporting somewhere you own has none of those problems, and
  that's the direction Hozz works in.

The full per-type coverage table, the durability guarantees behind "does not lose
records," and the clinical-records details are in
**[CONTRIBUTING.md](CONTRIBUTING.md)**.

## Reporting bugs & requesting features

Please open a [GitHub issue](https://github.com/thatcube/hozz/issues). Because
Hozz never sends your Health values anywhere you didn't configure, please don't
paste Health sample values into an issue. See
**[CONTRIBUTING.md](CONTRIBUTING.md)** for more.

## Contributing & development

Build instructions, the test suite, the durability and anchoring design, the Mac
app's networking gotchas, and how to enable clinical records all live in
**[CONTRIBUTING.md](CONTRIBUTING.md)**. Wire formats are in
[`docs/delivery-schema.md`](docs/delivery-schema.md) and the assistant tools in
[`docs/mcp.md`](docs/mcp.md).

## Donate

Sponsorship supports continued development of Hozz and Brandon's other
open-source projects.

**[Donate via GitHub Sponsors](https://github.com/sponsors/thatcube)**

## Credits

Hozz reads from **Apple Health** (HealthKit) on your device. Apple, Apple Health,
and HealthKit are trademarks of Apple Inc.; Hozz is an independent project and is
not affiliated with or endorsed by Apple. Your Health data is yours — Hozz just
helps you move a copy of it somewhere you own.

## License

[GPL-3.0, with an additional permission for Apple App Store distribution](LICENSE)
© 2026 Brandon Moore

<!-- app-family:start -->
<!-- Generated by https://github.com/thatcube/brando — edit apps.json there, not this block. -->

---

<p align="center"><b>More open source</b></p>

<p align="center">
  <a href="https://github.com/thatcube/hozz" title="Hozz — Apple Health, exported to storage you own"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/hozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/hozz-light.svg" height="40" alt="Hozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/thatcube/Mozz" title="Mozz — Your music, wherever it lives"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/mozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/mozz-light.svg" height="40" alt="Mozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/thatcube/Plozz" title="Plozz — Movies &amp; TV on Apple TV, iPhone &amp; iPad"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/plozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/plozz-light.svg" height="40" alt="Plozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/thatcube/Twozz" title="Twozz — Twitch on Apple TV, with real emotes"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/twozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/twozz-light.svg" height="40" alt="Twozz" /></picture></a>
</p>

<p align="center">
  <a href="https://brando.page">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/brando-white.svg" />
      <img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/brando-black.svg" height="22" alt="Brandon Moore" />
    </picture>
  </a>
</p>
<!-- app-family:end -->
