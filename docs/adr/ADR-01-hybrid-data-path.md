# ADR-01: Hybrid data path

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

Core Data is the read path for object values and the only write path. Raw SQLite is used only for change detection, the SQL console, statistics, the history fallback and raw mode.

## Why

Drivers D2 (model-faithful) and D6 (private on-disk details may change). Core Data gives authoritative decoding of every attribute type, composites, external storage and validation for free. Restricting raw SQLite to auxiliary jobs shrinks the private-format surface to table names, `Z_PK`/`Z_ENT`/`Z_OPT` and join tables.

## Consequences

Every feature that reads raw tables must check `FormatProbe` and degrade with an explanation. Object values never come from hand-decoded columns.
