//
//  PBChangedFile.h
//  GitX
//
//  Created by Pieter de Bie on 22-09-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>

typedef enum {
	NEW,
	MODIFIED,
	DELETED
} PBChangedFileStatus;

NS_ASSUME_NONNULL_BEGIN

@interface PBChangedFile : NSObject {
	NSString *path;
	BOOL hasStagedChanges;
	BOOL hasUnstagedChanges;

	// Index and HEAD stuff, to be used to revert changes
	NSString *commitBlobSHA;
	NSString *commitBlobMode;

	PBChangedFileStatus status;
}


@property (copy) NSString *path;
@property (copy, nullable) NSString *commitBlobSHA;
@property (copy, nullable) NSString *commitBlobMode;
@property (assign) PBChangedFileStatus status;
@property (assign) BOOL hasStagedChanges, hasUnstagedChanges;

- (nullable NSImage *)icon;

- (instancetype)initWithPath:(NSString *)p;
@end

NS_ASSUME_NONNULL_END
