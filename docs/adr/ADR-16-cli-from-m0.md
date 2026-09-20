# ADR-16: CLI from M0

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

The CLI target is created in M0 with `describe` and `query` and hardened into the product CLI in M6.

## Why

It is the headless exit criterion for M0; agents and CI use it from day one.

## Consequences

The CLI is the engine's first consumer and keeps the API honest.
