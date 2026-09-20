# ADR-07: System SQLite with a thin wrapper

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

`import SQLite3` plus an in-house wrapper. No GRDB or SQLite.swift.

## Why

We need only prepared statements, the authorizer, interrupt and the backup API; the PRD wants few dependencies and the system library.

## Consequences

`DabbiSQLite` owns all C interop. It knows nothing about Core Data's schema.
