#import "GLFileView.h"
#import "PBNativeContentView.h"
#import "PBGitGradientBarView.h"
#import "PBGitTree.h"
#import "PBWorkingTree.h"
#import "PBUncommittedChanges.h"
#import "PBGitCommit.h"
#import "PBGitHistoryController.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBGitIndex.h"
#import "PBChangedFile.h"
#import "PBTask.h"
#import "PBGitBinary.h"
#import "GitX-Swift.h"

static NSString *const PBEmptyTreeSHA = @"4b825dc642cb6eb9a060e54bf8d69288fbee4904";

typedef NS_ENUM(NSInteger, PBFileMode) {
	PBFileModeSource = 0,
	PBFileModeBlame = 1,
	PBFileModeHistory = 2,
	PBFileModeDiff = 3,
};

@interface GLFileView () <PBNativeContentViewDelegate>
@property (nonatomic) NSSegmentedControl *modeControl;
@property (nonatomic) dispatch_queue_t fileLoadQueue;
@property (nonatomic) NSUInteger fileLoadGeneration;
- (void)saveSplitViewPosition;
@end

@implementation GLFileView

- (void)awakeFromNib
{
	[super awakeFromNib];
	self.nativeView.delegate = self;
	self.fileLoadQueue = dispatch_queue_create("com.gitx.file-load", DISPATCH_QUEUE_CONCURRENT);
	[historyController.treeController addObserver:self
										  keyPath:@"selection"
										  options:0
											block:^(MAKVONotification *notification) {
												[notification.observer showFile];
											}];

	self.modeControl = [NSSegmentedControl segmentedControlWithLabels:@[ @"Source", @"Blame", @"History", @"Diff" ]
														 trackingMode:NSSegmentSwitchTrackingSelectOne
															   target:self
															   action:@selector(modeChanged:)];
	self.modeControl.selectedSegment = PBFileModeSource;
	self.modeControl.segmentStyle = NSSegmentStyleAutomatic;
	self.modeControl.controlSize = NSControlSizeSmall;
	self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
	[typeBar addSubview:self.modeControl];
	[(PBGitGradientBarView *)typeBar setTopShade:237 / 255.0f bottomShade:216 / 255.0f];
	[NSLayoutConstraint activateConstraints:@[
		[self.modeControl.centerXAnchor constraintEqualToAnchor:typeBar.centerXAnchor],
		[self.modeControl.centerYAnchor constraintEqualToAnchor:typeBar.centerYAnchor],
	]];

	[fileListSplitView setHidden:YES];
	[self performSelector:@selector(restoreSplitViewPositiion) withObject:nil afterDelay:0];
}

- (void)didLoad
{
	[self showFile];
}

- (void)modeChanged:(NSSegmentedControl *)sender
{
	[self showFile];
}

- (NSArray<NSDictionary *> *)historyEntriesForTree:(PBGitTree *)file
{
	NSString *separator = NSUUID.UUID.UUIDString;
	NSString *terminator = NSUUID.UUID.UUIDString;
	NSString *format = [[@"%h,%s,%aN,%ar,%H" stringByReplacingOccurrencesOfString:@"," withString:separator] stringByAppendingString:terminator];
	NSString *output = [file log:format] ?: @"";
	NSMutableArray *entries = [NSMutableArray array];
	for (NSString *raw in [output componentsSeparatedByString:terminator]) {
		NSArray<NSString *> *parts = [raw componentsSeparatedByString:separator];
		if (parts.count < 5) continue;
		[entries addObject:@{
			@"subject" : parts[1],
			@"author" : parts[2],
			@"date" : parts[3],
			@"sha" : [parts[4] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],
		}];
	}
	return entries;
}

- (NSString *)syntheticDiffForUntrackedFile:(PBChangedFile *)file
{
	NSString *contents = [historyController.repository.index diffForFile:file staged:NO contextLines:PBApplicationSettings.diffContextLines] ?: @"";
	return [PBSyntheticUntrackedDiffFormatter diffForPath:file.path contents:contents];
}

- (BOOL)isFileLoadGenerationCurrent:(NSUInteger)generation
{
	@synchronized(self) {
		return generation == self.fileLoadGeneration;
	}
}

- (NSDictionary<NSString *, id> *)imageSourceForRevisions:(NSArray<NSString *> *)revisions workingTree:(BOOL)workingTree
{
	NSAssert(NSThread.isMainThread, @"Image source state must be captured on the main thread");
	PBGitRepository *repository = historyController.repository;
	NSMutableDictionary<NSString *, id> *source = [@{
		PBNativeImageSourceRevisionsKey : revisions,
		PBNativeImageSourceWorkingTreeKey : @(workingTree),
	} mutableCopy];
	if (repository.workingDirectoryURL) source[PBNativeImageSourceWorkingTreeURLKey] = repository.workingDirectoryURL;
	if (PBGitBinary.path) source[PBNativeImageSourceGitLaunchPathKey] = PBGitBinary.path;
	if (repository.gitURL.path) source[PBNativeImageSourceGitDirectoryKey] = repository.gitURL.path;
	if (repository.workingDirectory) source[PBNativeImageSourceTaskDirectoryKey] = repository.workingDirectory;
	return source;
}

- (NSArray<NSDictionary *> *)diffSectionsForTrees:(NSArray<PBGitTree *> *)trees
									 workingState:(BOOL)workingState
										commitSHA:(NSString *)commitSHA
										parentSHA:(nullable NSString *)parentSHA
										  changes:(NSArray<PBChangedFile *> *)changes
									  imageSource:(NSDictionary<NSString *, id> *)imageSource
									   generation:(NSUInteger)generation
{
	NSMutableArray *sections = [NSMutableArray array];
	for (PBGitTree *tree in trees) {
		if (![self isFileLoadGenerationCurrent:generation]) return @[];
		if (!tree.leaf) continue;
		if (workingState) {
			PBChangedFile *change = nil;
			for (PBChangedFile *candidate in changes) {
				if ([candidate.path isEqualToString:tree.fullPath]) {
					change = candidate;
					break;
				}
			}
			if (!change) continue;
			if (change.hasStagedChanges) {
				[sections addObject:@{PBNativeSectionTitleKey : [NSString stringWithFormat:@"Staged — %@", tree.fullPath], PBNativeSectionTextKey : [historyController.repository.index diffForFile:change staged:YES contextLines:PBApplicationSettings.diffContextLines] ?: @"", PBNativeSectionContextKey : @"readOnly", PBNativeSectionImageSourceKey : imageSource}];
			}
			if (change.hasUnstagedChanges) {
				BOOL untracked = change.status == NEW && !change.hasStagedChanges;
				NSString *diffText = untracked ? [self syntheticDiffForUntrackedFile:change] : [historyController.repository.index diffForFile:change staged:NO contextLines:PBApplicationSettings.diffContextLines];
				[sections addObject:@{PBNativeSectionTitleKey : [NSString stringWithFormat:@"Unstaged — %@", tree.fullPath], PBNativeSectionTextKey : diffText ?: @"", PBNativeSectionContextKey : @"readOnly", PBNativeSectionImageSourceKey : imageSource}];
			}
		} else {
			NSString *base = parentSHA ?: PBEmptyTreeSHA;
			NSError *error = nil;
			NSMutableArray<NSString *> *arguments = [@[ @"diff" ] mutableCopy];
			[arguments addObjectsFromArray:PBDiffCommandOptions.arguments];
			[arguments addObjectsFromArray:@[ @"--find-renames", @"--no-ext-diff", base, commitSHA, @"--", tree.fullPath ]];
			NSString *patch = [historyController.repository outputOfTaskWithArguments:arguments error:&error] ?: @"";
			[sections addObject:@{PBNativeSectionTitleKey : tree.fullPath, PBNativeSectionTextKey : patch, PBNativeSectionContextKey : @"readOnly", PBNativeSectionImageSourceKey : imageSource}];
		}
	}
	return sections;
}

- (void)showFile
{
	NSArray<PBGitTree *> *selected = [historyController.treeController.selectedObjects copy];
	NSUInteger generation;
	@synchronized(self) {
		generation = ++self.fileLoadGeneration;
	}
	if (selected.count == 0) {
		[self.nativeView showMessage:@"No file selected"];
		return;
	}
	PBFileMode mode = self.modeControl.selectedSegment;
	PBGitCommit *commit = historyController.selectedCommits.firstObject;
	BOOL workingState = [commit isKindOfClass:PBUncommittedChanges.class];
	NSString *commitSHA = commit.SHA ?: @"";
	NSString *parentSHA = commit.parents.firstObject.SHA;
	NSArray<NSString *> *imageRevisions = [PBImageRevisionPolicy revisionsForCommitSHA:commitSHA
																			 parentSHA:parentSHA
																		  workingState:workingState];
	NSDictionary<NSString *, id> *imageSource = [self imageSourceForRevisions:imageRevisions workingTree:workingState];
	NSArray<PBChangedFile *> *changes = [historyController.repository.index.indexChanges copy];
	dispatch_async(self.fileLoadQueue, ^{
		if (![self isFileLoadGenerationCurrent:generation]) return;
		NSMutableArray *sections = [NSMutableArray array];
		for (PBGitTree *file in selected) {
			if (![self isFileLoadGenerationCurrent:generation]) return;
			if (!file.leaf) continue;
			if (mode == PBFileModeSource || mode == PBFileModeBlame) {
				[sections addObject:@{
					PBNativeSectionTitleKey : file.fullPath ?: file.path,
					PBNativeSectionPathKey : file.fullPath ?: file.path,
					PBNativeSectionTextKey : mode == PBFileModeSource ? (file.textContents ?: @"") : (file.blame ?: @""),
				}];
			} else if (mode == PBFileModeHistory) {
				[sections addObject:@{PBNativeSectionTitleKey : file.fullPath ?: file.path, PBNativeSectionEntriesKey : [self historyEntriesForTree:file]}];
			}
		}
		if (mode == PBFileModeDiff)
			sections = [[self diffSectionsForTrees:selected workingState:workingState commitSHA:commitSHA parentSHA:parentSHA changes:changes imageSource:imageSource generation:generation] mutableCopy];
		if (mode == PBFileModeDiff)
			sections = [[PBNativeDiffSectionSettings applyToSections:sections repository:self->historyController.repository] mutableCopy];
		if (![self isFileLoadGenerationCurrent:generation]) return;
		dispatch_async(dispatch_get_main_queue(), ^{
			if (![self isFileLoadGenerationCurrent:generation]) return;
			if (sections.count == 0) {
				[self.nativeView showMessage:@"Select one or more files to view this mode."];
			} else if (mode == PBFileModeSource) {
				[self.nativeView showSourceSections:sections];
			} else if (mode == PBFileModeBlame) {
				[self.nativeView showBlameSections:sections];
			} else if (mode == PBFileModeHistory) {
				[self.nativeView showHistorySections:sections];
			} else {
				[self.nativeView showDiffSections:sections];
			}
		});
	});
}

- (void)nativeContentView:(PBNativeContentView *)view selectCommit:(NSString *)sha
{
	[historyController selectCommit:[GTOID oidWithSHA:sha]];
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
	NSString *launchPath = imageSource[PBNativeImageSourceGitLaunchPathKey];
	NSString *gitDirectory = imageSource[PBNativeImageSourceGitDirectoryKey];
	if (!launchPath.length || !gitDirectory.length) return nil;
	for (NSString *revision in imageSource[PBNativeImageSourceRevisionsKey] ?: @[]) {
		NSString *object = [revision isEqualToString:@":"] ? [@":" stringByAppendingString:path] : [NSString stringWithFormat:@"%@:%@", revision, path];
		NSArray<NSString *> *arguments = @[ [@"--git-dir=" stringByAppendingString:gitDirectory], @"show", object ];
		PBTask *task = [PBTask taskWithLaunchPath:launchPath arguments:arguments inDirectory:imageSource[PBNativeImageSourceTaskDirectoryKey]];
		if ([task launchTask:nil] && task.standardOutputData.length) return task.standardOutputData;
	}
	return nil;
}

- (void)closeView
{
	@synchronized(self) {
		self.fileLoadGeneration++;
	}
	[self saveSplitViewPosition];
	[super closeView];
}

#define kFileListSplitViewLeftMin 120
#define kFileListSplitViewRightMin 180
#define kHFileListSplitViewPositionDefault @"File List SplitView Position"

- (CGFloat)splitView:(NSSplitView *)splitView constrainMinCoordinate:(CGFloat)proposedMin ofSubviewAt:(NSInteger)dividerIndex
{
	return kFileListSplitViewLeftMin;
}
- (CGFloat)splitView:(NSSplitView *)splitView constrainMaxCoordinate:(CGFloat)proposedMax ofSubviewAt:(NSInteger)dividerIndex
{
	return splitView.frame.size.width - splitView.dividerThickness - kFileListSplitViewRightMin;
}

- (void)splitView:(NSSplitView *)splitView resizeSubviewsWithOldSize:(NSSize)oldSize
{
	NSRect newFrame = splitView.frame;
	CGFloat dividerThickness = splitView.dividerThickness;
	NSView *leftView = splitView.subviews[0];
	NSRect leftFrame = leftView.frame;
	leftFrame.size.height = newFrame.size.height;
	if (newFrame.size.width - leftFrame.size.width - dividerThickness < kFileListSplitViewRightMin)
		leftFrame.size.width = newFrame.size.width - kFileListSplitViewRightMin - dividerThickness;
	NSView *rightView = splitView.subviews[1];
	NSRect rightFrame = rightView.frame;
	rightFrame.origin.x = leftFrame.size.width + dividerThickness;
	rightFrame.size.width = newFrame.size.width - rightFrame.origin.x;
	rightFrame.size.height = newFrame.size.height;
	leftView.frame = leftFrame;
	rightView.frame = rightFrame;
}

- (void)saveSplitViewPosition
{
	CGFloat position = [fileListSplitView.subviews[0] frame].size.width;
	[[NSUserDefaults standardUserDefaults] setDouble:position forKey:kHFileListSplitViewPositionDefault];
}

- (void)restoreSplitViewPositiion
{
	CGFloat position = [[NSUserDefaults standardUserDefaults] doubleForKey:kHFileListSplitViewPositionDefault];
	if (position < 1.0) position = 200;
	[fileListSplitView setPosition:position ofDividerAtIndex:0];
	[fileListSplitView setHidden:NO];
}

@end
