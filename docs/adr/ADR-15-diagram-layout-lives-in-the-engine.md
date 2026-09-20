# ADR-15: Diagram layout lives in the engine

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

Auto-layout and the text exporters (SVG, Mermaid, DOT) live in the engine; PDF/PNG rendering lives in the app.

## Why

The CLI can emit diagrams, and layout is unit-testable.

## Consequences

`DabbiDiagnostics` hosts `DiagramLayout` and the emitters.
