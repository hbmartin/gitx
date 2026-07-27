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

typedef NS_ENUM(NSInteger, PBAppearancePreference) {
	PBAppearancePreferenceAutomatic = 0,
	PBAppearancePreferenceLight = 1,
	PBAppearancePreferenceDark = 2,
};

NS_ASSUME_NONNULL_BEGIN

extern NSString *const PBGitHistorySortingPreferenceDidChangeNotification;
extern NSString *const PBAutoFetchPreferencesDidChangeNotification;
extern NSString *const PBAppearancePreferenceDidChangeNotification;

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
+ (nullable NSString *)recentCloneDestination;
+ (void)setRecentCloneDestination:(NSString *)path;
+ (NSInteger)branchFilter;
+ (void)setBranchFilter:(NSInteger)state;
+ (NSInteger)historySearchMode;
+ (void)setHistorySearchMode:(NSInteger)mode;
+ (BOOL)useRepositoryWatcher;
+ (nullable NSString *)terminalHandler;
+ (PBAppearancePreference)appearancePreference;
+ (void)setAppearancePreference:(PBAppearancePreference)preference;
+ (BOOL)historyColumnSortingEnabled;
+ (void)setHistoryColumnSortingEnabled:(BOOL)enabled;
+ (PBAutoFetchScope)autoFetchScope;
+ (void)setAutoFetchScope:(PBAutoFetchScope)scope;
+ (NSInteger)autoFetchIntervalMinutes;
+ (void)setAutoFetchIntervalMinutes:(NSInteger)minutes;
+ (BOOL)notifyAboutFetchedCommitsForRepositoryURL:(nullable NSURL *)repositoryURL;
+ (void)setNotifyAboutFetchedCommits:(BOOL)enabled forRepositoryURL:(nullable NSURL *)repositoryURL;


// Suppressed Dialog Warnings
+ (void)suppressDialogWarningForDialog:(NSString *)dialog;
+ (BOOL)isDialogWarningSuppressedForDialog:(NSString *)dialog;
+ (void)resetAllDialogWarnings;

@end

NS_ASSUME_NONNULL_END
