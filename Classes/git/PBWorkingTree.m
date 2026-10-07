#import "PBWorkingTree.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBGitIndex.h"
#import "PBChangedFile.h"
#import "PBTask.h"
#import "GitX-Swift.h"
#include <string.h>

@interface PBWorkingTree ()
@property (nonatomic) NSMutableArray<PBWorkingTree *> *workingChildren;
@property (nonatomic) NSString *workingStatus;
@property (nonatomic, copy, readwrite, nullable) NSData *rawPath;
@end

@implementation PBWorkingTree

+ (instancetype)rootForRepository:(PBGitRepository *)repository
{
	PBWorkingTree *root = [[self alloc] init];
	root.repository = repository;
	root.path = @"";
	root.leaf = NO;
	root.workingChildren = [NSMutableArray array];

	NSMutableDictionary<NSData *, PBChangedFile *> *changes = [NSMutableDictionary dictionary];
	for (PBChangedFile *file in repository.index.indexChanges) changes[file.rawPath] = file;

	NSMutableOrderedSet<NSData *> *paths = [NSMutableOrderedSet orderedSet];
	for (NSArray<NSString *> *arguments in @[ @[ @"ls-files", @"-co", @"--exclude-standard", @"-z" ], @[ @"ls-files", @"--deleted", @"-z" ] ]) {
		PBTask *task = [repository taskWithArguments:arguments];
		NSError *error = nil;
		if ([task launchTask:&error])
			[paths addObjectsFromArray:[PBIndexFilePresentation rawPathsFromData:task.standardOutputData]];
		else
			PBLogError(error);
	}

	NSMutableDictionary<NSString *, PBWorkingTree *> *nodes = [NSMutableDictionary dictionaryWithObject:root forKey:@""];
	for (NSData *rawPath in paths) {
		NSString *filePath = [PBIndexFilePresentation safePathForRawPath:rawPath];
		if (!filePath) {
			NSLog(@"[GitX] Keeping unsupported working-tree filename in staging only: %@", [PBIndexFilePresentation displayPathForRawPath:rawPath]);
			continue;
		}
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
				node.workingChildren = [NSMutableArray array];
				nodes[accumulated] = node;
				[parent.workingChildren addObject:node];
			}
			parent = node;
		}

		parent.rawPath = rawPath;
		PBChangedFile *change = changes[rawPath];
		if (change) parent.workingStatus = [PBIndexFilePresentation workingStatusForFile:change];
	}

	for (PBWorkingTree *node in nodes.allValues) {
		[node.workingChildren sortUsingComparator:^NSComparisonResult(PBWorkingTree *left, PBWorkingTree *right) {
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
	if ([self.workingStatus containsString:@"untracked"])
		symbol = @"?";
	else if ([self.workingStatus containsString:@"deleted"])
		symbol = @"D";
	else if ([self.workingStatus containsString:@"staged"] && ![self.workingStatus containsString:@"unstaged"])
		symbol = @"S";
	return [NSString stringWithFormat:@"%@  [%@]", self.path, symbol];
}

- (NSString *)fullPath
{
	if (self.leaf && self.rawPath) return [PBIndexFilePresentation safePathForRawPath:self.rawPath];
	return [super fullPath];
}

- (NSURL *)workingFileURL
{
	NSString *path = [PBIndexFilePresentation safePathForRawPath:self.rawPath];
	return path ? [self.repository.workingDirectoryURL URLByAppendingPathComponent:path] : nil;
}

- (NSString *)contents
{
	if (!self.leaf || ![PBIndexFilePresentation pathMatchesRawPath:self.rawPath fullPath:self.fullPath]) return @"";
	NSData *data = [NSData dataWithContentsOfURL:self.workingFileURL];
	if (!data) {
		NSError *error = nil;
		NSString *indexed = [self.repository outputOfTaskWithArguments:@[ @"show", [@":0:" stringByAppendingString:self.fullPath] ] error:&error];
		return indexed ?: error.localizedDescription ?:
													   @"";
	}
	if (data.length && memchr(data.bytes, 0, MIN(data.length, (NSUInteger)8000)))
		return @"This file cannot be displayed as text.";
	NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	return string ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?:
																							   @"This file cannot be displayed as text.";
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
	if (!self.leaf || ![PBIndexFilePresentation pathMatchesRawPath:self.rawPath fullPath:self.fullPath]) return @"";
	NSError *error = nil;
	NSArray<NSString *> *arguments = [self.repository.index literalArgumentsForRawPath:self.rawPath commandArguments:@[ @"blame", @"-p" ] error:&error];
	if (!arguments) {
		PBLogError(error);
		return @"";
	}
	NSString *blame = [self.repository outputOfTaskWithArguments:arguments error:&error];
	return blame ?: [self porcelainForUntrackedContents:self.contents];
}

- (NSString *)log:(NSString *)format
{
	if (!self.leaf || ![PBIndexFilePresentation pathMatchesRawPath:self.rawPath fullPath:self.fullPath]) return @"";
	NSError *error = nil;
	NSArray<NSString *> *arguments = [self.repository.index literalArgumentsForRawPath:self.rawPath
																	  commandArguments:@[ @"log", [NSString stringWithFormat:@"--pretty=format:%@", format], @"--follow" ]
																				 error:&error];
	if (!arguments) {
		PBLogError(error);
		return @"";
	}
	return [self.repository outputOfTaskWithArguments:arguments error:&error] ?: @"";
}

- (long long)fileSize
{
	NSNumber *size = nil;
	[self.workingFileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
	return size.longLongValue;
}

- (NSString *)tmpFileNameForContents
{
	if (![PBIndexFilePresentation pathMatchesRawPath:self.rawPath fullPath:self.fullPath]) return nil;
	if ([[NSFileManager defaultManager] fileExistsAtPath:self.workingFileURL.path]) return self.workingFileURL.path;
	return [super tmpFileNameForContents];
}

@end
