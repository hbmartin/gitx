//
//  PBChangedFile.m
//  GitX
//
//  Created by Pieter de Bie on 22-09-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import "PBChangedFile.h"
#import "GitX-Swift.h"

@implementation PBChangedFile

@synthesize hasStagedChanges, hasUnstagedChanges, commitBlobSHA, commitBlobMode;

+ (NSSet<NSString *> *)keyPathsForValuesAffectingRawPath
{
	return [NSSet setWithObject:@"path"];
}
+ (NSSet<NSString *> *)keyPathsForValuesAffectingSafePath
{
	return [NSSet setWithObject:@"rawPath"];
}
+ (NSSet<NSString *> *)keyPathsForValuesAffectingIcon
{
	return [NSSet setWithObject:@"status"];
}
+ (NSSet<NSString *> *)keyPathsForValuesAffectingStagedStatus
{
	return [NSSet setWithObject:@"status"];
}
+ (NSSet<NSString *> *)keyPathsForValuesAffectingWorktreeStatus
{
	return [NSSet setWithObject:@"status"];
}
+ (NSSet<NSString *> *)keyPathsForValuesAffectingStagedIcon
{
	return [NSSet setWithObject:@"stagedStatus"];
}
+ (NSSet<NSString *> *)keyPathsForValuesAffectingWorktreeIcon
{
	return [NSSet setWithObject:@"worktreeStatus"];
}

- (id)initWithPath:(NSString *)p
{
	return [self initWithPath:p rawPath:[p dataUsingEncoding:NSUTF8StringEncoding]];
}

- (instancetype)initWithPath:(NSString *)displayPath rawPath:(NSData *)pathBytes
{
	self = [super init];
	if (self) {
		// Do not call setPath: here: an escaped display label must not replace
		// the raw bytes supplied by the Git parser.
		path = [displayPath copy];
		rawPath = [pathBytes copy];
	}
	return self;
}

- (NSString *)path
{
	@synchronized(self) {
		return path;
	}
}
- (NSData *)rawPath
{
	@synchronized(self) {
		return rawPath;
	}
}
- (NSString *)safePath
{
	@synchronized(self) {
		return [PBIndexFilePresentation safePathForRawPath:rawPath];
	}
}
- (void)setPath:(NSString *)value
{
	@synchronized(self) {
		path = [value copy];
		rawPath = [path dataUsingEncoding:NSUTF8StringEncoding];
	}
}

- (PBChangedFileStatus)status
{
	@synchronized(self) {
		return status;
	}
}
- (void)setStatus:(PBChangedFileStatus)value
{
	@synchronized(self) {
		status = value;
		// Compatibility callers create a file with one legacy status. The
		// reconciler overwrites each side with its authoritative status next.
		stagedStatus = value;
		worktreeStatus = value;
	}
}
- (PBChangedFileStatus)stagedStatus
{
	@synchronized(self) {
		return stagedStatus;
	}
}
- (void)setStagedStatus:(PBChangedFileStatus)value
{
	@synchronized(self) {
		stagedStatus = value;
	}
}
- (PBChangedFileStatus)worktreeStatus
{
	@synchronized(self) {
		return worktreeStatus;
	}
}
- (void)setWorktreeStatus:(PBChangedFileStatus)value
{
	@synchronized(self) {
		worktreeStatus = value;
	}
}

- (NSImage *)icon
{
	return [NSImage imageNamed:[PBIndexFilePresentation imageNameForStatus:self.status]];
}
- (NSImage *)stagedIcon
{
	return [NSImage imageNamed:[PBIndexFilePresentation imageNameForStatus:self.stagedStatus]];
}
- (NSImage *)worktreeIcon
{
	return [NSImage imageNamed:[PBIndexFilePresentation imageNameForStatus:self.worktreeStatus]];
}

@end
