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

static NSString *const PBEmptyTreeSHA = @"4b825dc642cb6eb9a060e54bf8d69288fbee4904";

typedef NS_ENUM(NSInteger, PBFileMode) {
	PBFileModeSource = 0,
	PBFileModeBlame = 1,
	PBFileModeHistory = 2,
	PBFileModeDiff = 3,
};

@interface GLFileView () <PBNativeContentViewDelegate>
@property (nonatomic) NSSegmentedControl *modeControl;
- (void)saveSplitViewPosition;
@end

@implementation GLFileView

- (void)awakeFromNib
{
	startFile = @"fileview";
	[super awakeFromNib];
	self.nativeView.delegate = self;
	[historyController.treeController addObserver:self keyPath:@"selection" options:0 block:^(MAKVONotification *notification) {
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
	[(PBGitGradientBarView *)typeBar setTopShade:237/255.0f bottomShade:216/255.0f];
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
			@"subject" : parts[1], @"author" : parts[2], @"date" : parts[3],
			@"sha" : [parts[4] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],
		}];
	}
	return entries;
}

- (NSString *)syntheticDiffForUntrackedFile:(PBChangedFile *)file
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

- (NSArray<NSDictionary *> *)diffSectionsForTrees:(NSArray<PBGitTree *> *)trees
{
	NSMutableArray *sections = [NSMutableArray array];
	PBGitCommit *commit = historyController.selectedCommits.firstObject;
	BOOL workingState = [commit isKindOfClass:PBUncommittedChanges.class];
	for (PBGitTree *tree in trees) {
		if (!tree.leaf) continue;
		if (workingState) {
			PBChangedFile *change = nil;
			for (PBChangedFile *candidate in historyController.repository.index.indexChanges) {
				if ([candidate.path isEqualToString:tree.fullPath]) { change = candidate; break; }
			}
			if (!change) continue;
			if (change.hasStagedChanges) {
				[sections addObject:@{ PBNativeSectionTitleKey : [NSString stringWithFormat:@"Staged — %@", tree.fullPath], PBNativeSectionTextKey : [historyController.repository.index diffForFile:change staged:YES contextLines:3] ?: @"", PBNativeSectionContextKey : @"readOnly" }];
			}
			if (change.hasUnstagedChanges) {
				NSString *diffText = change.status == NEW ? [self syntheticDiffForUntrackedFile:change] : [historyController.repository.index diffForFile:change staged:NO contextLines:3];
				[sections addObject:@{ PBNativeSectionTitleKey : [NSString stringWithFormat:@"Unstaged — %@", tree.fullPath], PBNativeSectionTextKey : diffText ?: @"", PBNativeSectionContextKey : @"readOnly" }];
			}
		} else {
			NSString *base = commit.parents.firstObject.SHA ?: PBEmptyTreeSHA;
			NSError *error = nil;
			NSString *patch = [historyController.repository outputOfTaskWithArguments:@[ @"diff", @"--find-renames", @"--no-ext-diff", base, commit.SHA, @"--", tree.fullPath ] error:&error] ?: @"";
			[sections addObject:@{ PBNativeSectionTitleKey : tree.fullPath, PBNativeSectionTextKey : patch, PBNativeSectionContextKey : @"readOnly" }];
		}
	}
	return sections;
}

- (void)showFile
{
	NSArray<PBGitTree *> *selected = historyController.treeController.selectedObjects;
	if (selected.count == 0) {
		[self.nativeView showMessage:@"No file selected"];
		return;
	}
	PBFileMode mode = self.modeControl.selectedSegment;
	NSMutableArray *sections = [NSMutableArray array];
	for (PBGitTree *file in selected) {
		if (!file.leaf) continue;
		if (mode == PBFileModeSource || mode == PBFileModeBlame) {
			[sections addObject:@{
				PBNativeSectionTitleKey : file.fullPath ?: file.path,
				PBNativeSectionPathKey : file.fullPath ?: file.path,
				PBNativeSectionTextKey : mode == PBFileModeSource ? (file.textContents ?: @"") : (file.blame ?: @""),
			}];
		} else if (mode == PBFileModeHistory) {
			[sections addObject:@{ PBNativeSectionTitleKey : file.fullPath ?: file.path, PBNativeSectionEntriesKey : [self historyEntriesForTree:file] }];
		}
	}
	if (mode == PBFileModeDiff) sections = [[self diffSectionsForTrees:selected] mutableCopy];
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
}

- (void)nativeContentView:(PBNativeContentView *)view selectCommit:(NSString *)sha
{
	[historyController selectCommit:[GTOID oidWithSHA:sha]];
}

- (NSImage *)nativeContentView:(PBNativeContentView *)view imageForPath:(NSString *)path section:(NSUInteger)sectionIndex
{
	PBGitCommit *commit = historyController.selectedCommits.firstObject;
	NSData *data = nil;
	if ([commit isKindOfClass:PBUncommittedChanges.class]) {
		data = [NSData dataWithContentsOfURL:[historyController.repository.workingDirectoryURL URLByAppendingPathComponent:path]];
	} else if (commit.SHA.length) {
		PBTask *task = [historyController.repository taskWithArguments:@[ @"show", [NSString stringWithFormat:@"%@:%@", commit.SHA, path] ]];
		if ([task launchTask:nil]) data = task.standardOutputData;
	}
	return data.length ? [[NSImage alloc] initWithData:data] : nil;
}

- (void)closeView
{
	[self saveSplitViewPosition];
	[super closeView];
}

#define kFileListSplitViewLeftMin 120
#define kFileListSplitViewRightMin 180
#define kHFileListSplitViewPositionDefault @"File List SplitView Position"

- (CGFloat)splitView:(NSSplitView *)splitView constrainMinCoordinate:(CGFloat)proposedMin ofSubviewAt:(NSInteger)dividerIndex { return kFileListSplitViewLeftMin; }
- (CGFloat)splitView:(NSSplitView *)splitView constrainMaxCoordinate:(CGFloat)proposedMax ofSubviewAt:(NSInteger)dividerIndex { return splitView.frame.size.width - splitView.dividerThickness - kFileListSplitViewRightMin; }

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
