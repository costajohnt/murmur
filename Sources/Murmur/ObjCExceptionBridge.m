#import "ObjCExceptionBridge.h"

NSString *const MurmurExceptionErrorDomain = @"com.costajohnt.murmur.ObjCException";

BOOL MurmurCatchNSException(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: @"unknown reason";
            *error = [NSError errorWithDomain:MurmurExceptionErrorDomain
                                         code:0
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", exception.name, reason]
            }];
        }
        return NO;
    }
}
