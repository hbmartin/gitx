//
//  PBGitDefaults.h
//  GitX
//
//  Created by Jeff Mesnil on 19/10/08.
//  Copyright 2008 Jeff Mesnil (http://jmesnil.net/). All rights reserved.
//

#define kDialogAcceptDroppedRef @"Accept Dropped Ref"

typedef NS_ENUM(NSInteger, PBAutoFetchScope) {
	PBAutoFetchScopeNone = 0,
	PBAutoFetchScopeActiveRepository = 1,
	PBAutoFetchScopeOpenRepositories = 2,
	PBAutoFetchScopeOpenAndRecentRepositories = 3,
};

extern NSString *const PBGitHistorySortingPreferenceDidChangeNotification;
extern NSString *const PBAutoFetchPreferencesDidChangeNotification;

@interface PBGitDefaults : NSObject {
}

+ (NSInteger)commitMessageViewVerticalLineLength;
+ (NSInteger)commitMessageViewVerticalBodyLineLength;
+ (BOOL)commitMessageViewHasVerticalLine;
+ (BOOL)isGistEnabled;
+ (BOOL)isGravatarEnabled;
+ (BOOL)confirmPublicGists;
+ (BOOL)isGistPublic;
+ (BOOL)showWhitespaceDifferences;
+ (BOOL)shouldCheckoutBranch;
+ (void)setShouldCheckoutBranch:(BOOL)shouldCheckout;
+ (NSString *)recentCloneDestination;
+ (void)setRecentCloneDestination:(NSString *)path;
+ (BOOL)showStageView;
+ (void)setShowStageView:(BOOL)suppress;
+ (NSInteger)branchFilter;
+ (void)setBranchFilter:(NSInteger)state;
+ (NSInteger)historySearchMode;
+ (void)setHistorySearchMode:(NSInteger)mode;
+ (BOOL)useRepositoryWatcher;
+ (NSString *)terminalHandler;
+ (BOOL)historyColumnSortingEnabled;
+ (void)setHistoryColumnSortingEnabled:(BOOL)enabled;
+ (PBAutoFetchScope)autoFetchScope;
+ (void)setAutoFetchScope:(PBAutoFetchScope)scope;
+ (NSInteger)autoFetchIntervalMinutes;
+ (void)setAutoFetchIntervalMinutes:(NSInteger)minutes;
+ (BOOL)notifyAboutFetchedCommitsForRepositoryURL:(NSURL *)repositoryURL;
+ (void)setNotifyAboutFetchedCommits:(BOOL)enabled forRepositoryURL:(NSURL *)repositoryURL;


// Suppressed Dialog Warnings
+ (void)suppressDialogWarningForDialog:(NSString *)dialog;
+ (BOOL)isDialogWarningSuppressedForDialog:(NSString *)dialog;
+ (void)resetAllDialogWarnings;

@end
