# CoreDataDabbi

*Dabbi* — "box": the box your app's data lives in.

CoreDataDabbi is a **free, open-source** macOS developer tool for viewing, querying, editing, tracking and diffing the data inside **Core Data and SwiftData stores** — for Mac apps, apps in any Apple simulator, exported Xcode app containers and debug apps on physical devices. It never requires changes to the inspected app.

> **Status: pre-alpha — milestone M1, the viewer, is complete.** The Mac app opens a store — from a file, from a simulator, or dropped on the welcome window — and browses it read-only: entity tree, grid, inspector, relationships and a content viewer for blobs and archives. A 210 MB store with a million rows opens in under half a second and scrolls at 60 fps ([the numbers](docs/ARCHITECTURE.md#appendix-c--verified-in-m1-2026-09-20)). Querying, editing, tracking and diffing are still to come. See the [implementation plan](docs/IMPLEMENTATION_PLAN.md).

## What is here today

- **CoreDataDabbi.app** — the read-only viewer. Browse Simulators, Open Database, or drop a store, an app bundle or an `.xcappdata` container on the welcome window.
- `DabbiKit` — a UI-free Swift package (the engine) with a `Sendable` value-type API.
- `dabbi` — a command-line front end used as the engine's harness:

  ```sh
  swift run dabbi describe path/to/App.sqlite
  swift run dabbi query path/to/App.sqlite Person --where 'age > 30' --limit 20 --json
  ```

- `FixtureGen` — generates a zoo of Core Data stores used by the tests (nothing binary is committed).

## Build

Requirements: macOS 14 or later, Xcode 16 or later (Swift 6) for the package; the app is built with Xcode 26. No accounts, secrets or extra tools.

```sh
git clone https://github.com/anandghegde/CoreDataDabbi.git
cd CoreDataDabbi
swift build
swift test                 # the tests generate the fixtures they need
Scripts/smoke.sh           # the CLI loads the whole fixture zoo (generated into Fixtures/ on first run)

Scripts/app.sh build       # the Mac app
Scripts/app.sh test
open "$(Scripts/app.sh path)"
```

## How it works

Core Data itself is the read path for object data, so values, composites and external storage are decoded authoritatively. The model is loaded from the app bundle or from the copy Core Data caches inside the store, then *sanitised* so that none of the inspected app's classes are ever needed or instantiated. Raw SQLite is used only where Core Data cannot help (change detection, raw mode, statistics) over a hardened read-only connection.

Design documents:

- [Product requirements](docs/PRD.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md)
- [Architecture decision records](docs/adr/)

## Safety

Stores are opened **read-only by default**. Reads use short transactions so the inspected app's WAL checkpoints are never blocked. Attribute data is parsed, never unarchived into classes.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Two rules matter most: sign off your commits (DCO, `git commit -s`) and follow the clean-room rule.

Security issues: see [SECURITY.md](SECURITY.md).

## Credits

CoreDataDabbi is inspired by [Core Data Lab](https://betamagic.nl/products/coredatalab.html) by Betamagic, a polished commercial tool that showed how useful a model-aware Core Data inspector can be. CoreDataDabbi is an independent, clean-room project: it shares no code, assets or text with Core Data Lab and is not affiliated with Betamagic or Apple.

## Licence

[MIT](LICENSE). The project name and icon are trademarks and are excluded from the licence grant.
