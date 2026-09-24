import DabbiBase

extension WriteAuthorization {
    /// What the Mac app's saves are recorded as in a store's persistent history (EDT-5).
    public static let appAuthor = "CoreDataDabbi"

    /// The Mac app's authorization: the user unlocked the project (EDT-1).
    ///
    /// The command line will get one of its own behind `--allow-writes` (M6-01). The MCP server, which lives in
    /// the same executable, must never reach either; when it lands, these factories move to a module it does
    /// not link (ADR-12).
    public static var app: WriteAuthorization { WriteAuthorization(author: appAuthor) }
}
