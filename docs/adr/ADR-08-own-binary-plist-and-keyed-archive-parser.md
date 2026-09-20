# ADR-08: Own binary-plist and keyed-archive parser

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

Attribute data is parsed by our own bounded `bplist00` reader. `NSKeyedUnarchiver` is never run on attribute data.

## Why

`PropertyListSerialization` hides `CFKeyedArchiverUID` values behind private types, and unarchiving untrusted data instantiates classes. Our parser is bounded, fuzzable and safe.

## Consequences

The keyed-archive tree shows `$classname`s without instantiating anything.
