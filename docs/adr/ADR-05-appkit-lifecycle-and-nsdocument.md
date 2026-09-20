# ADR-05: AppKit lifecycle and NSDocument

- **Status:** Accepted
- **Date:** 2026-09-20

## Decision

The app uses the AppKit lifecycle with `NSDocument`. SwiftUI is hosted through `NSHostingView` for inspector forms, settings, wizards and the welcome window. `DocumentGroup` is not used.

## Why

Tabs, Versions, package documents, `NSTableView`, `NSPredicateEditor` and responder-chain menus all need AppKit-level control.

## Consequences

View models are `@MainActor @Observable`; heavy controls are AppKit views.
