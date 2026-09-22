# ADR-10: History-first change tracking

- **Status:** Amended by [ADR-18](ADR-18-the-scan-decides-history-enriches.md) (2026-09-22)
- **Date:** 2026-09-20

## Decision

~~The tracker reads persistent history when it exists and falls back to a `Z_PK`/`Z_OPT` scan.~~ **Reversed by ADR-18:** the scan always runs and answers which rows changed; history is read as well, and enriches. The rest stands. To-many changes come from join-table diffs. Changed rows are materialised through Core Data.

## Why

Exact and cheap when history exists; universal otherwise.

## Consequences

`HistoryReader` is a protocol with a public-API implementation and a raw-table implementation.

## Amendment (2026-09-22)

`NSPersistentHistoryTrackingKey` is per store *open*, not per file, so a store can carry history tables and still be written by a process that saves with tracking off. History-first would miss those saves in silence. See [ADR-18](ADR-18-the-scan-decides-history-enriches.md).
