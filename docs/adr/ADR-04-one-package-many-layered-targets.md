# ADR-04: One package, many layered targets

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

One SwiftPM package with multiple targets and enforced layering, and one umbrella product `DabbiKit`. Cross-target internals use the `package` access level.

## Why

Layering is compiler-checked, decoders can be fuzzed alone, and the public API stays small.

## Consequences

Targets are prefixed `Dabbi…` because module names must be unique across a consumer's dependency graph. `Scripts/check-layering.sh` additionally forbids UI frameworks in engine targets.
