//
//  PBDiffWindowController.h
//  GitX
//
//  Created by Pieter de Bie on 13-10-08.
//  Copyright 2008 Pieter de Bie. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class PBGitCommit;

NS_ASSUME_NONNULL_BEGIN

@interface PBDiffWindowController : NSWindowController

+ (void)showDiff:(NSString *)diff;
+ (void)showDiffWindowWithFiles:(nullable NSArray *)filePaths
					 fromCommit:(PBGitCommit *)startCommit
					 diffCommit:(nullable PBGitCommit *)diffCommit;
- (instancetype)initWithDiff:(NSString *)diff;

@property (readonly) NSString *diff;
@property (readonly, nullable) PBGitCommit *startCommit;
@property (readonly, nullable) PBGitCommit *diffCommit;
@end

NS_ASSUME_NONNULL_END
