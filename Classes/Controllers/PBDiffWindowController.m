//
//  PBDiffWindowController.m
//  GitX
//
//  Created by Pieter de Bie on 13-10-08.
//  Copyright 2008 Pieter de Bie. All rights reserved.
//

#import "PBDiffWindowController.h"
#import "PBGitRepository.h"
#import "PBGitCommit.h"
#import "PBGitDefaults.h"


@implementation PBDiffWindowController

@synthesize startCommit = _startCommit;
@synthesize diffCommit = _diffCommit;

+ (void)showDiff:(NSString *)diff
{
	PBDiffWindowController *diffController = [[self alloc] initWithDiff:diff];
	[diffController showWindow:self];
}

+ (void)showDiffWindowWithFiles:(NSArray *)filePaths fromCommit:(PBGitCommit *)startCommit diffCommit:(PBGitCommit *)diffCommit
{
	NSParameterAssert(startCommit != nil);
	NSString *diff = [startCommit.repository performDiff:startCommit against:diffCommit forFiles:filePaths];

	PBDiffWindowController *diffController = [[self alloc] initWithDiff:[diff copy]];
	diffController->_startCommit = startCommit;
	diffController->_diffCommit = diffCommit ?: startCommit.repository.headCommit;
	[diffController showWindow:self];
}

- (id)initWithDiff:(NSString *)aDiff
{
	self = [super initWithWindowNibName:@"PBDiffWindow"];
	if (!self) return nil;

	_diff = aDiff;

	return self;
}


@end
