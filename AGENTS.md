# Hozz contributor notes

Keep this repository simple, privacy-conscious, and honest.

- Hozz is free and open source. Do not add subscriptions, ads, analytics,
  accounts, or maintainer-operated infrastructure.
- Never add a default network destination. Nothing leaves the device until the
  user explicitly configures and confirms one.
- Never claim HealthKit completeness that the app cannot prove. Unknown,
  unavailable, denied-or-empty, and unsupported states must remain visible.
- `HozzHealth` is the only production module that may import HealthKit.
- Acquisition never uses date-window watermarks. Anchors are opaque,
  type-scoped, device-local, and committed only with durable staged data. In
  practice that means an anchor may only advance inside the same store
  transaction that seals the part holding its bytes; an unsealed part is
  discarded on relaunch and its work replays.
- Do not add a permanent local mirror of Health history without an explicit
  architecture review. The default design uses a bounded canonical spool.
- Keep credentials device-only in Keychain and Health-derived files protected
  and excluded from backup.
- Logs and diagnostics must never include sample values, credentials, or secret
  destination details.
- Add tests for transaction boundaries, cancellation, retries, tombstones,
  deterministic encoding, and privacy invariants as each feature lands.
- Do not commit signing credentials, App Store Connect keys, `.env` files, or
  generated Xcode projects.

Generate, build, and test:

```bash
xcodegen generate
xcodebuild -project Hozz.xcodeproj -scheme Hozz \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project Hozz.xcodeproj -scheme Hozz \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
