//
//  PBChangedFile.h
//  GitX
//
//  Created by Pieter de Bie on 22-09-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PBChangedFileStatus) {
	NEW,
	MODIFIED,
	DELETED
};

@interface PBChangedFile : NSObject {
	NSString *path;
	NSData *rawPath;
	BOOL hasStagedChanges;
	BOOL hasUnstagedChanges;

	// Index and HEAD stuff, to be used to revert changes
	NSString *commitBlobSHA;
	NSString *commitBlobMode;

	PBChangedFileStatus status;
	PBChangedFileStatus stagedStatus;
	PBChangedFileStatus worktreeStatus;
}


@property (copy) NSString *path;
@property (copy, readonly) NSData *rawPath;
@property (copy, readonly, nullable) NSString *safePath;
@property (copy, nullable) NSString *commitBlobSHA;
@property (copy, nullable) NSString *commitBlobMode;
@property (assign) PBChangedFileStatus status;
@property (assign) PBChangedFileStatus stagedStatus;
@property (assign) PBChangedFileStatus worktreeStatus;
@property (assign) BOOL hasStagedChanges, hasUnstagedChanges;

- (nullable NSImage *)icon;
- (nullable NSImage *)stagedIcon;
- (nullable NSImage *)worktreeIcon;

- (instancetype)initWithPath:(NSString *)p;
- (instancetype)initWithPath:(NSString *)displayPath rawPath:(NSData *)pathBytes;
@end

NS_ASSUME_NONNULL_END
