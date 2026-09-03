# Hozz for Android

This is the first Android shell for Hozz. It imports the lossless Hozz NDJSON
archive through Android's Storage Access Framework, keeps a local canonical
store, shows archive-only records honestly, and can explicitly project the
mapped subset into Health Connect.

It does not read Apple Health on Android and it does not use Health Connect as
the archive. Apple Health extraction still happens on an Apple device.

This project is an unreleased foundation, not a claim that Android support is
shipping. Health Connect projection stays explicitly user-initiated while
Google Play's policy on transfers between otherwise incompatible platforms is
clarified.

## Build

```bash
cd Android
./gradlew test assembleDebug
```

The project targets Android 16/API 36 and supports Android 9/API 28 or newer.
On Android 9 through 13, Health Connect must be installed from Google Play. It
is part of the system on Android 14 and newer.

`tools/generate-shared-contracts.py` owns the generated mapping and colour
sources. Gradle rejects a build when they drift from `schema/` or
`Sources/HozzUI/HozzPalette.swift`.
