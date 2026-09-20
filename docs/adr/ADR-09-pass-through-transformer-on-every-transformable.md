# ADR-09: Pass-through transformer on every transformable

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

The sanitiser gives **every** transformable attribute the pass-through transformer — not only those with unknown names.

## Why

A `nil` transformer name means Core Data's default secure-unarchive transformer, which would instantiate classes from untrusted data. Spike S1 showed version hashes are unaffected.

## Consequences

The original transformer name is kept in `ModelDescription` for display. After sanitising we assert that `entityVersionHashesByName` is unchanged and fail loudly otherwise.
