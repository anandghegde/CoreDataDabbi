import DabbiBase
import DabbiSQLite
import Foundation

/// What this particular file offers, found by looking rather than assuming (ARCHITECTURE.md §6.2).
///
/// Features that lean on private format knowledge ask the probe first and degrade when it says no: no history
/// tables → the history browser is off; schema map unverified → raw change detection falls back to a full
/// refresh. A failed probe is never an error by itself.
public struct FormatProbe: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Has both `Z_METADATA` and `Z_PRIMARYKEY`.
        case coreData
        /// A valid SQLite database that Core Data did not write. Raw mode only.
        case plainSQLite
    }

    public var kind: Kind
    /// `Z_MODELCACHE` exists and has content.
    public var hasModelCache: Bool
    /// The persistent history tables exist (`ATRANSACTION`, `ACHANGE`).
    public var hasHistory: Bool
    /// The `NSPersistentCloudKitContainer` mirroring tables exist (`ANSCK…`).
    public var hasCloudKitMirroring: Bool
    /// Every entity table carries `Z_OPT`, the per-row save counter change detection relies on.
    public var hasOptimisticLockColumn: Bool
    /// `Z_VERSION` from `Z_METADATA`: the store format version.
    public var storeFormatVersion: Int?
    /// Tables Core Data owns: entity tables, join tables, bookkeeping.
    public var coreDataTables: [String]
    /// Tables Core Data does not own. Visible in raw mode.
    public var otherTables: [String]

    public static func probe(_ connection: SQLiteConnection) throws -> FormatProbe {
        try connection.readTransaction {
            let tables = try connection.tableNames()
            let names = Set(tables)
            let isCoreData = names.contains("Z_METADATA") && names.contains("Z_PRIMARYKEY")
            guard isCoreData else {
                return FormatProbe(
                    kind: .plainSQLite, hasModelCache: false, hasHistory: false, hasCloudKitMirroring: false,
                    hasOptimisticLockColumn: false, storeFormatVersion: nil, coreDataTables: [],
                    otherTables: tables)
            }

            let owned = tables.filter(isCoreDataTable)
            let entityTables = owned.filter { $0.hasPrefix("Z") && !$0.hasPrefix("Z_") }
            let hasModelCache =
                try names.contains("Z_MODELCACHE")
                && (connection.scalar("SELECT length(Z_CONTENT) FROM Z_MODELCACHE LIMIT 1")?.int64 ?? 0) > 0
            let hasZOpt = try entityTables.allSatisfy { try connection.columnNames(ofTable: $0).contains("Z_OPT") }

            return FormatProbe(
                kind: .coreData,
                hasModelCache: hasModelCache,
                hasHistory: names.contains("ATRANSACTION") && names.contains("ACHANGE"),
                hasCloudKitMirroring: names.contains { $0.hasPrefix("ANSCK") },
                hasOptimisticLockColumn: !entityTables.isEmpty && hasZOpt,
                storeFormatVersion: try connection.scalar("SELECT Z_VERSION FROM Z_METADATA LIMIT 1")?.int64
                    .map(Int.init),
                coreDataTables: owned,
                otherTables: tables.filter { !isCoreDataTable($0) }
            )
        }
    }

    /// Core Data's tables are upper-case and start with `Z` (entities, joins, bookkeeping) or `A` (history and
    /// CloudKit mirroring: `ACHANGE`, `ATRANSACTION`, `ATRANSACTIONSTRING`, `ANSCK…`).
    static func isCoreDataTable(_ name: String) -> Bool {
        guard name == name.uppercased() else { return false }
        if name.hasPrefix("Z") { return true }
        return ["ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"].contains(name) || name.hasPrefix("ANSCK")
    }

    /// The error for opening a non-Core Data database as a store.
    public static func notCoreDataError(at url: URL) -> DabbiError {
        DabbiError(
            .notCoreData,
            "\(url.lastPathComponent) is an SQLite database, but not a Core Data store.",
            arguments: ["path": url.path],
            diagnosis: ["Core Data's bookkeeping tables (Z_METADATA, Z_PRIMARYKEY) were not found."],
            recovery: ["Open it in raw mode to browse its tables."]
        )
    }
}
