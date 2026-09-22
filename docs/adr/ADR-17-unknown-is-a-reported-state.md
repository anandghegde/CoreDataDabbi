# ADR-17: Unknown is a reported state, never a guess

- **Status:** Accepted
- **Date:** 2026-09-21

## Decision

Where the tracker does not know something, it reports *unknown* rather than the likeliest answer. Concretely: a row with no prior reading gets a `nil` `before` and a `nil` `changedKeys` (as against an *empty* `changedKeys`, which means "compared, nothing differs"); a row whose earlier membership of a watched view is not known gets no `PredicateTransition`, even though it is still reported as changed; an attribute only one side of a diff carries is not compared at all, which is how a blob Core Data keeps in a file beside the store — absent from a deep-tracking copy of the database — comes back unknown instead of emptied; and `PriorValues.membershipIsComplete` records whether absence from the member set means non-member or nothing at all.

## Why

The plausible answer is the dangerous one. An empty before-column reads as "it used to be blank", a missing member reads as "it has just arrived", and a blob whose file was not copied reads as "someone deleted it" — three wrong stories a user would act on, told confidently by a tool whose whole purpose is to say what a store contains. A field left visibly unknown costs the user one more click; a field quietly guessed wrong costs them their trust in every other field.

## Consequences

Unknown has to be representable everywhere the values are, so optionality is load-bearing in `ChangeEvent` and is not to be flattened for convenience: `nil` and empty are different answers and both are in the public API. The tracking UI (M2-10) needs labels for it — *changed, prior value unknown*, and a session marked reduced-fidelity when `ScanLimitation`s are present — rather than blank cells. It also puts a ceiling on how good the diff can look without help, which is what deep tracking, `ChangeTracker.remember(_:)` and history enrichment (M2-08) each buy back: they turn unknowns into facts instead of into guesses.
