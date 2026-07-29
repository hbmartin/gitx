//
//  PBCommitMessageView.m
//  GitX
//
//  Created by Jeff Mesnil on 13/10/08.
//  Copyright 2008 Jeff Mesnil (http://jmesnil.net/). All rights reserved.
//

#import "PBCommitMessageView.h"

#import "GitX-Swift.h"
#import "PBGitRepository.h"

static NSPasteboardType const PBFilenamesPasteboardType = @"NSFilenamesPboardType";

@implementation PBCommitMessageView

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
	NSPasteboard *pasteboard = sender.draggingPasteboard;

	if ([pasteboard.types containsObject:PBFilenamesPasteboardType]) {
		NSArray<NSString *> *filenames = [pasteboard propertyListForType:PBFilenamesPasteboardType];
		NSArray<NSString *> *relativeNames =
			[PBCommitMessageDropPathPolicy relativePathsFromFilenames:filenames ?: @[]
													 workingDirectory:self.repository.workingDirectory];
		if (relativeNames) {
			[pasteboard clearContents];
			[pasteboard writeObjects:relativeNames];
		}
	}
	return [super performDragOperation:sender];
}

@end
