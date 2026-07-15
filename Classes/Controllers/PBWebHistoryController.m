#import "PBWebHistoryController.h"
#import "PBNativeContentView.h"
#import "PBUncommittedChanges.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBGitIndex.h"
#import "PBChangedFile.h"
#import "PBTask.h"
#import "PBGitBinary.h"
#import "GitX-Swift.h"

static NSString *const PBMultiCommitDiffPresentationKey = @"PBMultiCommitDiffPresentation";
static NSString *const PBEmptyTreeSHA = @"4b825dc642cb6eb9a060e54bf8d69288fbee4904";

typedef NS_ENUM(NSInteger, PBMultiCommitDiffPresentation) {
	PBMultiCommitDiffPresentationSequential = 0,
	PBMultiCommitDiffPresentationCombined = 1,
};

@interface PBWebHistoryController () <PBNativeContentViewDelegate>
@property (nonatomic) NSSegmentedControl *presentationControl;
@property (nonatomic) NSArray<PBGitCommit *> *displayedCommits;
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

- (PBCommitRenderInput *)renderInputForCommit:(PBGitCommit *)commit
{
	NSAssert(NSThread.isMainThread, @"Commit render metadata must be captured on the main thread");
	return [[PBCommitRenderInput alloc] initWithSHA:commit.SHA ?: @""
									   parentSHA:commit.parents.firstObject.SHA
									   shortName:commit.shortName ?: @""
										 subject:commit.subject ?: @""
										  author:commit.author ?: @""
									  authorDate:commit.authorDate ?: @""];
}

- (NSArray<PBCommitRenderInput *> *)renderInputsForCommits:(NSArray<PBGitCommit *> *)commits
{
	NSMutableArray<PBCommitRenderInput *> *inputs = [NSMutableArray arrayWithCapacity:commits.count];
	for (PBGitCommit *commit in commits)
		[inputs addObject:[self renderInputForCommit:commit]];
	return inputs;
}

- (NSDictionary<NSString *, id> *)imageSourceForRevisions:(NSArray<NSString *> *)revisions workingTree:(BOOL)workingTree
{
	NSAssert(NSThread.isMainThread, @"Image source state must be captured on the main thread");
	PBGitRepository *currentRepository = historyController.repository;
	NSMutableDictionary<NSString *, id> *source = [@{
		PBNativeImageSourceRevisionsKey : revisions,
		PBNativeImageSourceWorkingTreeKey : @(workingTree),
	} mutableCopy];
	if (currentRepository.workingDirectoryURL) source[PBNativeImageSourceWorkingTreeURLKey] = currentRepository.workingDirectoryURL;
	if (PBGitBinary.path) source[PBNativeImageSourceGitLaunchPathKey] = PBGitBinary.path;
	if (currentRepository.gitURL.path) source[PBNativeImageSourceGitDirectoryKey] = currentRepository.gitURL.path;
	if (currentRepository.workingDirectory) source[PBNativeImageSourceTaskDirectoryKey] = currentRepository.workingDirectory;
	return source;
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

- (NSString *)diffForInput:(PBCommitRenderInput *)input generation:(NSUInteger)generation
{
	NSString *base = input.parentSHA ?: PBEmptyTreeSHA;
	return [self runGitArguments:@[ @"diff", @"--find-renames", @"--no-ext-diff", base, input.sha ] generation:generation error:nil] ?: @"";
}

- (BOOL)inputsShareAncestryPath:(NSArray<PBCommitRenderInput *> *)inputs generation:(NSUInteger)generation
{
	for (NSUInteger index = 1; index < inputs.count; index++) {
		NSString *oldSHA = inputs[index - 1].sha;
		NSString *newSHA = inputs[index].sha;
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

- (nullable NSArray<NSDictionary *> *)sequentialSectionsForInputs:(NSArray<PBCommitRenderInput *> *)inputs
									 imageSources:(NSArray<NSDictionary<NSString *, id> *> *)imageSources
									   generation:(NSUInteger)generation
{
	NSMutableArray *sections = [NSMutableArray array];
	for (NSUInteger index = 0; index < inputs.count; index++) {
		PBCommitRenderInput *input = inputs[index];
		if (![self isGenerationCurrent:generation]) return nil;
		[sections addObject:@{
			PBNativeSectionTitleKey : input.title,
			PBNativeSectionTextKey : [self diffForInput:input generation:generation],
			PBNativeSectionContextKey : @"readOnly",
			PBNativeSectionImageSourceKey : imageSources[index],
		}];
	}
	return [self isGenerationCurrent:generation] ? sections : nil;
}

- (nullable NSArray<NSDictionary *> *)combinedSectionsForInputs:(NSArray<PBCommitRenderInput *> *)inputs
									  imageSource:(NSDictionary<NSString *, id> *)imageSource
									   generation:(NSUInteger)generation
{
	PBCommitRenderInput *oldest = inputs.firstObject;
	PBCommitRenderInput *newest = inputs.lastObject;
	NSString *base = oldest.parentSHA ?: PBEmptyTreeSHA;
	NSString *combined = [self runGitArguments:@[ @"diff", @"--find-renames", @"--no-ext-diff", base, newest.sha ] generation:generation error:nil];
	if (!combined || ![self isGenerationCurrent:generation]) return nil;
	return @[ @{
		PBNativeSectionTitleKey : [NSString stringWithFormat:@"Combined Diff — %@ through %@", oldest.shortName, newest.shortName],
		PBNativeSectionTextKey : combined,
		PBNativeSectionContextKey : @"readOnly",
		PBNativeSectionImageSourceKey : imageSource,
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

- (nullable NSArray<NSDictionary *> *)workingStateSectionsForChanges:(NSArray<PBChangedFile *> *)changes
										 imageSource:(NSDictionary<NSString *, id> *)imageSource
										  generation:(NSUInteger)generation
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
		@{PBNativeSectionTitleKey : @"Staged Changes", PBNativeSectionTextKey : staged, PBNativeSectionContextKey : @"readOnly", PBNativeSectionImageSourceKey : imageSource},
		@{PBNativeSectionTitleKey : @"Unstaged Changes", PBNativeSectionTextKey : unstaged, PBNativeSectionContextKey : @"readOnly", PBNativeSectionImageSourceKey : imageSource},
	];
}

- (void)changeContentTo:(NSArray<PBGitCommit *> *)commits
{
	NSArray<PBGitCommit *> *requestedCommits = [commits copy] ?: @[];
	NSUInteger generation = [self beginContentGeneration];
	BOOL refreshingDisplayedWorkingState = [requestedCommits.firstObject isKindOfClass:PBUncommittedChanges.class] &&
		self.displayedCommits.firstObject == requestedCommits.firstObject && self->diff != nil;
	self.displayedCommits = requestedCommits;
	self.presentationControl.superview.hidden = requestedCommits.count <= 1;
	if (requestedCommits.count == 0) {
		self->diff = @"";
		[self.nativeView showMessage:@"No commit selected"];
		return;
	}
	if ([requestedCommits.firstObject isKindOfClass:PBUncommittedChanges.class]) {
		self.presentationControl.superview.hidden = YES;
		NSArray<PBChangedFile *> *changes = [historyController.repository.index.indexChanges copy];
		NSDictionary<NSString *, id> *imageSource = [self imageSourceForRevisions:@[ @":" ] workingTree:YES];
		if (!refreshingDisplayedWorkingState) [self.nativeView showMessage:@"Loading changes…"];
		dispatch_async(self.renderQueue, ^{
			NSArray<NSDictionary *> *sections = [self workingStateSectionsForChanges:changes imageSource:imageSource generation:generation];
			if (!sections) return;
			dispatch_async(dispatch_get_main_queue(), ^{
				if (![self isGenerationCurrent:generation]) return;
				NSString *renderedDiff = [[sections valueForKey:PBNativeSectionTextKey] componentsJoinedByString:@"\n"];
				BOOL shouldReplace = [PBWorkingStateRefreshPolicy shouldReplaceDisplayedDiff:self->diff renderedDiff:renderedDiff];
				self->diff = renderedDiff;
				if (shouldReplace) [self.nativeView showDiffSections:sections];
			});
		});
		return;
	}

	NSArray<PBGitCommit *> *ordered = [self oldestFirst:requestedCommits];
	NSArray<PBCommitRenderInput *> *inputs = [self renderInputsForCommits:ordered];
	NSMutableArray<NSDictionary<NSString *, id> *> *imageSources = [NSMutableArray arrayWithCapacity:inputs.count];
	for (PBCommitRenderInput *input in inputs)
		[imageSources addObject:[self imageSourceForRevisions:input.imageRevisions workingTree:NO]];
	PBMultiCommitDiffPresentation requestedMode = self.presentationControl.selectedSegment;
	[self.nativeView showMessage:@"Loading diff…"];
	dispatch_async(self.renderQueue, ^{
		BOOL combinedEnabled = inputs.count > 1 && [self inputsShareAncestryPath:inputs generation:generation];
		if (![self isGenerationCurrent:generation]) return;
		PBMultiCommitDiffPresentation mode = requestedMode;
		if (mode == PBMultiCommitDiffPresentationCombined && !combinedEnabled) mode = PBMultiCommitDiffPresentationSequential;
		NSArray<NSDictionary *> *sections = mode == PBMultiCommitDiffPresentationCombined ? [self combinedSectionsForInputs:inputs imageSource:imageSources.lastObject generation:generation] : [self sequentialSectionsForInputs:inputs imageSources:imageSources generation:generation];
		if (!sections || ![self isGenerationCurrent:generation]) return;
		dispatch_async(dispatch_get_main_queue(), ^{
			if (![self isGenerationCurrent:generation]) return;
			[self.presentationControl setEnabled:combinedEnabled forSegment:PBMultiCommitDiffPresentationCombined];
			self.presentationControl.selectedSegment = mode;
			self.presentationControl.toolTip = requestedMode == PBMultiCommitDiffPresentationCombined && !combinedEnabled ? NSLocalizedString(@"Combined Diff requires commits on one ancestry path.", @"Explanation shown when selected commits cannot produce one combined diff") : nil;
			self->diff = [[sections valueForKey:PBNativeSectionTextKey] componentsJoinedByString:@"\n"];
			[self.nativeView showDiffSections:sections];
		});
	});
}

- (nullable NSData *)dataForGitObject:(NSString *)object imageSource:(NSDictionary<NSString *, id> *)imageSource
{
	NSString *launchPath = imageSource[PBNativeImageSourceGitLaunchPathKey];
	NSString *gitDirectory = imageSource[PBNativeImageSourceGitDirectoryKey];
	if (!launchPath.length || !gitDirectory.length) return nil;
	NSArray<NSString *> *arguments = @[ [@"--git-dir=" stringByAppendingString:gitDirectory], @"show", object ];
	PBTask *task = [PBTask taskWithLaunchPath:launchPath arguments:arguments inDirectory:imageSource[PBNativeImageSourceTaskDirectoryKey]];
	if (![task launchTask:nil]) return nil;
	return task.standardOutputData;
}

- (nullable NSData *)nativeContentView:(PBNativeContentView *)view
				 imageDataForPath:(NSString *)path
						section:(NSUInteger)sectionIndex
					 imageSource:(NSDictionary<NSString *, id> *)imageSource
{
	if ([imageSource[PBNativeImageSourceWorkingTreeKey] boolValue]) {
		NSURL *workingTreeURL = imageSource[PBNativeImageSourceWorkingTreeURLKey];
		NSData *data = [NSData dataWithContentsOfURL:[workingTreeURL URLByAppendingPathComponent:path]];
		if (data.length) return data;
	}
	for (NSString *revision in imageSource[PBNativeImageSourceRevisionsKey] ?: @[]) {
		NSString *object = [revision isEqualToString:@":"] ? [@":" stringByAppendingString:path] : [NSString stringWithFormat:@"%@:%@", revision, path];
		NSData *data = [self dataForGitObject:object imageSource:imageSource];
		if (data.length) return data;
	}
	return nil;
}

- (void)presentationChanged:(NSSegmentedControl *)sender
{
	[[NSUserDefaults standardUserDefaults] setInteger:sender.selectedSegment forKey:PBMultiCommitDiffPresentationKey];
	[self changeContentTo:self.displayedCommits];
}

- (void)refreshDisplayedContent
{
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
