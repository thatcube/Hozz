# Platform capability contract

Hozz is a health-data unifier. Platform parity means that each applicable shell
offers the same trustworthy outcome, not that SwiftUI and Compose copy the same
screens.

| Capability | iPhone today | Mac today | Android foundation | Contract |
| --- | --- | --- | --- | --- |
| Receive or acquire | Reads Apple Health with anchored queries | Receives batches and watches folders | Imports Hozz archives through the system picker | Name the source and never substitute date windows for source cursors. |
| Understand coverage | Reports per-type acquisition state | Reports received coverage | Previews exact, lossy, and archive-only mappings | Empty, denied, incomplete, and unsupported remain distinct states. |
| Preserve | Keeps a bounded durable spool | Keeps the accumulating local archive | Keeps a versioned canonical local archive with tombstones | Stable IDs and monotonic versions make retries idempotent; unknown fields survive. |
| View | Health dashboard | Archive browser and analysis | Native Compose summary and timeline | A record stays visible even when a destination cannot represent it. |
| Project | Sends destination-specific payloads | Exposes queries and exports | Opt-in Health Connect projection | Projection is never the source of truth and every loss is named. |
| Move onward | Manual export and configured destinations | CSV and folder access | Saves a new canonical Hozz archive through the system picker | Transports are replaceable and user-controlled; no hosted relay is assumed. |

## Gaps revealed by Android

- iPhone and Mac should show the same exact/lossy/archive-only preview before a
  destination projection.
- Both Apple shells should expose canonical IDs, versions, tombstones, and
  source lineage as archive concepts rather than treating HealthKit identifiers
  as the whole model.
- Destination history should distinguish a successful lossless transfer from a
  successful lossy projection.
- Conflict handling should name whether an incoming record was new, newer,
  already current, or stale.
- The Mac archive browser should retain and label unprojectable records with the
  same mapping-warning vocabulary as Android.
- Future Health Connect acquisition must mark its package lineage so Android
  records are never blindly projected back into the same store.
- Shell navigation can differ, but every shell should make the unifier workflow
  legible: receive, understand, view, project, and move onward.
