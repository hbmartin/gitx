//
//  PBGitBinary.h
//  GitX
//
//  Created by Pieter de Bie on 04-10-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#define MIN_GIT_VERSION "1.6.0"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const PBGitMinimumVersion;
extern NSNotificationName const PBGitBinaryDidChangeNotification;
typedef void(NS_SWIFT_UI_ACTOR NS_SWIFT_SENDABLE ^ PBGitBinaryAvailabilityHandler)(NSString *_Nullable path, NSError *_Nullable error);

@interface PBGitBinary : NSObject

+ (nullable NSString *)path;
+ (nullable NSString *)version;
+ (NSArray<NSString *> *)searchLocations;
+ (NSString *)notFoundError;
/// Delivers the active validated path, or waits for initial discovery; exactly once on the main queue.
+ (void)whenAvailable:(PBGitBinaryAvailabilityHandler)completion NS_SWIFT_NAME(whenAvailable(_:));
@end

NS_ASSUME_NONNULL_END
