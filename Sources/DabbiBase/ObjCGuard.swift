import DabbiObjC
import Foundation

/// Runs `body` and turns an Objective-C exception raised inside it into a `DabbiError`.
///
/// Swift cannot catch `NSException`, yet `NSPredicate(format:)`, fetches with bad key paths and KVC on unknown
/// keys raise them. Keep `body` tiny — ideally one Foundation or Core Data call — because unwinding through
/// Swift frames is not memory-safe in general.
///
/// - Parameters:
///   - message: What failed, in the user's terms.
///   - code: The code of the error thrown for an exception. Swift errors thrown by `body` pass through as is.
public func objcGuarded<T>(
    _ message: @autoclosure () -> String,
    code: DabbiError.Code = .objcException,
    _ body: () throws -> T
) throws -> T {
    var result: Result<T, any Error>?
    var exception: NSError?
    let completed = DBTryCatch({ result = Result { try body() } }, &exception)
    if !completed {
        let nsError = exception ?? NSError(domain: DBExceptionErrorDomain, code: 0)
        let name = nsError.userInfo[DBExceptionNameKey] as? String
        let reason = nsError.userInfo[DBExceptionReasonKey] as? String
        var arguments: [String: String] = [:]
        if let name { arguments["exception"] = name }
        throw DabbiError(
            code,
            message(),
            arguments: arguments,
            diagnosis: reason.map { [$0] } ?? [],
            underlying: nsError
        )
    }
    guard let result else {
        throw DabbiError(.internal, "A guarded call finished without a result.")
    }
    return try result.get()
}
