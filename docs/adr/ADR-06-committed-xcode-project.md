# ADR-06: Committed Xcode project

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

A committed `.xcodeproj` with folder-synchronised groups references the local package. No XcodeGen or Tuist.

## Why

Clone, open, run — with zero extra tools.

## Consequences

Project-file merge conflicts are limited by folder-synchronised groups.
