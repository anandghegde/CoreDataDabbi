// DabbiExchange — CSV and JSON export and import (docs/ARCHITECTURE.md §6.9).
//
// Export (IMX-1, BRW-12, TRK-5): `ExportReader` reads records out of a `StoreSession` — a selection, a fetch, a
// whole entity — following relationships as far as `ExportOptions` says, and hands them one at a time to an
// `Exporter`, which only turns records into text: `CSVExporter` (and TSV), `JSONExporter`,
// `MarkdownTableExporter`. `TrackedSessionExport` does the same for a tracker's version log.
//
// Import (IMX-2 – IMX-4): `ImportTable` and `JSONNode` parse a file, `ImportMapping` maps its columns onto an
// entity's properties and coerces the text with `ValueText`, and the rows it makes are staged by
// `StoreSession.importRows` — dry run first, then as one undoable edit that Commit writes like any other.
//
// Values never reach a log or an error message from here: errors say where (a line, a column name), never what.
