# ADR-13: .dabbi is a JSON package

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

Projects are schema-versioned JSON packages. Machine-local state (bookmarks, window state) is separable from shareable state.

## Why

Diffable, committable and team-friendly (PRD §9.6).

## Consequences

Forward migrations are keyed on `schemaVersion`; unknown keys are preserved on save.
