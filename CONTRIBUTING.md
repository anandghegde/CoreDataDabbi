# Contributing to CoreDataDabbi

Thank you for helping. This project is maintainer-led; decisions are made in public GitHub issues and discussions.

## Ground rules

### 1. Clean-room rule

CoreDataDabbi reproduces *capabilities* of existing tools, never their expression. Behaviour must come only from:

- public documentation and release notes, and
- Apple's frameworks and tools, observed through their public APIs and through stores you generate yourself.

Do **not** decompile, disassemble, or inspect the binaries, resources or project files of Core Data Lab or any other closed-source product, and do not copy its assets, screenshots, help text or UI copy. Every pull request affirms this with a checkbox.

### 2. Developer Certificate of Origin (DCO)

There is no CLA. Instead, sign off every commit:

```sh
git commit -s -m "Add gzip content decoder"
```

This adds a `Signed-off-by:` line certifying the [DCO 1.1](https://developercertificate.org). CI rejects pull requests with unsigned commits.

### 3. Licence

Contributions are accepted under the [MIT licence](LICENSE). New dependencies must be permissively licensed (MIT/BSD/Apache-2.0) and need a maintainer's agreement first — the project deliberately has very few.

## Getting started

```sh
swift build
swift test              # the tests generate the fixtures they need, in a temporary folder
Scripts/fixtures.sh     # optional: the whole zoo in Fixtures/ (git-ignored), to poke at with `dabbi`
```

No signing identity, paid account or secret is needed for a debug build.

## Where to start

Good first contributions are the protocol plug-points, where a PR is typically one new file plus a fixture:

| Plug-point | Target | Protocol |
|---|---|---|
| Field content decoders | `DabbiContent` | `ContentDecoder` |
| Exporters / importers | `DabbiExchange` | `Exporter`, `Importer` |
| Store Doctor checks | `DabbiDiagnostics` | `DoctorCheck` |
| Diagram emitters | `DabbiDiagnostics` | — |

Look for the `good first issue` label.

## Architecture in one paragraph

The engine is a single SwiftPM package with layered targets (see [ARCHITECTURE.md](docs/ARCHITECTURE.md) §3). Arrows only point down; no engine target imports AppKit or SwiftUI (`Scripts/check-layering.sh` enforces this in CI). Everything crossing the engine's public API is a `Sendable` value type — `NSManagedObject` and friends never leave `DabbiStore`. Knowledge of Core Data's *private* on-disk format is quarantined in `SchemaMap`/`FormatProbe` (`DabbiModel`) and `HistoryReader` (`DabbiTracking`), and guarded by format canary tests.

## Definition of done

- Tests at the right tier pass in CI (`swift test`).
- No new strict-concurrency warnings (Swift 6 language mode everywhere).
- Public engine API has DocC comments.
- User-visible strings are externalised; new controls have accessibility labels.
- **No row data in logs.** Anything derived from store content is wrapped in `Redacted`.
- The PR references the PRD requirement IDs it addresses (e.g. `BRW-4`).
- An ADR under `docs/adr/` is added or amended when a decision changes.

## Branching and pull requests

Trunk-based: short-lived branches, squash merge. One work package from the plan may span several PRs. Labels: `prd:<ID>`, `milestone:Mx`, `area:<target>`.

## Style

`swift format` with the repository's `.swift-format`. Before pushing, run what CI runs: `swift test`, `Scripts/lint.sh` (`--fix` formats in place), `Scripts/check-layering.sh` and `Scripts/smoke.sh`. CI lints with Xcode 26.4; another toolchain's `swift format` may disagree about line breaks.
