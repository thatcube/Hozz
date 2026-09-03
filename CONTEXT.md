# Hozz

Hozz moves a person's health data between the places and platforms they use
without silently losing meaning or records.

## Language

**Archive**:
A versioned, lossless Hozz-owned collection of health records transferred
between devices or platforms.
_Avoid_: Backup, Health Connect database

**Canonical record**:
Hozz's source-neutral form of one health record, with a stable identity and
version, time semantics, canonical and original values, source lineage,
tombstone state, and untouched source data.
_Avoid_: Sample, row

**Source record**:
The record as supplied by its original health store, together with that store's
identity and provenance.
_Avoid_: Canonical record

**Tombstone**:
A versioned canonical record stating that a previously observed source record
was deleted.
_Avoid_: Missing record

**Lineage**:
The ordered history of stores and adapters through which a canonical record has
travelled. A projection never writes a record back to the same store identity
already present in its lineage.
_Avoid_: Origin

**Projection**:
A deliberate mapping from a canonical record into a platform store that may
preserve less meaning than the archive.
_Avoid_: Restore, sync

**Mapping warning**:
A machine-readable statement naming meaning that a projection cannot represent
exactly.
_Avoid_: Error

**Archive-only record**:
A canonical record Hozz preserves and shows but does not project because the
destination store has no faithful representation.
_Avoid_: Unsupported record

**Platform adapter**:
A boundary that reads from or writes to a platform health store without making
that store Hozz's source of truth.
_Avoid_: Core

**Shell**:
The native user interface for one platform.
_Avoid_: Client

**Transport**:
A user-controlled path by which an archive moves between devices or platforms.
_Avoid_: Sync engine

**Destination**:
A place a person explicitly chooses to receive an archive or projection.
_Avoid_: Transport
