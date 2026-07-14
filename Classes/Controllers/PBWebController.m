#import "PBWebController.h"
#import "PBNativeContentView.h"

@interface PBWebController ()
@property (nonatomic, readwrite) PBNativeContentView *nativeView;
@end

@implementation PBWebController

@synthesize repository;

- (void)awakeFromNib
{
	self.nativeView = [[PBNativeContentView alloc] initWithFrame:self.view.bounds];
	self.nativeView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	self.nativeView.translatesAutoresizingMaskIntoConstraints = YES;
	[self.view addSubview:self.nativeView positioned:NSWindowAbove relativeTo:nil];
	self.nativeView.frame = self.view.bounds;

	[[NSNotificationCenter defaultCenter] addObserver:self
							 selector:@selector(preferencesChangedWithNotification:)
								 name:NSUserDefaultsDidChangeNotification
							  object:nil];
	finishedLoading = YES;
	dispatch_async(dispatch_get_main_queue(), ^{ [self didLoad]; });
}

- (void)didLoad
{
}

- (void)closeView
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self.nativeView removeFromSuperview];
	self.nativeView = nil;
}

- (void)preferencesChanged
{
}

- (void)preferencesChangedWithNotification:(NSNotification *)notification
{
	[self preferencesChanged];
}

@end
