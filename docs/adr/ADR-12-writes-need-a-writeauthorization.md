# ADR-12: Writes need a WriteAuthorization

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

Write APIs require a `WriteAuthorization` value that only the app and `dabbi --allow-writes` can mint. The MCP target cannot construct one.

## Why

"Writes are never exposed over MCP" becomes a compile-time property.

## Consequences

The initialiser is `package`-level, wrapped by public factories in code the MCP command does not link.
