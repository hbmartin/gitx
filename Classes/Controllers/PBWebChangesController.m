#import "PBWebChangesController.h"
#import "PBGitIndex.h"
#import "PBNativeContentView.h"
#import "PBGitRepository.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBTask.h"

static void *const UnstagedFileSelectedContext = @"UnstagedFileSelectedContext";
static void *const CachedFileSelectedContext = @"CachedFileSelectedContext";

@interface PBRefreshCoalescer : NSObject
- (instancetype)initWithDeliveryHandler:(void (^)(void))deliveryHandler;
- (void)requestRefresh;
- (void)cancel;
@end

@interface PBWebChangesController () <PBNativeContentViewDelegate>
@property (nonatomic) NSUInteger contextLines;
@property (nonatomic) NSTextField *contextValueLabel;
@property (nonatomic) PBRefreshCoalescer *refreshCoalescer;
@end

@implementation PBWebChangesController

- (void)awakeFromNib
{
	[super awakeFromNib];
	self.nativeView.delegate = self;
	__weak typeof(self) weakSelf = self;
	self.refreshCoalescer = [[PBRefreshCoalescer alloc] initWithDeliveryHandler:^{
		[weakSelf refresh];
	}];
	NSNumber *savedContext = [[NSUserDefaults standardUserDefaults] objectForKey:@"PBStageDiffContextLines"];
	self.contextLines = savedContext ? savedContext.unsignedIntegerValue : 3;
	NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 34)];
	NSStackView *controls = [NSStackView stackViewWithViews:@[]];
	controls.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	controls.spacing = 6;
	controls.translatesAutoresizingMaskIntoConstraints = NO;
	[accessory addSubview:controls];
	[NSLayoutConstraint activateConstraints:@[
		[accessory.heightAnchor constraintEqualToConstant:34],
		[controls.centerXAnchor constraintEqualToAnchor:accessory.centerXAnchor],
		[controls.centerYAnchor constraintEqualToAnchor:accessory.centerYAnchor],
	]];
	[controls addArrangedSubview:[NSTextField labelWithString:NSLocalizedString(@"Context:", @"Label for the number of surrounding lines shown in a diff")]];
	self.contextValueLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%lu lines", (unsigned long)self.contextLines]];
	self.contextValueLabel.alignment = NSTextAlignmentRight;
	[self.contextValueLabel.widthAnchor constraintEqualToConstant:52].active = YES;
	[controls addArrangedSubview:self.contextValueLabel];
	NSStepper *stepper = [[NSStepper alloc] init];
	stepper.minValue = 0;
	stepper.maxValue = 50;
	stepper.integerValue = self.contextLines;
	stepper.target = self;
	stepper.action = @selector(contextLinesChanged:);
	[controls addArrangedSubview:stepper];
	[self.nativeView setAccessoryView:accessory];
	[unstagedFilesController addObserver:self forKeyPath:@"selection" options:0 context:UnstagedFileSelectedContext];
	[stagedFilesController addObserver:self forKeyPath:@"selection" options:0 context:CachedFileSelectedContext];
}

- (void)contextLinesChanged:(NSStepper *)sender
{
	self.contextLines = sender.integerValue;
	self.contextValueLabel.stringValue = [NSString stringWithFormat:@"%lu lines", (unsigned long)self.contextLines];
	[[NSUserDefaults standardUserDefaults] setInteger:self.contextLines forKey:@"PBStageDiffContextLines"];
	[self refresh];
}

- (void)closeView
{
	[self.refreshCoalescer cancel];
	self.refreshCoalescer = nil;
	[unstagedFilesController removeObserver:self forKeyPath:@"selection"];
	[stagedFilesController removeObserver:self forKeyPath:@"selection"];
	[super closeView];
}

- (void)didLoad
{
	[self refresh];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (context == UnstagedFileSelectedContext || context == CachedFileSelectedContext) {
		[self.refreshCoalescer requestRefresh];
		return;
	}
	[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (NSDictionary *)sectionForFile:(PBChangedFile *)file staged:(BOOL)staged
{
	NSString *diff = [controller.index diffForFile:file staged:staged contextLines:self.contextLines] ?: @"";
	return @{
		PBNativeSectionTitleKey : [NSString stringWithFormat:@"%@ — %@", staged ? @"Staged" : @"Unstaged", file.path],
		PBNativeSectionPathKey : file.path ?: @"",
		PBNativeSectionTextKey : diff,
		PBNativeSectionContextKey : staged ? @"staged" : @"unstaged",
	};
}

- (void)refresh
{
	if (!finishedLoading) return;
	NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
	for (PBChangedFile *file in stagedFilesController.selectedObjects) [sections addObject:[self sectionForFile:file staged:YES]];
	for (PBChangedFile *file in unstagedFilesController.selectedObjects) [sections addObject:[self sectionForFile:file staged:NO]];
	NSLog(@"[GitX] Rendering %lu selected stage-diff sections", (unsigned long)sections.count);
	if (sections.count == 0)
		[self.nativeView showMessage:@"No file selected"];
	else
		[self.nativeView showDiffSections:sections];
}

- (void)showMultiple:(NSArray *)files
{
	[self refresh];
}

- (void)setStateMessage:(NSString *)state
{
	[self.nativeView showMessage:state ?: @""];
}

- (void)nativeContentView:(PBNativeContentView *)view performDiffAction:(NSString *)action patch:(NSString *)patch
{
	if ([action isEqualToString:@"stage"]) {
		NSLog(@"[GitX] Applying a partial stage patch");
		[controller.index applyPatch:patch stage:YES reverse:NO];
	} else if ([action isEqualToString:@"unstage"]) {
		NSLog(@"[GitX] Applying a partial unstage patch");
		[controller.index applyPatch:patch stage:YES reverse:YES];
	} else if ([action isEqualToString:@"discard"]) {
		NSAlert *alert = [[NSAlert alloc] init];
		alert.messageText = NSLocalizedString(@"Discard hunk", @"");
		alert.informativeText = NSLocalizedString(@"Are you sure you wish to discard this hunk? This operation cannot be undone.", @"");
		[alert addButtonWithTitle:NSLocalizedString(@"Discard", @"")];
		[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"")];
		[alert beginSheetModalForWindow:self.view.window
					  completionHandler:^(NSModalResponse response) {
						  if (response == NSAlertFirstButtonReturn) {
							  [self->controller.index applyPatch:patch stage:NO reverse:YES];
						  }
					  }];
	}
}

- (NSImage *)nativeContentView:(PBNativeContentView *)view imageForPath:(NSString *)path section:(NSUInteger)sectionIndex
{
	PBGitRepository *workingRepository = controller.repository;
	NSData *data = [NSData dataWithContentsOfURL:[workingRepository.workingDirectoryURL URLByAppendingPathComponent:path]];
	if (!data.length) {
		PBTask *task = [workingRepository taskWithArguments:@[ @"show", [@":" stringByAppendingString:path] ]];
		if ([task launchTask:nil]) data = task.standardOutputData;
	}
	return data.length ? [[NSImage alloc] initWithData:data] : nil;
}

@end
