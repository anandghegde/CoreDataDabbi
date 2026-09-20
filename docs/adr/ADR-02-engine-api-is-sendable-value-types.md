# ADR-02: Engine API is Sendable value types

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

`NSManagedObject`, contexts and coordinators never cross `StoreSession`'s public API. Front ends see `ObjectRef`, `Value`, `RowSnapshot`, `RowPage`, `ModelDescription` and friends.

## Why

Swift 6 strict concurrency; the same API serves the GUI, the CLI and the MCP server; value rows are cheap to cache and to diff.

## Consequences

Conversion to DTOs happens inside `context.perform`. The boundary types in `DabbiBase` are the semver'd contract of `DabbiKit`.
