# ADR-03: StoreSession and ChangeTracker are actors

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

Both are actors. Core Data work runs inside `await context.perform {}` and returns DTOs.

## Why

Data-race safety without leaking `@unchecked Sendable` into the API.

## Consequences

No transaction or Core Data object is held across an `await` outside `perform`.
