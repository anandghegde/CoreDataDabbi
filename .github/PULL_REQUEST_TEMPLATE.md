## What and why

<!-- One or two sentences. Link the issue / work package (e.g. M0-04). -->

**PRD IDs:** <!-- e.g. PRJ-3, BRW-4 -->

## Checklist

- [ ] **Clean-room:** this change is based only on public documentation and on Apple frameworks observed through public APIs. I did not decompile or inspect any closed-source product.
- [ ] Commits are signed off (`git commit -s`, DCO).
- [ ] Tests added or updated; `swift test` passes.
- [ ] No new strict-concurrency warnings.
- [ ] Public engine API has DocC comments.
- [ ] No row data is logged (store-derived values are wrapped in `Redacted`).
- [ ] User-visible strings are externalised; new controls have accessibility labels.
- [ ] ADR added or amended if a decision changed.
