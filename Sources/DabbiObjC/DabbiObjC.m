#import "DabbiObjC.h"

NSErrorDomain const DBExceptionErrorDomain = @"org.coredatadabbi.objc-exception";
NSErrorUserInfoKey const DBExceptionNameKey = @"DBExceptionName";
NSErrorUserInfoKey const DBExceptionReasonKey = @"DBExceptionReason";

BOOL DBTryCatch(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: @"(no reason)";
            *error = [NSError errorWithDomain:DBExceptionErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : reason,
                                         DBExceptionNameKey : exception.name,
                                         DBExceptionReasonKey : reason,
                                     }];
        }
        return NO;
    } @catch (id thrown) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:DBExceptionErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey : @"A non-NSException object was thrown."}];
        }
        return NO;
    }
}
