#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The error domain of errors produced from caught Objective-C exceptions.
FOUNDATION_EXPORT NSErrorDomain const DBExceptionErrorDomain;
/// `userInfo` key holding the `NSException`'s name.
FOUNDATION_EXPORT NSErrorUserInfoKey const DBExceptionNameKey;
/// `userInfo` key holding the `NSException`'s reason.
FOUNDATION_EXPORT NSErrorUserInfoKey const DBExceptionReasonKey;

/// Runs `block` and converts an `NSException` raised inside it into an `NSError`.
///
/// Swift cannot catch Objective-C exceptions, yet `NSPredicate(format:)`, fetches with bad key paths and KVC on
/// unknown keys raise them. Keep the guarded block tiny — ideally a single Foundation or Core Data call — because
/// unwinding through Swift frames is not memory-safe in general.
///
/// Returns `NO` and sets `error` when an exception was caught. Swift callers use `objcGuarded` in `DabbiBase`.
BOOL DBTryCatch(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
