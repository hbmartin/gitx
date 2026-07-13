#import "PBWorkingTree.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBGitIndex.h"
#import "PBChangedFile.h"

@interface PBWorkingTree ()
@property (nonatomic) NSArray<PBWorkingTree *> *workingChildren;
@property (nonatomic) NSString *workingStatus;
@end

@implementation PBWorkingTree

+ (instancetype)rootForRepository:(PBGitRepository *)repository
{
	PBWorkingTree *root = [[self alloc] init];
	root.repository = repository;
	root.path = @"";
	root.leaf = NO;
	root.workingChildren = @[];

	NSMutableDictionary<NSString *, PBChangedFile *> *changes = [NSMutableDictionary dictionary];
	for (PBChangedFile *file in repository.index.indexChanges) changes[file.path] = file;

	NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
	NSError *error = nil;
	NSString *trackedAndUntracked = [repository outputOfTaskWithArguments:@[ @"ls-files", @"-co", @"--exclude-standard", @"-z" ] error:&error];
	for (NSString *path in [trackedAndUntracked componentsSeparatedByString:@"\0"]) if (path.length) [paths addObject:path];
	NSString *deleted = [repository outputOfTaskWithArguments:@[ @"ls-files", @"--deleted", @"-z" ] error:nil];
	for (NSString *path in [deleted componentsSeparatedByString:@"\0"]) if (path.length) [paths addObject:path];

	NSMutableDictionary<NSString *, PBWorkingTree *> *nodes = [NSMutableDictionary dictionaryWithObject:root forKey:@""];
	for (NSString *filePath in paths) {
		NSArray<NSString *> *components = [filePath pathComponents];
		NSMutableString *accumulated = [NSMutableString string];
		PBWorkingTree *parent = root;
		for (NSUInteger index = 0; index < components.count; index++) {
			NSString *component = components[index];
			if (accumulated.length) [accumulated appendString:@"/"];
			[accumulated appendString:component];
			PBWorkingTree *node = nodes[accumulated];
			if (!node) {
				node = [[PBWorkingTree alloc] init];
				node.repository = repository;
				node.parent = parent;
				node.path = component;
				node.leaf = index == components.count - 1;
				node.workingChildren = @[];
				nodes[accumulated] = node;
				parent.workingChildren = [parent.workingChildren arrayByAddingObject:node];
			}
			parent = node;
		}

		PBChangedFile *change = changes[filePath];
		if (change) {
			NSMutableArray *states = [NSMutableArray array];
			if (change.hasStagedChanges) [states addObject:@"staged"];
			if (change.hasUnstagedChanges) [states addObject:(change.status == NEW ? @"untracked" : @"unstaged")];
			if (change.status == DELETED) [states addObject:@"deleted"];
			parent.workingStatus = [states componentsJoinedByString:@", "];
		}
	}

	for (PBWorkingTree *node in nodes.allValues) {
		node.workingChildren = [node.workingChildren sortedArrayUsingComparator:^NSComparisonResult(PBWorkingTree *left, PBWorkingTree *right) {
			if (left.leaf != right.leaf) return left.leaf ? NSOrderedDescending : NSOrderedAscending;
			return [left.path localizedStandardCompare:right.path];
		}];
	}
	return root;
}

- (NSArray *)children
{
	return self.workingChildren;
}

- (NSString *)displayPath
{
	if (self.workingStatus.length == 0) return self.path;
	NSString *symbol = @"M";
	if ([self.workingStatus containsString:@"untracked"]) symbol = @"?";
	else if ([self.workingStatus containsString:@"deleted"]) symbol = @"D";
	else if ([self.workingStatus containsString:@"staged"] && ![self.workingStatus containsString:@"unstaged"]) symbol = @"S";
	return [NSString stringWithFormat:@"%@  [%@]", self.path, symbol];
}

- (NSURL *)workingFileURL
{
	return [self.repository.workingDirectoryURL URLByAppendingPathComponent:self.fullPath];
}

- (NSString *)contents
{
	if (!self.leaf) return @"";
	NSData *data = [NSData dataWithContentsOfURL:self.workingFileURL];
	if (!data) {
		NSError *error = nil;
		NSString *indexed = [self.repository outputOfTaskWithArguments:@[ @"show", [@":" stringByAppendingString:self.fullPath] ] error:&error];
		return indexed ?: error.localizedDescription ?: @"";
	}
	NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	return string ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"This file cannot be displayed as text.";
}

- (NSString *)textContents
{
	return self.contents;
}

- (NSString *)porcelainForUntrackedContents:(NSString *)contents
{
	NSArray<NSString *> *lines = [contents componentsSeparatedByString:@"\n"];
	NSMutableString *result = [NSMutableString string];
	NSString *zero = @"0000000000000000000000000000000000000000";
	NSUInteger lineNumber = 1;
	for (NSString *line in lines) {
		[result appendFormat:@"%@ %lu %lu 1\nauthor Not Committed Yet\nsummary Uncommitted line\n\t%@\n", zero, (unsigned long)lineNumber, (unsigned long)lineNumber, line];
		lineNumber++;
	}
	return result;
}

- (NSString *)blame
{
	if (!self.leaf) return @"";
	NSError *error = nil;
	NSString *blame = [self.repository outputOfTaskWithArguments:@[ @"blame", @"-p", @"--", self.fullPath ] error:&error];
	return blame ?: [self porcelainForUntrackedContents:self.contents];
}

- (NSString *)log:(NSString *)format
{
	if (!self.leaf) return @"";
	NSError *error = nil;
	return [self.repository outputOfTaskWithArguments:@[ @"log", [NSString stringWithFormat:@"--pretty=format:%@", format], @"--follow", @"--", self.fullPath ] error:&error] ?: @"";
}

- (long long)fileSize
{
	NSNumber *size = nil;
	[self.workingFileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
	return size.longLongValue;
}

- (NSString *)tmpFileNameForContents
{
	if ([[NSFileManager defaultManager] fileExistsAtPath:self.workingFileURL.path]) return self.workingFileURL.path;
	return [super tmpFileNameForContents];
}

@end
