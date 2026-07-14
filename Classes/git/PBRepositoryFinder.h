//
//  PBRepositoryFinder.h
//  GitX
//
//  Created by Rowan James on 13/11/2012.
//
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PBRepositoryFinder : NSObject

+ (nullable NSURL *)fileURLForURL:(NSURL *)inputURL;
+ (nullable NSURL *)workDirForURL:(NSURL *)fileURL;
+ (nullable NSURL *)gitDirForURL:(NSURL *)fileURL;

@end

NS_ASSUME_NONNULL_END
