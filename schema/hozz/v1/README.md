# Hozz archive schema v1

`archive-manifest.schema.json` describes the `hozz-manifest.json` sidecar in a
versioned Hozz NDJSON ZIP. `canonical-record.schema.json` describes each NDJSON
line. The stream intentionally retains run records such as `manifest`,
`typeSummary`, and `completion`; consumers skip them when building a health
timeline.

The sidecar is additive. Readers must continue accepting legacy Hozz exports
that contain one `.ndjson` member and carry their version only in the first
`kind: "manifest"` line.

`health-connect-mappings.json` is the source of truth for HealthKit-to-Health
Connect projection. Generated Swift and Kotlin constants must be refreshed with:

```bash
tools/generate-shared-contracts.py
```

Records and fields unknown to a reader are preserved in the archive rather than
dropped. A projection is never evidence that the archive can be discarded.

`recordVersion` is Hozz's monotonic version for merge and projection. A source
store's own version belongs in `sourceRecord.version` when that store exposes
one; HealthKit does not, so Apple records omit it rather than inventing a value.
Likewise, HealthKit exposes a quantity's normalized value and a textual source
description but not a stable original unit/value pair. In that case
`quantity.original` carries only the description.

Android canonical exports sort records by canonical ID, recursively sort JSON
object keys, derive the archive ID from the resulting NDJSON, and use source
record time for the manifest timestamp. Exporting an unchanged store therefore
produces the same bytes.
