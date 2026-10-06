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

@interface PBGitBinary : NSObject

+ (nullable NSString *)path;
+ (nullable NSString *)version;
+ (NSArray<NSString *> *)searchLocations;
+ (NSString *)notFoundError;
@end

NS_ASSUME_NONNULL_END
