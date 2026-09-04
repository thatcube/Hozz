# Hozz for Android

This is the first Android shell for Hozz. It imports the lossless Hozz NDJSON
archive through Android's Storage Access Framework, keeps a local canonical
store, shows archive-only records honestly, and can explicitly project the
mapped subset into Health Connect on Android 14/API 34 or newer.

It does not read Apple Health on Android and it does not use Health Connect as
the archive. Apple Health extraction still happens on an Apple device.

This project is an unreleased foundation, not a claim that Android support is
shipping. On supported devices, Health Connect projection stays explicitly
user-initiated while Google Play's policy on transfers between otherwise
incompatible platforms is clarified.

## Build

```bash
cd Android
./gradlew test assembleDebug
```

The project targets Android 16/API 36 and supports the canonical archive
workflow on Android 9/API 28 or newer. Health Connect projection requires the
system module on Android 14/API 34 or newer. Hozz deliberately reports
projection as unavailable on Android 9 through 13 even when the standalone
Health Connect provider is installed: its identifier-delete contract rejects a
retry after the first delete succeeds, so a process death before Hozz commits
its ledger cannot be reconciled safely without requesting broad historical
read access.

`tools/generate-shared-contracts.py` owns the generated mapping and colour
sources. Gradle rejects a build when they drift from `schema/` or
`Sources/HozzUI/HozzPalette.swift`.
