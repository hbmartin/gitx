//
//  PBGitRevSpecifier.h
//  GitX
//
//  Created by Pieter de Bie on 12-09-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>
@class PBGitRef;

NS_ASSUME_NONNULL_BEGIN

@interface PBGitRevSpecifier : NSObject <NSCopying> {
	NSString *_Nullable description;
	NSArray<NSString *> *parameters;
	NSURL *_Nullable workingDirectory;
	BOOL isSimpleRef;
}

- (instancetype)initWithParameters:(NSArray<NSString *> *)params description:(nullable NSString *)descrip;
- (instancetype)initWithParameters:(NSArray<NSString *> *)params;
- (instancetype)initWithRef:(PBGitRef *)ref;

- (nullable NSString *)simpleRef;
- (nullable PBGitRef *)ref;
- (BOOL)hasPathLimiter;
- (NSString *)title;

- (BOOL)isEqual:(nullable PBGitRevSpecifier *)other;
- (BOOL)isAllBranchesRev;
- (BOOL)isLocalBranchesRev;

+ (PBGitRevSpecifier *)allBranchesRevSpec;
+ (PBGitRevSpecifier *)localBranchesRevSpec;

@property (nullable, retain) NSString *description;
@property (readonly) NSArray<NSString *> *parameters;
@property (nullable, retain) NSURL *workingDirectory;
@property (readonly) BOOL isSimpleRef;

@end


NS_ASSUME_NONNULL_END
