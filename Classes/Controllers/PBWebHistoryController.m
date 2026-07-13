#import "PBWebHistoryController.h"
#import "PBNativeContentView.h"
#import "PBUncommittedChanges.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBGitIndex.h"
#import "PBChangedFile.h"
#import "PBTask.h"

static NSString *const PBMultiCommitDiffPresentationKey = @"PBMultiCommitDiffPresentation";
static NSString *const PBEmptyTreeSHA = @"4b825dc642cb6eb9a060e54bf8d69288fbee4904";

typedef NS_ENUM(NSInteger, PBMultiCommitDiffPresentation) {
	PBMultiCommitDiffPresentationSequential = 0,
	PBMultiCommitDiffPresentationCombined = 1,
};

@interface PBWebHistoryController () <PBNativeContentViewDelegate>
@property (nonatomic) NSSegmentedControl *presentationControl;
@property (nonatomic) NSArray<PBGitCommit *> *displayedCommits;
@property (nonatomic) NSArray<PBGitCommit *> *renderedCommits;
@end

@implementation PBWebHistoryController

@synthesize diff;

- (void)awakeFromNib
{
	startFile = @"history";
	repository = historyController.repository;
	[super awakeFromNib];
	self.nativeView.delegate = self;

	self.presentationControl = [NSSegmentedControl segmentedControlWithLabels:@[ @"Sequential", @"Combined" ]
										 trackingMode:NSSegmentSwitchTrackingSelectOne
											 target:self
											 action:@selector(presentationChanged:)];
	self.presentationControl.controlSize = NSControlSizeSmall;
	self.presentationControl.accessibilityIdentifier = @"MultiCommitDiffPresentation";
	self.presentationControl.selectedSegment = [[NSUserDefaults standardUserDefaults] integerForKey:PBMultiCommitDiffPresentationKey];
	NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 32)];
	accessory.translatesAutoresizingMaskIntoConstraints = NO;
	self.presentationControl.translatesAutoresizingMaskIntoConstraints = NO;
	[accessory addSubview:self.presentationControl];
	[NSLayoutConstraint activateConstraints:@[
		[accessory.heightAnchor constraintEqualToConstant:32],
		[self.presentationControl.centerXAnchor constraintEqualToAnchor:accessory.centerXAnchor],
		[self.presentationControl.centerYAnchor constraintEqualToAnchor:accessory.centerYAnchor],
	]];
	[self.nativeView setAccessoryView:accessory];
	accessory.hidden = YES;

	[historyController addObserver:self keyPath:@"webCommits" options:0 block:^(MAKVONotification *notification) {
		[notification.observer changeContentTo:((PBGitHistoryController *)notification.target).webCommits];
	}];
}

- (void)didLoad
{
	[self changeContentTo:historyController.webCommits];
}

- (NSArray<PBGitCommit *> *)oldestFirst:(NSArray<PBGitCommit *> *)commits
{
	// NSArrayController supplies selected commits in visible (newest-first Git
	// graph) order. Reversing preserves topology even when authored dates lie.
	return commits.reverseObjectEnumerator.allObjects;
}

- (NSString *)diffForCommit:(PBGitCommit *)commit
{
	NSString *base = commit.parents.firstObject.SHA ?: PBEmptyTreeSHA;
	NSError *error = nil;
	return [historyController.repository outputOfTaskWithArguments:@[ @"diff", @"--find-renames", @"--no-ext-diff", base, commit.SHA ] error:&error] ?: @"";
}

- (BOOL)commitsShareAncestryPath:(NSArray<PBGitCommit *> *)commits
{
	for (NSUInteger index = 1; index < commits.count; index++) {
		NSError *error = nil;
		NSString *lineage = [historyController.repository outputOfTaskWithArguments:@[ @"rev-list", @"--first-parent", commits[index].SHA ] error:&error];
		if (!lineage) return NO;
		NSSet<NSString *> *firstParents = [NSSet setWithArray:[lineage componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]];
		if (![firstParents containsObject:commits[index - 1].SHA]) return NO;
	}
	return YES;
}

- (NSArray<NSDictionary *> *)sequentialSectionsForCommits:(NSArray<PBGitCommit *> *)commits
{
	NSMutableArray *sections = [NSMutableArray array];
	for (PBGitCommit *commit in commits) {
		NSString *shortSHA = commit.shortName ?: @"";
		NSString *title = [NSString stringWithFormat:@"%@  %@\n%@ — %@", shortSHA, commit.subject ?: @"", commit.author ?: @"", commit.authorDate ?: @""];
		[sections addObject:@{
			PBNativeSectionTitleKey : title,
			PBNativeSectionTextKey : [self diffForCommit:commit],
			PBNativeSectionContextKey : @"readOnly",
		}];
	}
	return sections;
}

- (NSArray<NSDictionary *> *)combinedSectionsForCommits:(NSArray<PBGitCommit *> *)commits
{
	PBGitCommit *oldest = commits.firstObject;
	PBGitCommit *newest = commits.lastObject;
	NSString *base = oldest.parents.firstObject.SHA ?: PBEmptyTreeSHA;
	NSError *error = nil;
	NSString *combined = [historyController.repository outputOfTaskWithArguments:@[ @"diff", @"--find-renames", @"--no-ext-diff", base, newest.SHA ] error:&error] ?: @"";
	return @[@{
		PBNativeSectionTitleKey : [NSString stringWithFormat:@"Combined Diff — %@ through %@", oldest.shortName, newest.shortName],
		PBNativeSectionTextKey : combined,
		PBNativeSectionContextKey : @"readOnly",
	}];
}

- (NSString *)syntheticUntrackedDiffForFile:(PBChangedFile *)file
{
	NSString *contents = [historyController.repository.index diffForFile:file staged:NO contextLines:3] ?: @"";
	NSMutableArray<NSString *> *lines = [[contents componentsSeparatedByString:@"\n"] mutableCopy];
	BOOL endsWithNewline = [contents hasSuffix:@"\n"];
	if (endsWithNewline && [lines.lastObject length] == 0) [lines removeLastObject];
	if (lines.count == 0 || (lines.count == 1 && [lines.firstObject length] == 0)) return @"";
	NSMutableString *added = [NSMutableString string];
	for (NSString *line in lines) [added appendFormat:@"+%@\n", line];
	if (!endsWithNewline) [added appendString:@"\\ No newline at end of file\n"];
	return [NSString stringWithFormat:@"diff --git a/%@ b/%@\nnew file mode 100644\n--- /dev/null\n+++ b/%@\n@@ -0,0 +1,%lu @@\n%@", file.path, file.path, file.path, (unsigned long)lines.count, added];
}

- (NSArray<NSDictionary *> *)workingStateSections
{
	NSError *error = nil;
	NSString *staged = [historyController.repository outputOfTaskWithArguments:@[ @"diff", @"--cached", @"--find-renames", @"--no-ext-diff" ] error:&error] ?: @"";
	NSMutableString *unstaged = [[historyController.repository outputOfTaskWithArguments:@[ @"diff", @"--find-renames", @"--no-ext-diff" ] error:&error] ?: @"" mutableCopy];
	for (PBChangedFile *file in historyController.repository.index.indexChanges) {
		if (file.status == NEW && file.hasUnstagedChanges) [unstaged appendString:[self syntheticUntrackedDiffForFile:file]];
	}
	return @[
		@{ PBNativeSectionTitleKey : @"Staged Changes", PBNativeSectionTextKey : staged, PBNativeSectionContextKey : @"readOnly" },
		@{ PBNativeSectionTitleKey : @"Unstaged Changes", PBNativeSectionTextKey : unstaged, PBNativeSectionContextKey : @"readOnly" },
	];
}

- (void)changeContentTo:(NSArray<PBGitCommit *> *)commits
{
	self.displayedCommits = commits ?: @[];
	self.presentationControl.superview.hidden = commits.count <= 1;
	if (commits.count == 0) {
		[self.nativeView showMessage:@"No commit selected"];
		return;
	}
	if ([commits.firstObject isKindOfClass:PBUncommittedChanges.class]) {
		self.renderedCommits = @[];
		self.presentationControl.superview.hidden = YES;
		NSArray *sections = [self workingStateSections];
		self->diff = [[sections valueForKey:PBNativeSectionTextKey] componentsJoinedByString:@"\n"];
		[self.nativeView showDiffSections:sections];
		return;
	}

	NSArray<PBGitCommit *> *ordered = [self oldestFirst:commits];
	BOOL combinedEnabled = commits.count > 1 && [self commitsShareAncestryPath:ordered];
	[self.presentationControl setEnabled:combinedEnabled forSegment:PBMultiCommitDiffPresentationCombined];
	PBMultiCommitDiffPresentation mode = self.presentationControl.selectedSegment;
	if (mode == PBMultiCommitDiffPresentationCombined && !combinedEnabled) {
		mode = PBMultiCommitDiffPresentationSequential;
		self.presentationControl.selectedSegment = mode;
		self.presentationControl.toolTip = NSLocalizedString(@"Combined Diff requires commits on one ancestry path.", @"Explanation shown when selected commits cannot produce one combined diff");
	} else {
		self.presentationControl.toolTip = nil;
	}
	NSArray *sections = mode == PBMultiCommitDiffPresentationCombined ? [self combinedSectionsForCommits:ordered] : [self sequentialSectionsForCommits:ordered];
	self.renderedCommits = mode == PBMultiCommitDiffPresentationCombined ? @[ ordered.lastObject ] : ordered;
	self->diff = [[sections valueForKey:PBNativeSectionTextKey] componentsJoinedByString:@"\n"];
	[self.nativeView showDiffSections:sections];
}

- (nullable NSData *)dataForGitObject:(NSString *)object
{
	PBTask *task = [historyController.repository taskWithArguments:@[ @"show", object ]];
	if (![task launchTask:nil]) return nil;
	return task.standardOutputData;
}

- (NSImage *)nativeContentView:(PBNativeContentView *)view imageForPath:(NSString *)path section:(NSUInteger)sectionIndex
{
	NSData *data = nil;
	if (sectionIndex < self.renderedCommits.count) {
		PBGitCommit *commit = self.renderedCommits[sectionIndex];
		data = [self dataForGitObject:[NSString stringWithFormat:@"%@:%@", commit.SHA, path]];
		if (!data.length && commit.parents.firstObject) data = [self dataForGitObject:[NSString stringWithFormat:@"%@:%@", commit.parents.firstObject.SHA, path]];
	} else {
		data = [NSData dataWithContentsOfURL:[historyController.repository.workingDirectoryURL URLByAppendingPathComponent:path]];
		if (!data.length) data = [self dataForGitObject:[@":" stringByAppendingString:path]];
	}
	return data.length ? [[NSImage alloc] initWithData:data] : nil;
}

- (void)presentationChanged:(NSSegmentedControl *)sender
{
	[[NSUserDefaults standardUserDefaults] setInteger:sender.selectedSegment forKey:PBMultiCommitDiffPresentationKey];
	[self changeContentTo:self.displayedCommits];
}

- (void)nativeContentView:(PBNativeContentView *)view selectCommit:(NSString *)sha
{
	[historyController selectCommit:[GTOID oidWithSHA:sha]];
}

- (void)sendKey:(NSString *)key
{
	if ([key isEqualToString:@"j"]) [self.nativeView.textView scrollLineDown:self];
	else if ([key isEqualToString:@"k"]) [self.nativeView.textView scrollLineUp:self];
}

- (void)scrollPageUp { [self.nativeView scrollPageUp]; }
- (void)scrollPageDown { [self.nativeView scrollPageDown]; }
- (void)preferencesChanged { [self changeContentTo:self.displayedCommits]; }

@end
