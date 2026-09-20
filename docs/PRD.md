# CoreDataDabbi — Product Requirements Document

| | |
|---|---|
| **Working name** | CoreDataDabbi ("Dabbi" — *box*: the box your app's data lives in) |
| **Doc status** | Draft v1.1 · 2026-09-20 |
| **Model** | Free and open source (no paid tier, no trial, no telemetry) |
| **Owner** | Anand Hegde |
| **Reference product** | [Core Data Lab](https://betamagic.nl/products/coredatalab.html) by Betamagic (v2.4.7 on the Mac App Store, $19.99, macOS 10.15+; site shows 3.0 feature art) |
| **Platform** | Native macOS app (Apple Silicon + Intel), plus a CLI and an MCP server built on the same engine |

---

## 1. Summary

CoreDataDabbi is a **free, open-source** native macOS developer tool for **viewing, querying, editing, tracking and diffing the data inside Core Data and SwiftData stores** — for Mac apps, apps in any Apple simulator, exported Xcode app containers, and (new) debug apps on physical devices.

Goal one is **feature parity** with Core Data Lab: model-aware data browsing, live change tracking, a predicate editor, a validated data editor, a field content viewer, relationship browsing, model diagrams, a simulator browser, CSV/JSON import/export, and project documents.

Goal two is to **beat it** where it is weak today (each gap below is documented in its own help/release notes):

| Gap in the reference product | Our answer |
|---|---|
| Change tracking doesn't work with predicates, parent/child entities, or read-only stores | Tracking works everywhere, including read-only and filtered views (§6.3) |
| Composite attributes are read-only | Full composite editing (§6.5) |
| No SQL access; predicates are builder-only | Text predicate mode + read-only SQL console with Core Data name mapping (§7.1, §7.2) |
| No notion of store state over time | Snapshots, restore-to-simulator, store-vs-store diff (§7.3) |
| Persistent history is a checkbox, not a feature | Persistent History timeline with authors/transactions (§7.4) |
| JSON import limited to to-many relationships with inverses | Any relationship, link-by-key (§6.9) |
| Dates shown in GMT only | Selectable time zone + raw value (§6.2) |
| Simulators only | Pull containers from physical devices via `devicectl` (§7.5) |
| GUI only | CLI, URL scheme, MCP server for AI agents (§7.8) |
| No model-evolution help | Model version diff + lightweight-migration check (§7.6) |
| Paid, closed source | Free, open source, scriptable engine anyone can build on (§14) |

> **Clone boundaries.** We replicate *capabilities*, not the expression: our own name, icon, copy, layout decisions, document format and code. No reuse of Betamagic assets, screenshots, or help text. Because our code is public, the rule is strict clean-room: behaviour is derived only from public docs and from Apple's frameworks — nobody decompiles or inspects the reference app's binary or project files.

---

## 2. Problem

Core Data and SwiftData persist to SQLite, but the on-disk format is hostile to inspection:

- Tables/columns are mangled (`ZPERSON`, `ZFIRSTNAME`, `Z_PK`, `Z_ENT`, `Z_OPT`), many-to-many joins live in `Z_12TAGS`-style tables, entity inheritance shares one table.
- Dates are seconds since 2001-01-01, UUIDs/URIs/transformables/composites are blobs, "Allows External Storage" blobs live in a hidden `_EXTERNAL_DATA` folder.
- Simulator containers live under opaque UUID paths that change on reinstall.
- SwiftData apps ship no compiled model (`.momd`) in the bundle at all.
- Generic SQLite tools can't validate edits against the model, so hand edits corrupt object graphs.

Developers need to answer, quickly: *What did my app just save? Why is this relationship nil? Is my migration/import/sync writing what I think? Can I reproduce this bug state again?*

## 3. Target users

| Persona | Needs |
|---|---|
| **iOS/macOS app developer** (primary) | See what the app wrote, live, while running in the simulator. Fix/seed data to reproduce bugs. |
| **QA / test engineer** | Put an app into a known data state, repeatedly. Export evidence of bad data. |
| **Developer migrating Core Data → SwiftData / adding CloudKit** | Verify model compatibility, history tracking, sync metadata. |
| **Support engineer / indie dev** | Open a customer's exported container or store file and find the broken record. |
| **AI coding agents** (new) | Read-only programmatic access to the store of the app under development. |

## 4. Goals and non-goals

**Goals**
1. Zero-instrumentation: never require changes to the inspected app (no SDK, no library).
2. Model-faithful: present data as entities/attributes/relationships, never as `Z` tables (except in raw/SQL modes).
3. Safe by default: read-only on open; writes are explicit, validated, backed up, undoable.
4. Fast on big stores: 1M-row entities scroll smoothly.
5. Project-based: pick up exactly where you left off.
6. Private: no data leaves the Mac. No telemetry at all.
7. Free and open: every feature available to everyone; the engine (`DabbiKit`) is a reusable package with a stable, documented API; the project is easy to build and contribute to (clone → open → run, no secrets or paid accounts needed for a debug build).

**Non-goals (v1)**
- Editing the *model* (we are not the Xcode model editor) or running migrations on a user's store.
- Non-SQLite stores for editing (XML/binary/in-memory are view-only, P2).
- Inspecting release/App Store builds on physical devices (not possible without the app's cooperation).
- Windows/Linux/iPad versions.
- A general-purpose SQLite admin tool (raw mode is for inspection only).

---

## 5. Product principles

- **Feels like Xcode's sibling.** Standard macOS document app: tabs, autosave, versions, inspector, toolbar, full keyboard access, Dark Mode, VoiceOver, "Differentiate without color" (tracking states get glyphs, not only colors).
- **Every view is copy-able as code.** Predicates → `NSPredicate` / `#Predicate` / `FetchDescriptor`; objects → JSON; diagrams → PDF/SVG/Mermaid.
- **Never surprise the running app.** We don't checkpoint its WAL, don't hold write locks while idle, and warn before writing under a live process.

---

## 6. Parity feature requirements

Priority: **P0** = required for 1.0, **P1** = 1.x, **P2** = later. IDs are stable for tracking.

### 6.1 Projects and store discovery

| ID | Requirement | Pri |
|---|---|---|
| PRJ-1 | Document-based app. A project (`.dabbi` package) stores: database reference, app/model reference, access mode, saved predicates (with column order/visibility/sort), diagrams, SQL snippets, snapshots index, window/selection state. Autosave, tabs, Versions. | P0 |
| PRJ-2 | File references stored as security-scoped bookmarks + last known path + simulator identity (device UDID, bundle ID, relative path) so they survive container UUID churn. | P0 |
| PRJ-3 | **Open Database…** — open a Core Data SQLite file directly using the model cached in the store (`Z_MODELCACHE`). Status area labels the model source: *Cached model* / *App bundle model* / *Model file*. Warn that a cached model can lack fetch request templates. | P0 |
| PRJ-4 | **Select App** (`.app`) → enumerate all `.momd/.mom` in the bundle (incl. frameworks/plugins) → **Search Database**: find stores whose metadata version hashes match (`NSStoreModelVersionHashes`). Fast path: look in the app's own container first, then the configured search path. Cancellable, streaming results. | P0 |
| PRJ-5 | **Select Model** (`.mom`/`.momd`) → same database search. | P0 |
| PRJ-6 | **Select Database** → **Search App**: find apps whose bundled model matches the store. | P1 |
| PRJ-7 | Manual pairing of database + app/model with compatibility check and a clear mismatch explanation (which entities' hashes differ). | P0 |
| PRJ-8 | **Simulator browser**: devices (iOS, iPadOS, watchOS, tvOS, visionOS) grouped by runtime, booted state badge; per device the apps that have Core Data/SwiftData stores, with app icon, bundle ID, store files (incl. App Group containers), size, modified date. One click → new project. Search field; "Booted only" filter. | P0 |
| PRJ-9 | **Open Container…** for Xcode `.xcappdata` packages; one store → open directly, several → picker. Finder "Open With" support. | P1 |
| PRJ-10 | **Project Assistant**: guided wizard covering all of the above paths; every choice editable later in Project Settings. | P1 |
| PRJ-11 | **SwiftData support**: detect SwiftData apps (no bundled `.mom`), extract bundle ID + app-group IDs from entitlements, locate `default.store` by convention (`Library/Application Support/`, group containers), load model from the store's cache. | P0 |
| PRJ-12 | **Auto-repair**: on window activation, verify store reachability. For simulator projects, re-resolve by device UDID + bundle ID after reinstall. If files are gone, show Project Settings with diagnosis and suggested fix. | P0 |
| PRJ-13 | **Raw SQLite mode**: open any SQLite DB without a model, read-only; tables, rows, `CREATE` script. Register as a viewer for `.sqlite`, `.db`, `.store`. | P1 |
| PRJ-14 | **Store Metadata** viewer: standard Core Data metadata + custom keys, store UUID, model version identifiers, per-entity version hashes. | P1 |
| PRJ-15 | Extension-less and custom-extension stores supported in search (configurable extension list). | P1 |
| PRJ-16 | Welcome window: recent projects, "Browse Simulators", "Open Database", drop zone for `.sqlite` / `.app` / `.xcappdata`. | P0 |

### 6.2 Data browsing

| ID | Requirement | Pri |
|---|---|---|
| BRW-1 | Sidebar sections: **Entities** (with row counts; abstract/parent hierarchy shown as a tree), **Fetch Requests** (model templates, runnable, with substitution-variable prompts), **Saved Predicates**, **Diagrams**, plus new sections from §7. Filter field at bottom. | P0 |
| BRW-2 | Main grid (AppKit `NSTableView`): one column per attribute + relationship summary columns (to-one: target's display value; to-many: count). Object ID column. | P0 |
| BRW-3 | Column ops: drag-reorder, hide/show via header context menu with checkbox list + "Show All", click-sort, "Remove Sorting", multi-column sort (shift-click), auto-size. Persisted per entity and per saved predicate. | P0 |
| BRW-4 | Type-aware rendering: dates (time zone selectable: UTC / local / custom; hover shows raw `TimeInterval`), booleans, decimals, UUID, URI, binary (size + detected type + thumbnail), transformable (decoded summary), composite (inline dictionary), `nil` visibly distinct from empty string. | P0 |
| BRW-5 | Sort/filter on transformable, binary, UUID, URI attributes where SQLite allows. | P1 |
| BRW-6 | Sub-entity handling: selecting a parent entity shows all descendants with an "Entity" column; selecting a child shows only that child. | P0 |
| BRW-7 | **Inspector › Details**: all attribute values of the selected object, tab-navigable, editable when unlocked. | P0 |
| BRW-8 | **Inspector › Entity description**: attributes (type, optional, default, min/max, regex, transformer, external storage, preserve-after-deletion, derived expression), relationships (destination, inverse, delete rule, min/max count, ordered), indexes, uniqueness constraints, user info, renaming ID, version hash; **Structure** tab with the raw SQLite DDL for the entity's table. | P0 |
| BRW-9 | **Detail window**: double-click opens an object in its own window with optional relationships pane — for side-by-side comparison. | P1 |
| BRW-10 | Grid font size (menu + settings), row striping, multi-select toggle, Invert Selection. | P1 |
| BRW-11 | Performance options: lazy-load property values (`fetchBatchSize`, faults), default sort on object ID, configurable fetch limit with "Load more". | P0 |
| BRW-12 | Copy row(s) as TSV / JSON / Markdown table; copy object ID URI. | P1 |

### 6.3 Change tracker

| ID | Requirement | Pri |
|---|---|---|
| TRK-1 | Toolbar **Play/Stop** (and `Data › Track Changes`, ⌘R). While tracking, the grid becomes a live log: **created** = green, **updated** = purple, **deleted** = red; each state also has a leading glyph (+ / ✎ / −). | P0 |
| TRK-2 | Every update inserts a **new version row** under the object; changed fields in strong text, unchanged fields dimmed. Prior versions remain visible. Updates to a newly created row are shown as updates. | P0 |
| TRK-3 | Works with macOS apps and apps in any simulator, with **no changes to the inspected app**. | P0 |
| TRK-4 | Tracking colors configurable in Settings. | P1 |
| TRK-5 | Export tracked session (with full version history) to JSON/CSV. | P1 |
| TRK-6 | Deleting objects while tracking is allowed (when unlocked). | P1 |
| TRK-7 | **Beyond parity:** tracking works on read-only stores, on parent/child entities, and on saved-predicate views (rows entering/leaving the predicate are flagged ↘ / ↗). | P0 |
| TRK-8 | **Beyond parity:** *Track All Entities* — a store-wide activity feed ("12:04:31 · Order +2, LineItem +7, Customer ✎1"), click to jump. Sidebar entities get live change badges. | P1 |
| TRK-9 | **Beyond parity:** timestamps per change, pause/resume, clear, relationship changes shown (added/removed object links for to-many). | P1 |
| TRK-10 | When the store has Persistent History enabled, enrich each change with transaction author, context name and transaction ID. | P1 |

### 6.4 Predicate editor (filtering)

| ID | Requirement | Pri |
|---|---|---|
| PRD-1 | Visual rule builder: All/Any/None compound root, nested groups, `+`/`−` rows; attribute → operator → value with type-appropriate editors (date picker, bool popup, number field, UUID field). Enter applies. | P0 |
| PRD-2 | Key paths through relationships (`customer.address.city`), to-many quantifiers (ANY/ALL/NONE), `@count`, elements of composite attributes (nested), nil checks, `BETWEEN`, `IN`, `CONTAINS/BEGINSWITH/ENDSWITH/LIKE/MATCHES` with `[cd]` toggles. | P0 |
| PRD-3 | Save predicate into the project with name, sort, column layout. Duplicate, rename, delete. Default name derived from first condition. Pre-select `name`/`title` attribute when present; focus first field. | P0 |
| PRD-4 | **Copy Predicate As**: format string, Swift `NSPredicate`, Objective-C, Swift `#Predicate` macro, full `NSFetchRequest` / `FetchDescriptor` with sort descriptors. | P1 |
| PRD-5 | On load, validate saved predicates against the current model; show a warning badge and the missing key paths rather than failing. | P0 |
| PRD-6 | Quick filter field above the grid: substring match across all string attributes of the current entity. | P1 |

### 6.5 Data editor

| ID | Requirement | Pri |
|---|---|---|
| EDT-1 | Global access mode: **Read-only (default)** ↔ **Editable**, a lock toggle in the toolbar; default for new projects set in Settings. | P0 |
| EDT-2 | Create, edit, delete objects; all mutations run through Core Data validation (optional, min/max, regex, relationship counts, delete rules, uniqueness constraints). Validation errors shown inline per field, in plain language. | P0 |
| EDT-3 | Edit in the inspector, inline in the grid, or in a detail window with relationship management pane (link/unlink existing objects via picker, create related object). | P0 |
| EDT-4 | Batch ops on displayed/selected rows: **Batch Update** (set value — all scalar types, not only integers), **Find and Replace** (strings; plain or regex), **Nullify Attributes**. Preview count + sample before applying. | P1 |
| EDT-5 | Persistent History aware: if the store has history tables, open with `NSPersistentHistoryTrackingKey` so it stays writable and our edits are recorded (author = `CoreDataDabbi`). | P0 |
| EDT-6 | Binary attributes: replace from file, save to file, clear. Supports external-storage blobs. | P1 |
| EDT-7 | **Beyond parity:** composite attribute editing (nested form). | P1 |
| EDT-8 | **Beyond parity:** staged edits — changes accumulate in a *Pending Changes* panel (diff view), then **Save** (⌘S semantics are project-level, so use **Commit to Store** ⌘↩) or **Discard**. Full undo/redo before commit. | P0 |
| EDT-9 | **Beyond parity:** automatic backup of `.sqlite` + `-wal` + `-shm` before the first commit of a session (retention configurable). | P0 |
| EDT-10 | **Beyond parity:** live-process guard — detect that the owning app is running (simulator process / Mac app) and warn that its in-memory context won't see edits until refetch/relaunch; offer "Terminate app in Simulator". | P1 |
| EDT-11 | **Beyond parity:** CloudKit guard — detect `NSPersistentCloudKitContainer` stores (mirroring tables present) and warn that committed edits will be exported to iCloud on next app launch. | P0 |
| EDT-12 | Transformable attributes: view-only in v1; editable when the decoded value is a plist/JSON-compatible type. | P2 |

### 6.6 Field content viewer

| ID | Requirement | Pri |
|---|---|---|
| CNT-1 | Bottom panel zooms into one field of the selected row (main grid or relationship grid). Auto-detects: plain text, **JSON**, **XML**, **HTML**, **RTF**, **property list** (XML + binary), URLs → web page or image, images (PNG/JPEG/GIF/HEIC/WebP/TIFF/SVG), audio/video (MP4/MOV/M4A), PDF, **gzip/zlib-compressed** payloads (auto-inflate then re-detect). | P0 |
| CNT-2 | Mode switcher: Rendered / Text (pretty-printed, syntax highlighted, foldable tree for JSON/plist) / Hex. | P0 |
| CNT-3 | HTML content: WKWebView preview with Web Inspector enabled. Remote loads are **off by default** per project (privacy), one click to allow. | P1 |
| CNT-4 | **Beyond parity:** `NSKeyedArchiver` decoding *without the app's classes* — render the archive as an object tree with class names (covers most transformables, `NSAttributedString`, `UIColor`, custom `NSSecureCoding` types). | P0 |
| CNT-5 | **Beyond parity:** Codable-JSON blobs, Protobuf-ish/unknown binary → hex + strings view; size and SHA-256; "Save As…", "Open With…", Quick Look. | P1 |

### 6.7 Relationships viewer

| ID | Requirement | Pri |
|---|---|---|
| REL-1 | Bottom-left panel lists the selected object's relationships (with counts); choosing one shows related objects in a grid. Selecting a related object shows it in the inspector and content viewer. | P0 |
| REL-2 | Non-inverse (one-directional) relationships, ordered relationships (show order index), many-to-many. | P0 |
| REL-3 | **Beyond parity:** drill-through navigation — "Reveal in Entity" jumps the main grid to the related object; browser-style **Back/Forward** (⌘[ / ⌘]) and a breadcrumb trail (`Order #12 › customer › orders`). | P0 |
| REL-4 | **Beyond parity:** "Referenced by" — find all objects pointing at this object across all inverse-less relationships. | P1 |

### 6.8 Model diagrams

| ID | Requirement | Pri |
|---|---|---|
| DGM-1 | Multiple named diagrams per project. Entity boxes with attributes (type labels optional), relationship lines with cardinality (to-one/to-many arrowheads), inheritance lines, non-inverse lines in a distinct style. | P1 |
| DGM-2 | Drag to position, hide/unhide entities, Redraw (auto-layout), Reset, Rename, Duplicate, Delete. "Focus on entity" = show entity + N-hop neighbours. | P1 |
| DGM-3 | Copy as vector to clipboard; export PDF. Option to include/exclude background grid. | P1 |
| DGM-4 | Settings: center names, bold/sort-first non-optional attributes, font size, box width, grid size, line colors. | P2 |
| DGM-5 | **Beyond parity:** export **SVG, PNG, Mermaid `erDiagram`, DOT**; click entity → jump to its data; overlay row counts. | P1 |

### 6.9 Import and export

| ID | Requirement | Pri |
|---|---|---|
| IMX-1 | Export selected rows / current view / whole entity to **CSV** (separator choice, header row) and **JSON**. JSON optionally includes relationship data (depth-limited, cycle-safe) and composite attributes. Dates ISO 8601, binary Base64. | P0 |
| IMX-2 | Import **CSV** and **JSON** into the selected entity under model validation; per-row error report; dry-run preview; all-or-nothing or skip-invalid mode. | P1 |
| IMX-3 | Column-mapping UI for CSV (map/ignore columns, type coercion preview). | P1 |
| IMX-4 | **Beyond parity:** relationships of any cardinality on import; link to existing objects by uniqueness-constraint key or object ID URI instead of always creating children. Upsert mode when the entity has a uniqueness constraint. | P1 |
| IMX-5 | **Beyond parity:** export whole store as JSON bundle, SQL dump (raw), or **Swift seed code** (Core Data or SwiftData insert statements) for previews/tests. | P2 |

### 6.10 Settings (app-level)

General (default access mode, time zone, date format) · Access Permissions (home dir, app search dir, database search dir — with re-grant buttons) · Search (extensions, excluded dirs) · Tables (font size, striping, multi-select) · Tracking (colors, debounce, max retained versions) · Content viewer (remote content policy) · Diagrams · Performance (lazy loading, default sort, fetch limit) · Backups (location, retention) · Advanced (allow cached model, automatic update checks).

---

## 7. New features (differentiators)

### 7.1 Text predicate mode — P0
A code field beside the visual builder: type `age > 30 AND ANY orders.total > 100`, with key-path autocomplete from the model, live parse errors (caught safely — `NSPredicate(format:)` throws ObjC exceptions), and round-tripping to the visual builder whenever the predicate is representable there.

### 7.2 SQL console — P1
Read-only SQLite console against the same store.
- **Name mapping**: write `SELECT name FROM Person` and we rewrite to `ZNAME`/`ZPERSON`; results map back (dates decoded, `Z_ENT` → entity name). Toggle to see the raw SQL.
- `EXPLAIN QUERY PLAN` view — check whether a fetch index is actually used.
- Saved snippets in the project. Hard read-only connection (`SQLITE_OPEN_READONLY` + `PRAGMA query_only`).

### 7.3 Snapshots, restore and diff — P0 (snapshots/restore), P1 (diff)
- **Snapshot**: consistent copy of the store (SQLite backup API; includes external-data folder) with name + note, stored beside the project or in a shared library.
- **Restore**: put a snapshot back into the simulator/Mac container (guard: app must not be running; offers to terminate via `simctl`). This turns bug reproduction and screenshot staging into one click.
- **Diff**: snapshot ↔ live store, snapshot ↔ snapshot, or any two compatible stores: per-entity added/removed/changed counts → row-level → field-level diff. Export as JSON/Markdown report.
- **Scenarios** (P2): named snapshots exposed to the CLI for UI-test setup (`dabbi restore "Empty cart" --booted`).

### 7.4 Persistent History timeline — P1
For stores with `NSPersistentHistoryTracking`: transactions listed by time with author, context name, bundle ID, process; expand to see inserted/updated/deleted objects and updated properties, tombstones; filter by author/entity; jump to object. Essential for debugging app-extension/widget sync and CloudKit mirroring.

### 7.5 Physical device container pull — P1
List paired devices and installed **development-signed** apps (`xcrun devicectl`), pull the app data container to a temp `.xcappdata`-like folder, open it as a project; "Refresh from device" re-pulls and diffs against the previous pull. Read-only (no push-back in v1).

### 7.6 Model tools — P1
- **Model version diff**: compare two `.mom` versions (or bundle model vs store's cached model): added/removed/changed entities, attributes, relationships; hash changes.
- **Migration check**: report whether Core Data can infer a lightweight mapping (`NSMappingModel.inferredMappingModel`) and, if not, why.
- **Codegen** (P2): generate `NSManagedObject` subclasses or SwiftData `@Model` classes from the loaded model — handy for Core Data → SwiftData migrations.

### 7.7 Store Doctor and statistics — P1
- **Statistics**: row counts, table/index bytes (`dbstat`), largest blobs, WAL size, external-data folder size, per-attribute null ratio and distinct counts.
- **Doctor**: `PRAGMA integrity_check`; rows violating current model validation; dangling foreign keys; inverse-relationship mismatches; orphaned external-data files; uniqueness-constraint duplicates; `Z_PRIMARYKEY.Z_MAX` drift. Each finding links to the offending rows.

### 7.8 Automation: CLI, URL scheme, MCP server — P1
- `dabbi` CLI (same engine): `dabbi stores --booted`, `dabbi query Person --where 'age > 30' --json`, `dabbi export`, `dabbi snapshot`, `dabbi restore`, `dabbi diff`, `dabbi open --bundle-id com.acme.app --booted` (launches the GUI on the right store).
- URL scheme `coredatadabbi://open?bundleId=…&device=booted&entity=Person`.
- **MCP server** (`dabbi mcp`): read-only tools — list stores, describe model, fetch with predicate, get object, recent changes — so coding agents (Claude Code, Xcode's assistant) can verify what the app persisted. Writes are never exposed over MCP in v1.

### 7.9 Global search — P1
⌘⇧F: search a string/number/UUID across all entities and attributes; results grouped by entity; streaming, cancellable.

### 7.10 Natural-language queries — P2
"orders over $100 from last week with no customer" → predicate, using Apple's on-device Foundation Models where available. On-device only; the generated predicate is always shown and editable; feature hidden when the model isn't available.

### 7.11 Smaller quality-of-life wins
- Auto-follow: when the booted simulator's frontmost app has a known store, offer "Open its store" (P2).
- Pin/bookmark objects and add notes per object in the project (P2).
- Seed data generator: N fake objects per entity respecting validation rules (P2).
- CloudKit mirroring inspector: record names/zones, export state per object (P2).

---

## 8. UX specification

### 8.1 Main document window

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ ◀ ▶  ▶ Track   ⌕ Filter   🔒 Read-only   [ AppIcon  MyApp › iPhone 17 › default.store · Cached model ]   ⓘ │
├────────────┬─────────────────────────────────────────────────┬────────────────┤
│ ENTITIES   │  breadcrumb: Order › customer                   │ INSPECTOR      │
│  Customer 1.2k│ ┌ predicate editor (collapsible) ───────────┐ │ [Details|Entity]│
│  Order   48k │ └────────────────────────────────────────────┘ │ name   Anand   │
│  ▸ Payment   │  id │ name │ createdAt │ total │ customer │…   │ total  129.00  │
│ FETCH REQS │  …main grid…                                    │ …              │
│ PREDICATES │                                                 │                │
│ DIAGRAMS   ├───────────────────────────┬─────────────────────┤                │
│ SNAPSHOTS  │ RELATIONSHIPS  items (7) ▾│ CONTENT  [Rendered|Text|Hex]         │
│ SQL        │  …related rows grid…      │  { "sku": "A-1", … }                 │
│ [filter…]  │                           │                                      │
└────────────┴───────────────────────────┴─────────────────────┴────────────────┘
```

- Status capsule shows app icon, store path (click = path menu / Reveal in Finder), model source, access mode; double-click zooms the window.
- All panes collapsible; layout saved per project.
- Empty/error states are instructive: missing store → what we looked for and where; incompatible model → which entities differ.

### 8.2 Menus (top level)
**File** (New Project ▸ Assistant / Browse Simulators / Browse Devices / Select App / Select Model / Select Database; Open Database; Open Container; Project Settings; Store Metadata) · **Edit** (Undo/Redo, Copy As ▸, Invert Selection, Find) · **View** (panes, Show All Columns, Grid Font Size, Time Zone) · **Project** (Search Database, Search App, Snapshots ▸, Doctor, Statistics) · **Data** (Track Changes, New Object, Delete, Batch Update, Find and Replace, Nullify, Commit/Discard, Import ▸, Export ▸) · **Diagram** · **Window** · **Help**.

### 8.3 Key shortcuts
⌘R track · ⌘F quick filter · ⌥⌘F predicate editor · ⌘⇧F global search · ⌘[ / ⌘] back/forward · ⌘↩ commit · ⌥⌘0 inspector · ⌘N new object (when editable) · Space Quick Look on binary field.

### 8.4 Accessibility
VoiceOver labels on grid cells incl. tracking state; tracking states have glyphs as well as color; WCAG AA contrast in both appearances; Reduce Motion honored; full keyboard navigation.

---

## 9. Technical approach

### 9.1 Stack
- Swift 6, **macOS 14+** (composite attributes and SwiftData exist from 14). Universal binary.
- SwiftUI for chrome, settings, wizards; **AppKit** for the heavy controls: `NSTableView` grids, `NSOutlineView` sidebar, `NSPredicateEditor`-based builder (custom row templates), diagram canvas.
- `NSDocument` architecture (tabs, autosave, versions).
- One engine package, three front ends:

```
DabbiKit (Swift package, no UI)
 ├─ StoreLocator      simulators, devices, containers, search, SwiftData conventions
 ├─ ModelLoader       .mom/.momd, Z_MODELCACHE, hash matching, model sanitizing
 ├─ StoreSession      Core Data stack (read-only / writable), staged edits, backups
 ├─ RawSQLite         read-only connection: raw mode, SQL console, stats, history tables
 ├─ ChangeTracker     file watching + diff engine + history enrichment
 ├─ QueryEngine       predicates, fetch templates, global search, code generation
 ├─ ImportExport      CSV/JSON/seed code
 ├─ Snapshots         backup API copy, restore, store diff
 └─ ContentDecoders   type sniffing, keyed-archive tree, inflate, plist/JSON
Apps: CoreDataDabbi.app · dabbi (CLI) · dabbi mcp (MCP server)
```

### 9.2 Loading a model without the app's code
1. Source priority: user-selected model → matching model in app bundle → store's `Z_MODELCACHE` (keyed archive, possibly compressed).
2. **Sanitize a mutable copy** before use: set every entity's `managedObjectClassName` to `NSManagedObject`; replace unknown `valueTransformerName`s with a pass-through transformer that hands us raw `Data` (decoded later by `ContentDecoders`, never by instantiating app classes); keep version hashes intact (class names/transformers don't affect hashes — verify in tests).
3. Verify compatibility with `isConfiguration(withName:compatibleWithStoreMetadata:)`; on mismatch, compute per-entity hash diff for the error UI.
4. All access through KVC on `NSManagedObject`; composite attributes as dictionaries.

### 9.3 Opening stores safely
- Default: `NSReadOnlyPersistentStoreOption`, no migration options, never infer mapping.
- Writable: same sanitised model; enable `NSPersistentHistoryTrackingKey` iff history tables exist (otherwise Core Data forces read-only); never toggle it on for stores that don't have it.
- Raw connection is separate, `SQLITE_OPEN_READONLY`, `query_only`, short-lived read transactions so we never block the app's WAL checkpoints.
- Detect & label: CloudKit-mirrored stores, encrypted/unsupported stores (SQLCipher → clear message), non-Core-Data SQLite → raw mode.

### 9.4 Change tracking design
- Watch `store`, `store-wal`, `store-shm` with `DispatchSource` file-system sources + an FSEvents watch on the directory (files get recreated on checkpoint/reinstall). Debounce ~150 ms.
- On change, per tracked entity: `SELECT Z_PK, Z_OPT FROM <table>` (cheap; `Z_OPT` is Core Data's optimistic-lock counter and increments on every update). Compare with the previous map → inserted / deleted / `Z_OPT`-bumped PKs → fetch only those rows → field-level diff against cached values → append version rows.
- To-many changes without a `Z_OPT` bump on the other side: also diff join tables (`Z_nREL`) for tracked relationships.
- If persistent history exists, read transactions after the last seen token from the history tables to add author/context and to cross-check.
- Memory budget: cap retained versions (default 10k rows), spill older ones to a temp SQLite file.
- Predicate views: evaluate the predicate in-memory on changed objects to flag enter/leave.

### 9.5 Simulator and device discovery
- `xcrun simctl list -j devices` for names/runtimes/state; fall back to parsing `~/Library/Developer/CoreSimulator/Devices/*/device.plist` if Xcode tools are missing.
- Map apps ↔ data containers via `.com.apple.mobile_container_manager.metadata.plist` (bundle ID) under `data/Containers/{Bundle,Data,Shared}`; scan data + app-group containers for SQLite files with `Z_METADATA`.
- Cache an index per device; refresh with FSEvents.
- Devices: `xcrun devicectl list devices`, `devicectl device info apps`, `devicectl device copy from --domain-type appDataContainer`. Requires Xcode 15+; feature hidden otherwise.

### 9.6 Project file format
`.dabbi` package: `project.json` (schema-versioned), `bookmarks/`, `diagrams/*.json`, `sql/*.sql`, `snapshots/index.json` (+ optional snapshot payloads). JSON so it diffs well and can be committed to a repo; an option stores machine-specific bookmarks outside the package so teams can share predicates/diagrams.

### 9.7 Distribution and sandboxing
- **Primary: GitHub Releases** — Developer ID signed + notarized `.dmg`, non-sandboxed, Sparkle updates fed from an appcast generated by the release workflow. Rationale: simulator browsing, device pulls (`xcrun`), restore-into-container and the CLI are far simpler and more reliable outside the sandbox.
- **Homebrew**: `brew install --cask coredatadabbi` for the app, a formula for the `dabbi` CLI.
- **Build from source** must work with a free Apple ID (ad-hoc signing, no entitlements that need a paid team). Signing identity and notarization credentials live only in CI secrets.
- **Optional (P2): free Mac App Store build**, sandboxed, with security-scoped bookmarks for home/search directories (an Access Permissions pane like the reference product) and reduced features (no `devicectl`, CLI installed separately). Only if the license choice allows it (§14).
- Hardened runtime; no network entitlement needed except for optional remote content in the content viewer and update checks.
- Cost note: notarization requires one Apple Developer Program membership ($99/yr) held by the maintainer — the project's only fixed cost.

### 9.8 Privacy and security
- No analytics, no third-party SDKs phoning home. Crashes are reported by the user: a "Report a Problem…" item prepares a GitHub issue with the local crash log and environment info (never row data) for the user to review and submit.
- Web content sandboxed in WKWebView with JavaScript limited to the previewed document; remote loads opt-in.
- Keyed archives are *parsed*, never unarchived into arbitrary classes.
- MCP/CLI read-only by default; write commands require `--allow-writes` and never run over MCP.

---

## 10. Non-functional requirements

| Area | Target |
|---|---|
| Open to first rows | < 1 s for a 100 MB store; < 2 s for 1 GB (M-series) |
| Grid | 60 fps scroll on a 1M-row entity (batched faulting, cell reuse, no per-cell fetch) |
| Tracking latency | < 500 ms from app `save()` to highlighted row |
| Tracking overhead | No observable slowdown of the inspected app; no write locks taken |
| Memory | < 300 MB typical; bounded tracking history |
| Simulator index | First full scan < 3 s with 30 devices; incremental afterwards |
| Reliability | Zero store corruption in fuzz/soak tests; every commit preceded by verified backup |
| Compatibility | Stores written by iOS 13+ / macOS 10.15+ era Core Data; SwiftData from iOS 17; Xcode 15+ for device features |
| Localization | English at launch; all strings externalised |

## 11. Test strategy
- **Fixture zoo**: generated stores covering every attribute type, inheritance, ordered/many-to-many/non-inverse relationships, composites, derived attributes, external storage, history tracking, CloudKit mirroring, SwiftData (incl. enums/Codable structs), large (1M rows), WAL-only changes, old model caches.
- A **sample writer app** (macOS + iOS simulator targets) that mutates data on a script, used to verify tracking end-to-end in CI.
- Unit tests on `DabbiKit`; snapshot tests for decoders; UI tests for critical flows (open from simulator, track, edit+commit, import/export round trip).
- Soak test: tracker attached for hours to a busy writer; assert no locks, leaks, or missed changes.
- CI on GitHub Actions macOS runners: build + `DabbiKit` tests on every PR (no signing needed); the fixture zoo is generated by a script in the repo, not committed as binaries, so contributors can regenerate and extend it.

---

## 12. Release plan

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0 Foundations** | Public repo (LICENSE, README, CONTRIBUTING, code of conduct, issue/PR templates, CI), `DabbiKit` skeleton, ModelLoader (bundle + cached), read-only StoreSession, fixture zoo, sample writer app | Can load every fixture headlessly; PR CI green |
| **M1 Viewer** | Document window, sidebar, grid, inspector (details + entity description), relationships panel, content viewer (text/JSON/plist/image/keyed-archive), Open Database, Simulator browser, SwiftData detection | Daily-drivable read-only viewer |
| **M2 Query + Track** | Predicate builder + text mode, saved predicates with column configs, fetch templates, change tracker (incl. predicate/read-only tracking), project auto-repair | Tracking demo works against simulator app |
| **M3 Edit + Exchange** | Access mode, staged edits, validation UI, backups, batch ops, CloudKit/live-process guards, CSV/JSON export + import | Round-trip import/export; zero-corruption soak |
| **M4 Parity polish → 1.0** | Diagrams, Project Assistant, app/database search, `.xcappdata`, raw SQLite mode, store metadata, settings, welcome window, docs site, release workflow (notarized `.dmg` + Sparkle appcast + Homebrew cask) | Parity checklist (§6 P0+P1) green |
| **M5 → 1.1** | Snapshots/restore/diff, SQL console, Persistent History timeline, global search | |
| **M6 → 1.2** | CLI + URL scheme + MCP server, device pull, Doctor + statistics, model diff/migration check | |
| **Later** | Optional free MAS build, NL queries, codegen, seed generator, CloudKit inspector, scenarios | |

**MVP cut (if we need something usable fastest):** M1 + tracker from M2.

## 13. Success metrics
- Time from launch → seeing rows of a simulator app's store: **< 15 s, ≤ 3 clicks** for a first-time user.
- Zero confirmed data-corruption reports; crash issues triaged within a week.
- Since we collect no telemetry, adoption is measured from public signals only: GitHub stars, release download counts, Homebrew install analytics, issues/discussions volume.
- Community health: first external PR merged within 3 months of going public; ≥ 5 outside contributors in year one; median time-to-first-response on issues < 3 days.
- Ecosystem: at least one third-party tool or script built on `DabbiKit`/the CLI/the MCP server.

## 14. Open-source model
CoreDataDabbi is free and open source: all features for everyone, no trial, no paid tier, no accounts.

- **License — recommendation: MIT** for the whole repo (app, `DabbiKit`, CLI, MCP server). It maximises adoption and reuse of the engine, matches the norm for Swift developer tools, and keeps a Mac App Store build possible. Trade-off: anyone can repackage and sell it; we mitigate with the name/icon (kept as project trademarks, excluded from the license grant) rather than with copyleft. Alternative if resale worries us more than reuse: GPLv3 for the app + MIT for `DabbiKit` (note GPL conflicts with MAS distribution terms).
- **Dependencies** must be permissively licensed (MIT/BSD/Apache-2.0) and few: Sparkle, swift-argument-parser, an MCP Swift SDK; prefer the system SQLite over bundling one.
- **Governance**: maintainer-led (BDFL) to start; decisions in public GitHub issues/discussions; this PRD and the roadmap live in the repo; feature IDs here become issue labels/milestones. No CLA — DCO sign-off (`git commit -s`) only.
- **Contribution surface designed in**: `DabbiKit` is UI-free and unit-testable; content decoders, exporters and Doctor checks are small protocol-based plug-points so a first PR can be one new file plus a fixture.
- **Sustainability**: GitHub Sponsors link, nothing gated behind it. The only fixed cost is the Apple Developer membership for notarization.
- **Security policy**: `SECURITY.md` with private vulnerability reporting — the app opens untrusted database files and renders their contents, so decoder/web-view bugs are security-relevant.

## 15. Risks

| Risk | Mitigation |
|---|---|
| Private on-disk details (`Z_MODELCACHE` encoding, `Z_OPT`, history tables) change between OS releases | Isolate in `RawSQLite`/`ModelLoader` behind version probes; fixture stores per OS release in CI; degrade to Core Data-only paths |
| Writing under a live app causes confusion or conflicts | Read-only default, staged commits, live-process + CloudKit guards, auto-backup |
| Sanitising the model changes version hashes | Tests assert hash equality; fall back to store-cached model |
| Unknown transformers / secure-coding classes | Never unarchive; parse keyed archives structurally |
| `devicectl` output/behaviour changes | JSON output mode only; feature-flagged; graceful absence |
| Sandboxed MAS build cripples key features | Ship via GitHub/Homebrew first; MAS is an optional reduced build |
| Perception as a knock-off of a paid indie app | Distinct brand/UI; clean-room rule (§1); lead with differentiators (snapshots, history, automation); credit the reference product as inspiration in the README |
| Maintainer bandwidth — a parity-plus scope is large for a volunteer project | Ruthless milestone order (MVP = M1 + tracker); engine-first architecture so contributors can own vertical slices; "good first issue" plug-points |
| Third parties repackage and sell the app | Trademarked name/icon excluded from the license; official builds only from GitHub/Homebrew |

## 16. Open questions
1. License: MIT everywhere (proposed) vs GPLv3 app + MIT engine (see §14)?
2. Minimum OS: macOS 14 (proposed) or 15 to simplify SwiftUI/Observation usage?
3. Should restore-to-simulator also support pushing to physical devices later (`devicectl … copy to`)?
4. Do we want team features (shared project files in the app repo) in 1.0, or just keep the format friendly to it?
5. Name/trademark check for "CoreDataDabbi" / "Dabbi"; avoid "Core Data" as a leading mark if Apple's guidelines object.

---

## Appendix A — Parity checklist vs Core Data Lab

| Core Data Lab capability | Our ID(s) |
|---|---|
| Project documents (NSDocument, tabs, autosave) | PRJ-1, PRJ-2 |
| Project assistant | PRJ-10 |
| Select app/model → search database; select database → search app | PRJ-4, PRJ-5, PRJ-6, PRJ-7 |
| Simulator browser (iOS, iPadOS, watchOS, tvOS, visionOS) | PRJ-8 |
| Open database with cached model | PRJ-3 |
| `.xcappdata` containers | PRJ-9 |
| SwiftData apps and stores | PRJ-11 |
| Auto-repair of moved simulator stores; deleted-file detection | PRJ-12 |
| Raw SQLite viewer, Finder integration, DDL structure tab | PRJ-13, BRW-8 |
| Store metadata | PRJ-14 |
| Entities / fetch requests / saved predicates sidebar with filter | BRW-1 |
| Grid with column reorder/hide/sort, persisted with predicates | BRW-3 |
| Composite attributes (view, sort, filter, export/import, track) | BRW-4, PRD-2, IMX-1, TRK-2 (+ editing: EDT-7) |
| Details inspector + detail windows | BRW-7, BRW-9 |
| Entity description (attributes, relationships, indexes, constraints) | BRW-8 |
| Data change tracker with colored version rows, export | TRK-1…TRK-6 |
| Predicate editor, save/duplicate, copy as text/Swift/ObjC | PRD-1…PRD-5 |
| Data editor with model validation; batch update / find-replace / nullify | EDT-1…EDT-4 |
| NSPersistentHistoryTracking project setting | EDT-5 |
| Field content viewer (HTML, XML, RTF, PLIST, JSON, URLs, images, media, gzip) + web debugger | CNT-1…CNT-3 |
| Save binary field to file | EDT-6 |
| Relationships viewer incl. non-inverse | REL-1, REL-2 |
| Model diagrams, PDF export, clipboard copy, settings | DGM-1…DGM-4 |
| CSV/JSON import/export with relationships | IMX-1…IMX-3 |
| Performance settings (lazy loading, default sort) | BRW-11 |
| Grid font size, invert selection, tracking colors, access permissions | BRW-10, TRK-4, §6.10 |

## Appendix B — Sources
- Product page: https://betamagic.nl/products/coredatalab.html
- Help / Tips and Tricks: https://betamagic.nl/support/coredatalab/help.html
- Release notes: [1.2](https://betamagic.nl/news/2020/2020_07.html) · [1.6](https://betamagic.nl/news/2021/2021_01.html) · [2.3](https://betamagic.nl/news/2023/2023_02.html) · [2.4](https://betamagic.nl/news/2023/2023_05.html)
- Mac App Store listing: https://apps.apple.com/us/app/core-data-lab/id1460684638
- Other tools in the space: [Core Data Editor (open source, unmaintained)](https://github.com/ChristianKienle/Core-Data-Editor), [CoreData Studio](https://apps.apple.com/us/app/coredata-studio-sql-manager/id6670322925)
