# Security policy

CoreDataDabbi opens **untrusted database files** and renders their contents. Bugs in the model loader, content decoders, SQLite handling or the web preview are therefore security-relevant, and we treat them that way.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private vulnerability reporting for this repository (*Security › Report a vulnerability*). Include:

- the affected version or commit,
- a description of the issue and its impact,
- a reproducer — ideally a minimal store file or blob. Never attach real user data.

You will get an acknowledgement within 7 days. We will agree a disclosure date with you once a fix is ready, and credit you in the release notes unless you prefer otherwise.

## Scope

In scope:

- memory safety or code execution from opening a store, model cache, project file, container or blob;
- class instantiation from attribute data (attribute data must only ever be *parsed*);
- decompression bombs or unbounded recursion in decoders;
- any write to a store opened read-only, or any write reachable through the MCP server;
- remote loads from the content viewer when the project has not allowed them;
- row data appearing in logs or problem reports.

Out of scope: issues that require an attacker who already controls the user's account, and vulnerabilities in Apple frameworks themselves (report those to Apple; tell us too if CoreDataDabbi can mitigate them).

## Design commitments

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) §10. In short: hardened read-only SQLite connections, the model unarchiver restricted to Core Data's own classes, bounded decoders, no telemetry, no network use beyond opt-in remote content and update checks.
