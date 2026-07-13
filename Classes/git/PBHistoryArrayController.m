#import "PBHistoryArrayController.h"
#import "PBGitDefaults.h"

@implementation PBHistoryArrayController

- (id)arrangeObjects:(id)objects
{
	id arranged = [super arrangeObjects:objects];
	if (!self.pinnedObject) return arranged;
	NSMutableArray *result = [NSMutableArray arrayWithObject:self.pinnedObject];
	if ([arranged isKindOfClass:NSArray.class]) [result addObjectsFromArray:arranged];
	return result;
}

- (void)setPinnedObject:(id)pinnedObject
{
	if (_pinnedObject == pinnedObject) return;
	_pinnedObject = pinnedObject;
	[self rearrangeObjects];
}

- (void)setSortDescriptors:(NSArray<NSSortDescriptor *> *)sortDescriptors
{
	[super setSortDescriptors:[PBGitDefaults historyColumnSortingEnabled] ? sortDescriptors : @[]];
}

@end
