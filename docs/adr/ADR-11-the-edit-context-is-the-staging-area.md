# ADR-11: The edit context is the staging area

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

Staged edits are the editable context's unsaved change set plus its `UndoManager`.

## Why

No parallel change model to keep in sync; validation and the pending-change display come straight from Core Data.

## Consequences

`PendingChange` is derived from `insertedObjects`/`updatedObjects`/`deletedObjects`.
