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
@property (nonatomic) dispatch_queue_t renderQueue;
@property (nonatomic) NSUInteger contentGeneration;
@property (nonatomic) PBTask *activeTask;
@end

@implementation PBWebHistoryController

@synthesize diff;

- (void)awakeFromNib
{
	repository = historyController.repository;
	[super awakeFromNib];
	self.nativeView.delegate = self;
	self.renderQueue = dispatch_queue_create("com.gitx.history-render", DISPATCH_QUEUE_SERIAL);

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

- (BOOL)isGenerationCurrent:(NSUInteger)generation
{
	@synchronized(self) {
		return generation == self.contentGeneration;
	}
}

- (NSUInteger)beginContentGeneration
{
	PBTask *task = nil;
	NSUInteger generation = 0;
	@synchronized(self) {
		generation = ++self.contentGeneration;
		task = self.activeTask;
		self.activeTask = nil;
	}
	[task terminate];
	return generation;
}

- (nullable NSString *)runGitArguments:(NSArray<NSString *> *)arguments generation:(NSUInteger)generation error:(NSError **)error
{
	if (![self isGenerationCurrent:generation]) return nil;
	PBTask *task = [historyController.repository taskWithArguments:arguments];
	task.timeout = 2.0 * 60.0;
	@synchronized(self) {
		if (generation != self.contentGeneration) return nil;
		self.activeTask = task;
	}
	BOOL success = [task launchTask:error];
	@synchronized(self) {
		if (self.activeTask == task) self.activeTask = nil;
	}
	if (!success || ![self isGenerationCurrent:generation]) return nil;
	return task.standardOutputString ?: @"";
}

- (NSString *)diffForCommit:(PBGitCommit *)commit generation:(NSUInteger)generation
{
	NSString *base = commit.parents.firstObject.SHA ?: PBEmptyTreeSHA;
	return [self runGitArguments:@[ @"diff", @"--find-renames", @"--no-ext-diff", base, commit.SHA ] generation:generation error:nil] ?: @"";
}

- (BOOL)commitsShareAncestryPath:(NSArray<PBGitCommit *> *)commits generation:(NSUInteger)generation
{
	for (NSUInteger index = 1; index < commits.count; index++) {
		NSString *oldSHA = commits[index - 1].SHA;
		NSString *newSHA = commits[index].SHA;
		NSString *range = [NSString stringWithFormat:@"%@..%@", oldSHA, newSHA];
		NSString *lineage = [self runGitArguments:@[ @"rev-list", @"--first-parent", @"--parents", range ] generation:generation error:nil];
		if (!lineage || ![self isGenerationCurrent:generation]) return NO;
		NSArray<NSString *> *lines = [lineage componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
		NSString *oldestLine = nil;
		for (NSString *line in lines.reverseObjectEnumerator) {
			if (line.length) {
				oldestLine = line;
				break;
			}
		}
		NSArray<NSString *> *parts = [oldestLine componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		NSMutableArray<NSString *> *nonempty = [NSMutableArray array];
		for (NSString *part in parts)
			if (part.length) [nonempty addObject:part];
		if (nonempty.count < 2 || ![nonempty[1] isEqualToString:oldSHA]) return NO;
	}
	return YES;
}

- (nullable NSArray<NSDictionary *> *)sequentialSectionsForCommits:(NSArray<PBGitCommit *> *)commits generation:(NSUInteger)generation
{
	NSMutableArray *sections = [NSMutableArray array];
	for (PBGitCommit *commit in commits) {
		if (![self isGenerationCurrent:generation]) return nil;
		NSString *shortSHA = commit.shortName ?: @"";
		NSString *title = [NSString stringWithFormat:@"%@  %@\n%@ — %@", shortSHA, commit.subject ?: @"", commit.author ?: @"", commit.authorDate ?: @""];
		[sections addObject:@{
			PBNativeSectionTitleKey : title,
			PBNativeSectionTextKey : [self diffForCommit:commit generation:generation],
			PBNativeSectionContextKey : @"readOnly",
		}];
	}
	return [self isGenerationCurrent:generation] ? sections : nil;
}

- (nullable NSArray<NSDictionary *> *)combinedSectionsForCommits:(NSArray<PBGitCommit *> *)commits generation:(NSUInteger)generation
{
	PBGitCommit *oldest = commits.firstObject;
	PBGitCommit *newest = commits.lastObject;
	NSString *base = oldest.parents.firstObject.SHA ?: PBEmptyTreeSHA;
	NSString *combined = [self runGitArguments:@[ @"diff", @"--find-renames", @"--no-ext-diff", base, newest.SHA ] generation:generation error:nil];
	if (!combined || ![self isGenerationCurrent:generation]) return nil;
	return @[ @{
		PBNativeSectionTitleKey : [NSString stringWithFormat:@"Combined Diff — %@ through %@", oldest.shortName, newest.shortName],
		PBNativeSectionTextKey : combined,
		PBNativeSectionContextKey : @"readOnly",
	} ];
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

- (nullable NSArray<NSDictionary *> *)workingStateSectionsForChanges:(NSArray<PBChangedFile *> *)changes generation:(NSUInteger)generation
{
	NSString *staged = [self runGitArguments:@[ @"diff", @"--cached", @"--find-renames", @"--no-ext-diff" ] generation:generation error:nil];
	if (!staged || ![self isGenerationCurrent:generation]) return nil;
	NSString *unstagedOutput = [self runGitArguments:@[ @"diff", @"--find-renames", @"--no-ext-diff" ] generation:generation error:nil];
	if (!unstagedOutput || ![self isGenerationCurrent:generation]) return nil;
	NSMutableString *unstaged = [unstagedOutput mutableCopy];
	for (PBChangedFile *file in changes) {
		if (![self isGenerationCurrent:generation]) return nil;
		BOOL untracked = file.status == NEW && !file.hasStagedChanges;
		if (untracked && file.hasUnstagedChanges) [unstaged appendString:[self syntheticUntrackedDiffForFile:file]];
	}
	return @[
		@{PBNativeSectionTitleKey : @"Staged Changes", PBNativeSectionTextKey : staged, PBNativeSectionContextKey : @"readOnly"},
		@{PBNativeSectionTitleKey : @"Unstaged Changes", PBNativeSectionTextKey : unstaged, PBNativeSectionContextKey : @"readOnly"},
	];
}

- (void)changeContentTo:(NSArray<PBGitCommit *> *)commits
{
	NSArray<PBGitCommit *> *requestedCommits = [commits copy] ?: @[];
	NSUInteger generation = [self beginContentGeneration];
	self.displayedCommits = requestedCommits;
	self.presentationControl.superview.hidden = requestedCommits.count <= 1;
	if (requestedCommits.count == 0) {
		self.renderedCommits = @[];
		self->diff = @"";
		[self.nativeView showMessage:@"No commit selected"];
		return;
	}
	if ([requestedCommits.firstObject isKindOfClass:PBUncommittedChanges.class]) {
		self.presentationControl.superview.hidden = YES;
		NSArray<PBChangedFile *> *changes = [historyController.repository.index.indexChanges copy];
		[self.nativeView showMessage:@"Loading changes…"];
		dispatch_async(self.renderQueue, ^{
			NSArray<NSDictionary *> *sections = [self workingStateSectionsForChanges:changes generation:generation];
			if (!sections) return;
			dispatch_async(dispatch_get_main_queue(), ^{
				if (![self isGenerationCurrent:generation]) return;
				self.renderedCommits = @[];
				self->diff = [[sections valueForKey:PBNativeSectionTextKey] componentsJoinedByString:@"\n"];
				[self.nativeView showDiffSections:sections];
			});
		});
		return;
	}

	NSArray<PBGitCommit *> *ordered = [self oldestFirst:requestedCommits];
	PBMultiCommitDiffPresentation requestedMode = self.presentationControl.selectedSegment;
	[self.nativeView showMessage:@"Loading diff…"];
	dispatch_async(self.renderQueue, ^{
		BOOL combinedEnabled = requestedCommits.count > 1 && [self commitsShareAncestryPath:ordered generation:generation];
		if (![self isGenerationCurrent:generation]) return;
		PBMultiCommitDiffPresentation mode = requestedMode;
		if (mode == PBMultiCommitDiffPresentationCombined && !combinedEnabled) mode = PBMultiCommitDiffPresentationSequential;
		NSArray<NSDictionary *> *sections = mode == PBMultiCommitDiffPresentationCombined ? [self combinedSectionsForCommits:ordered generation:generation] : [self sequentialSectionsForCommits:ordered generation:generation];
		if (!sections || ![self isGenerationCurrent:generation]) return;
		dispatch_async(dispatch_get_main_queue(), ^{
			if (![self isGenerationCurrent:generation]) return;
			[self.presentationControl setEnabled:combinedEnabled forSegment:PBMultiCommitDiffPresentationCombined];
			self.presentationControl.selectedSegment = mode;
			self.presentationControl.toolTip = requestedMode == PBMultiCommitDiffPresentationCombined && !combinedEnabled ? NSLocalizedString(@"Combined Diff requires commits on one ancestry path.", @"Explanation shown when selected commits cannot produce one combined diff") : nil;
			self.renderedCommits = mode == PBMultiCommitDiffPresentationCombined ? @[ ordered.lastObject ] : ordered;
			self->diff = [[sections valueForKey:PBNativeSectionTextKey] componentsJoinedByString:@"\n"];
			[self.nativeView showDiffSections:sections];
		});
	});
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
