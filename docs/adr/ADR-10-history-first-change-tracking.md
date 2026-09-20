# ADR-10: History-first change tracking

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

The tracker reads persistent history when it exists and falls back to a `Z_PK`/`Z_OPT` scan. To-many changes come from join-table diffs. Changed rows are materialised through Core Data.

## Why

Exact and cheap when history exists; universal otherwise.

## Consequences

`HistoryReader` is a protocol with a public-API implementation and a raw-table implementation.
