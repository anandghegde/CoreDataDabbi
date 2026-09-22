# ADR-18: The scan decides what changed; history says who changed it

- **Status:** Accepted
- **Date:** 2026-09-22
- **Amends:** [ADR-10](ADR-10-history-first-change-tracking.md)

## Decision

`ChangeScanner` is the sole answer to **which rows changed**. Persistent history is read *as well*, never *instead*, and supplies only what the scan cannot get at any price: the author, the context name, the process, the save time, the transaction number, the property *names* a save wrote to a row nobody had read, and the preserved values of a row deleted before anybody read it.

Three rules follow, and all three are in the code:

1. **History never removes a row from a batch.** A scanned row that history cannot account for is still reported, with `history == nil`, and the batch carries a `ScanLimitation(reason: .historyIncomplete)` naming the entity.
2. **History never overrules a diff.** Where prior values exist, `changedKeys` comes from comparing them. History fills `changedKeys` only when it would otherwise be `nil`, because history says what a save *wrote* and a diff says what *changed* — writing a field the value it already held is not a change.
3. **History is read before the scan**, and its token is committed only after the scan succeeds. The reverse order would advance the token past saves the batch does not report and lose their attribution permanently. A save landing between the two reads is a `historyIncomplete` limitation, not a silence.

## Why

ADR-10 said *persistent-history-first, scan as fallback*, on the reasoning that history is exact and cheap where it exists. The first half is true and the second does not follow, because of one fact about how history is switched on: `NSPersistentHistoryTrackingKey` is an option **per store open**, not a property of the file. An app can open its store with tracking on for one launch and off for the next, or run a sync process that sets it and a migration tool that does not. Those saves land in the file and never reach `ATRANSACTION`.

So "the store has history tables" does not mean "history knows about every save into this store", and there is no way to ask the file which it is. A history-first tracker would read an empty transaction list and report nothing at all — no rows, no limitation, no sign — for changes it can plainly see by scanning. That is the exact failure ADR-17 exists to forbid, and it is worse than the usual unknown because there is nothing on screen to be unknown *about*.

The asymmetry settles it. Getting this wrong in the direction ADR-10 chose loses changes silently; getting it wrong in this direction costs one missing author on a row that is still reported, still diffed, and still marked as lacking one. The scan's cost is why ADR-10 wanted to avoid it, and the measurements (Appendix D) say it is affordable: 90 ms on a million rows, inside a 500 ms budget of which 150 ms is already the debounce.

## Consequences

The scan runs on every commit, on every store, history or not — there is no cheap path that skips it, and the baselines in Appendix D are therefore the baselines for every store rather than the worst case. `ChangeTracker.Options.History` can switch enrichment off; it cannot switch the scan off.

Enrichment being additive is what lets it be best-effort: `HistoryReaders.open(for:preferring:)` proves its choice by asking for a token and passing over a reader that cannot answer, a failed history read degrades to `historyUnavailable` rather than failing the batch, and the raw reader exists as a fallback for a Core Data that refuses a read-only history fetch. None of that can cost a reported change.

The limitation is raised only when enrichment is on, the store carries history tables, and the batch has rows — otherwise every batch of every ordinary store would be `isReducedFidelity` and the flag would mean nothing.

ADR-10 stands as written for everything else: to-many changes from join-table diffs, changed rows materialised through Core Data, and `HistoryReader` as a protocol with a public-API implementation and a raw-table one.
