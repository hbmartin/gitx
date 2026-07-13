#import "PBWebDiffController.h"
#import "PBNativeContentView.h"
#import "PBGitCommit.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBTask.h"

@interface PBWebDiffController () <PBNativeContentViewDelegate>
@end

@implementation PBWebDiffController

- (void)awakeFromNib
{
	startFile = @"diff";
	[super awakeFromNib];
	self.nativeView.delegate = self;
	[diffController addObserver:self
					 keyPath:@"diff"
					 options:0
					   block:^(MAKVONotification *notification) {
		PBDiffWindowController *target = notification.target;
		[notification.observer showDiff:target.diff];
	}];
}

- (NSImage *)nativeContentView:(PBNativeContentView *)view imageForPath:(NSString *)path section:(NSUInteger)sectionIndex
{
	PBGitCommit *commit = diffController.diffCommit;
	if (!commit.SHA.length) return nil;
	PBTask *task = [commit.repository taskWithArguments:@[ @"show", [NSString stringWithFormat:@"%@:%@", commit.SHA, path] ]];
	if (![task launchTask:nil]) return nil;
	return [[NSImage alloc] initWithData:task.standardOutputData];
}

- (void)didLoad
{
	[self showDiff:diffController.diff];
}

- (void)showDiff:(NSString *)diff
{
	if (!finishedLoading || diff == nil) return;
	if (diff.length == 0) [self.nativeView showMessage:@"There are no differences"];
	else [self.nativeView showDiffSections:@[@{
		PBNativeSectionTitleKey : @"Diff",
		PBNativeSectionTextKey : diff,
		PBNativeSectionContextKey : @"readOnly",
	}]];
}

@end
