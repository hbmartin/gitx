//
//  PBPrefsWindowController.m
//  GitX
//
//  Created by Christian Jacobsen on 02/10/2008.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import "PBPrefsWindowController.h"
#import "PBGitRepository.h"
#import "PBGitDefaults.h"

#define kPreferenceViewIdentifier @"PBGitXPreferenceViewIdentifier"

@interface PBPrefsWindowController ()
@property (nonatomic) NSView *historyAndFetchPrefsView;
@property (nonatomic) NSButton *historySortingCheckbox;
@property (nonatomic) NSPopUpButton *autoFetchScopePopup;
@property (nonatomic) NSTextField *autoFetchIntervalField;
@property (nonatomic) NSStepper *autoFetchIntervalStepper;
@end

@implementation PBPrefsWindowController

#pragma mark DBPrefsWindowController overrides

- (void)setupToolbar
{
	// GENERAL
	[self addView:generalPrefsView label:@"General" image:[NSImage imageNamed:NSImageNameApplicationIcon]];
	// INTERGRATION
	[self addView:integrationPrefsView label:@"Integration" image:[NSImage imageNamed:NSImageNameNetwork]];
	// UPDATES
	[self addView:updatesPrefsView label:@"Updates"];
	[self createHistoryAndFetchPreferencesIfNeeded];
	[self syncHistoryAndFetchPreferences];
	[self addView:self.historyAndFetchPrefsView
			label:@"History & Fetch"
			image:[NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath" accessibilityDescription:nil]];
}

- (NSTextField *)labelWithString:(NSString *)string frame:(NSRect)frame
{
	NSTextField *label = [NSTextField labelWithString:string];
	label.frame = frame;
	return label;
}

- (void)createHistoryAndFetchPreferencesIfNeeded
{
	if (self.historyAndFetchPrefsView) return;
	NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 270)];

	NSTextField *historyHeading = [self labelWithString:@"History" frame:NSMakeRect(40, 220, 440, 22)];
	historyHeading.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
	[view addSubview:historyHeading];

	self.historySortingCheckbox = [NSButton checkboxWithTitle:@"Allow commit columns to sort history" target:self action:@selector(historySortingChanged:)];
	self.historySortingCheckbox.frame = NSMakeRect(40, 188, 400, 24);
	[view addSubview:self.historySortingCheckbox];
	NSTextField *historyHelp = [self labelWithString:@"Turn this off to keep commits exclusively in Git graph order." frame:NSMakeRect(60, 164, 420, 20)];
	historyHelp.textColor = NSColor.secondaryLabelColor;
	[view addSubview:historyHelp];

	NSTextField *fetchHeading = [self labelWithString:@"Scheduled Fetch" frame:NSMakeRect(40, 126, 440, 22)];
	fetchHeading.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
	[view addSubview:fetchHeading];
	[view addSubview:[self labelWithString:@"Repositories:" frame:NSMakeRect(40, 92, 100, 24)]];
	self.autoFetchScopePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(142, 88, 270, 28) pullsDown:NO];
	NSArray<NSString *> *scopeTitles = @[ @"None", @"Active repository", @"All open repositories", @"Open and recent repositories" ];
	for (NSInteger scope = 0; scope < scopeTitles.count; scope++) {
		[self.autoFetchScopePopup addItemWithTitle:scopeTitles[scope]];
		self.autoFetchScopePopup.lastItem.tag = scope;
	}
	self.autoFetchScopePopup.target = self;
	self.autoFetchScopePopup.action = @selector(autoFetchScopeChanged:);
	[view addSubview:self.autoFetchScopePopup];

	[view addSubview:[self labelWithString:@"Every:" frame:NSMakeRect(40, 54, 100, 24)]];
	self.autoFetchIntervalField = [[NSTextField alloc] initWithFrame:NSMakeRect(142, 51, 70, 26)];
	NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
	formatter.minimum = @1;
	formatter.maximum = @1440;
	formatter.allowsFloats = NO;
	self.autoFetchIntervalField.formatter = formatter;
	self.autoFetchIntervalField.target = self;
	self.autoFetchIntervalField.action = @selector(autoFetchIntervalChanged:);
	[view addSubview:self.autoFetchIntervalField];
	self.autoFetchIntervalStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(214, 49, 20, 28)];
	self.autoFetchIntervalStepper.minValue = 1;
	self.autoFetchIntervalStepper.maxValue = 1440;
	self.autoFetchIntervalStepper.increment = 1;
	self.autoFetchIntervalStepper.target = self;
	self.autoFetchIntervalStepper.action = @selector(autoFetchIntervalChanged:);
	[view addSubview:self.autoFetchIntervalStepper];
	[view addSubview:[self labelWithString:@"minutes (1–1440)" frame:NSMakeRect(242, 54, 170, 24)]];

	NSTextField *fetchHelp = [self labelWithString:@"Fetches are noninteractive and never prune. A failure pauses only that repository until a successful manual fetch." frame:NSMakeRect(40, 17, 440, 34)];
	fetchHelp.maximumNumberOfLines = 2;
	fetchHelp.lineBreakMode = NSLineBreakByWordWrapping;
	fetchHelp.textColor = NSColor.secondaryLabelColor;
	[view addSubview:fetchHelp];

	self.historyAndFetchPrefsView = view;
}

- (void)syncHistoryAndFetchPreferences
{
	self.historySortingCheckbox.state = [PBGitDefaults historyColumnSortingEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
	[self.autoFetchScopePopup selectItemWithTag:[PBGitDefaults autoFetchScope]];
	NSInteger interval = [PBGitDefaults autoFetchIntervalMinutes];
	self.autoFetchIntervalField.integerValue = interval;
	self.autoFetchIntervalStepper.integerValue = interval;
	BOOL enabled = [PBGitDefaults autoFetchScope] != PBAutoFetchScopeNone;
	self.autoFetchIntervalField.enabled = enabled;
	self.autoFetchIntervalStepper.enabled = enabled;
}

- (IBAction)historySortingChanged:(NSButton *)sender
{
	[PBGitDefaults setHistoryColumnSortingEnabled:sender.state == NSControlStateValueOn];
}

- (IBAction)autoFetchScopeChanged:(NSPopUpButton *)sender
{
	[PBGitDefaults setAutoFetchScope:sender.selectedItem.tag];
	[self syncHistoryAndFetchPreferences];
}

- (IBAction)autoFetchIntervalChanged:(NSControl *)sender
{
	NSInteger interval = MAX(1, MIN(1440, sender.integerValue));
	[PBGitDefaults setAutoFetchIntervalMinutes:interval];
	self.autoFetchIntervalField.integerValue = interval;
	self.autoFetchIntervalStepper.integerValue = interval;
}

- (void)displayViewForIdentifier:(NSString *)identifier animate:(BOOL)animate
{
	[super displayViewForIdentifier:identifier animate:animate];

	[[NSUserDefaults standardUserDefaults] setObject:identifier forKey:kPreferenceViewIdentifier];
}

- (NSString *)defaultViewIdentifier
{
	NSString *identifier = [[NSUserDefaults standardUserDefaults] objectForKey:kPreferenceViewIdentifier];
	if (identifier)
		return identifier;

	return [super defaultViewIdentifier];
}

#pragma mark -
#pragma mark Delegate methods

- (IBAction)checkGitValidity:sender
{
	// FIXME: This does not work reliably, probably due to: http://www.cocoabuilder.com/archive/message/cocoa/2008/9/10/217850
	//[badGitPathIcon setHidden:[PBGitRepository validateGit:[[NSValueTransformer valueTransformerForName:@"PBNSURLPathUserDefaultsTransfomer"] reverseTransformedValue:[gitPathController URL]]]];
}

- (IBAction)resetGitPath:sender
{
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:@"gitExecutable"];
}

- (void)pathCell:(NSPathCell *)pathCell willDisplayOpenPanel:(NSOpenPanel *)openPanel
{
	[openPanel setCanChooseDirectories:NO];
	[openPanel setCanChooseFiles:YES];
	[openPanel setAllowsMultipleSelection:NO];
	[openPanel setTreatsFilePackagesAsDirectories:YES];
	[openPanel setAccessoryView:gitPathOpenAccessory];
	[openPanel setResolvesAliases:NO];
	//[[openPanel _navView] setShowsHiddenFiles:YES];

	gitPathOpenPanel = openPanel;
}

- (IBAction)resetAllDialogWarnings:(id)sender
{
	[PBGitDefaults resetAllDialogWarnings];
}

#pragma mark -
#pragma mark Git Path open panel actions

- (IBAction)showHideAllFiles:sender
{
	/* FIXME: This uses undocumented OpenPanel features to show hidden files! */
	NSNumber *showHidden = [NSNumber numberWithBool:[sender state] == NSControlStateValueOn];
	[[gitPathOpenPanel valueForKey:@"_navView"] setValue:showHidden forKey:@"showsHiddenFiles"];
}

@end
