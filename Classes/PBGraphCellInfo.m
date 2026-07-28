//
//  PBGraphCellInfo.m
//  GitX
//
//  Created by Pieter de Bie on 27-08-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import "PBGraphCellInfo.h"


@implementation PBGraphCellInfo
@synthesize nLines, position, numColumns, sign;

// Threading contract: instances are created and configured on the history graph
// queue, then published to the main thread through PBGitCommit's atomic lineInfo
// property. The @synchronized pair on the manual `lines` accessors gives the
// main-thread reader visibility of the background-written buffer pointer; the
// scalar properties are atomic by declaration. The returned buffer stays valid
// for the receiver's lifetime because nothing replaces it after publication --
// setLines: frees the previous buffer and must never run concurrently with a
// reader that still uses a previously returned pointer.
- (id)initWithPosition:(long)p andLines:(struct PBGitGraphLine *)l
{
	self = [super init];
	if (self) {
		position = p;
		@synchronized(self) {
			lines = l;
		}
	}

	return self;
}

- (struct PBGitGraphLine *)lines
{
	@synchronized(self) {
		return lines;
	}
}

- (void)setLines:(struct PBGitGraphLine *)l
{
	@synchronized(self) {
		free(lines);
		lines = l;
	}
}

- (NSString *)description
{
	return [self debugDescription];
}

- (NSString *)debugDescription
{
	NSMutableString *desc = [NSMutableString stringWithFormat:@"<%@: %p position: %ld numColumns: %ld nLines: %ld sign: '%c'>",
															  NSStringFromClass([self class]), self, position, numColumns, nLines, sign];
	for (int lineIndex = 0; lineIndex < nLines; lineIndex++) {
		struct PBGitGraphLine line = lines[lineIndex];
		[desc appendString:[NSString stringWithFormat:@"\n\t<upper: %d from: %d to: %d colorIndex: %d>",
													  line.upper, line.from, line.to, line.colorIndex]];
	}
	return desc;
}

- (void)dealloc
{
	free(lines);
}

@end
