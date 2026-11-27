#import "PBWebDiffController.h"
#import "PBNativeContentView.h"
#import "PBGitCommit.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBTask.h"
#import "PBGitBinary.h"
#import "GitX-Swift.h"

@interface PBWebDiffController () <PBNativeContentViewDelegate>
@end

@implementation PBWebDiffController

- (void)awakeFromNib
{
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
	NSString *launchPath = [PBGitBinary path];
	NSData *data = launchPath ? [PBLFSContentResolver displayDataForData:task.standardOutputData
																	path:path
														   gitLaunchPath:launchPath
															gitDirectory:commit.repository.gitURL.path
														workingDirectory:commit.repository.workingDirectoryURL.path] :
								task.standardOutputData;
	return data ? [[NSImage alloc] initWithData:data] : nil;
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
