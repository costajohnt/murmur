#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C `@try/@catch` so an `NSException`
/// raised by a framework (notably `-[AVAudioNode installTapOnBus:...]`)
/// becomes a Swift `Error` instead of aborting the process. Swift's own
/// `do/catch` cannot intercept ObjC exceptions, so the catch has to live in
/// an ObjC frame directly around the raising call.
///
/// Returns YES on success. On an exception it returns NO and, when `error`
/// is non-NULL, fills it with an NSError carrying the exception's name and
/// reason.
BOOL MurmurCatchNSException(void (NS_NOESCAPE ^block)(void), NSError **error);

NS_ASSUME_NONNULL_END
