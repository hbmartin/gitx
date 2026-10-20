#import <Cocoa/Cocoa.h>
#import "PBSourceViewItem.h"
#import "PBGitWindowControllerCompatibility.h"

@class PBGitRepository;
@class PBGitRef;
@class PBTask;

NS_ASSUME_NONNULL_BEGIN

typedef void(NS_SWIFT_SENDABLE ^ PBWorktreePreparationObserver)(void);

@interface PBWorktreePrunePreview : NSObject
@property (readonly, copy) NSString *report;
@property (readonly) BOOL hasMovedWorktrees;
@end

@interface PBWorktreeRepairPreview : NSObject
@property (readonly, copy) NSArray<NSString *> *paths;
@property (readonly, copy) NSArray<NSString *> *reclaimPaths;
@property (readonly) BOOL requiresReclaim;
@end

@interface PBWorktreeLifecycleDiagnostics : NSObject
+ (NSString *)publicEventWithArguments:(NSArray<NSString *> *)arguments stage:(NSString *)stage phase:(NSString *)phase count:(NSInteger)count category:(NSString *)category NS_SWIFT_NAME(publicEvent(arguments:stage:phase:count:category:));
@end

/// Narrow mirrors of the generated Swift interface for app-hosted XCTest.
@interface PBGitWorktree : NSObject
@property (readonly, copy) NSString *path;
@property (readonly, copy, nullable) NSString *branchRefName;
@property (readonly, copy, nullable) NSString *headRefName;
@property (readonly) BOOL isMain;
@property (readonly) BOOL isCurrent;
@property (readonly) BOOL isLocked;
@property (readonly) BOOL folderExists;
@property (readonly) BOOL hasBrokenLink;
@property (readonly, copy, nullable) NSString *movedPath;
@property (readonly, copy, nullable) NSString *lockReason;
@end

NS_SWIFT_UI_ACTOR
@interface PBRepositoryWorktreeService : NSObject
#if DEBUG
@property (readonly) uint64_t repairPreparationCount;
@property (copy, nullable) void (NS_SWIFT_UI_ACTOR ^repairPreparationResultObserver)(void);
@property (copy, nullable) PBWorktreePreparationObserver preferenceFingerprintObserver;
@property (copy, nullable) void (NS_SWIFT_UI_ACTOR ^preferenceFingerprintResultObserver)(void);
@property (copy, nullable) void (NS_SWIFT_UI_ACTOR ^acceptedDiscoveryObserver)(void);
#endif
@property (readonly, copy) NSArray<PBGitWorktree *> *worktrees;
@property (readonly, copy, nullable) NSString *gitVersion;
@property (readonly) BOOL isSupported;
@property (readonly) BOOL hasPublishedSnapshot;
@property (readonly) NSInteger inventoryStatus;
@property (readonly, copy) NSString *explanation;
- (instancetype)initWithRepository:(PBGitRepository *)repository taskFactory:(PBTask *(^)(NSArray<NSString *> *))factory;
#if DEBUG
- (instancetype)initWithRepository:(PBGitRepository *)repository taskFactory:(PBTask *(^)(NSArray<NSString *> *))factory repairPreparationObserver:(PBWorktreePreparationObserver)observer;
#endif
- (void)start;
- (void)refresh;
- (void)cancel;
- (nullable PBGitWorktree *)worktreeForBranch:(NSString *)ref NS_SWIFT_NAME(worktree(forBranch:));
- (void)addWorktreeAtPath:(NSString *)path branch:(NSString *)branch createBranch:(BOOL)createBranch completion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion NS_SWIFT_NAME(addWorktree(path:branch:createBranch:completion:));
- (void)removeWorktreeAtPath:(NSString *)path force:(BOOL)force completion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion NS_SWIFT_NAME(removeWorktree(path:force:completion:));
- (void)lockWorktreeAtPath:(NSString *)path reason:(NSString *)reason completion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion NS_SWIFT_NAME(lockWorktree(path:reason:completion:));
- (void)unlockWorktreeAtPath:(NSString *)path completion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion NS_SWIFT_NAME(unlockWorktree(path:completion:));
- (void)pruneWorktreesReportOnly:(BOOL)reportOnly completion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion NS_SWIFT_NAME(pruneWorktrees(reportOnly:completion:));
- (void)preparePrunePreviewWithCompletion:(void (^)(PBWorktreePrunePreview *_Nullable, NSError *_Nullable))completion NS_SWIFT_NAME(preparePrunePreview(completion:));
- (void)pruneWithConfirmedPreview:(PBWorktreePrunePreview *)preview completion:(void (^)(PBWorktreePrunePreview *_Nullable, NSError *_Nullable))completion NS_SWIFT_NAME(prune(confirmedPreview:completion:));
- (void)discardPrunePreview:(PBWorktreePrunePreview *)preview;
- (void)prepareRepairWorktree:(PBGitWorktree *)worktree movedTo:(NSString *)path completion:(void (^)(PBWorktreeRepairPreview *_Nullable, NSError *_Nullable))completion NS_SWIFT_NAME(prepareRepair(worktree:movedTo:completion:));
- (void)prepareRepairLinksWithRelativePaths:(BOOL)relative completion:(void (^)(PBWorktreeRepairPreview *_Nullable, NSError *_Nullable))completion NS_SWIFT_NAME(prepareRepairLinks(relativePaths:completion:));
- (void)repairWithConfirmedPreview:(PBWorktreeRepairPreview *)preview completion:(void (^)(PBWorktreeRepairPreview *_Nullable, NSError *_Nullable))completion NS_SWIFT_NAME(repair(confirmedPreview:completion:));
- (void)discardRepairPreview:(PBWorktreeRepairPreview *)preview;

@end

@interface PBRepositoryWatchPaths : NSObject
- (instancetype)initWithGitDirectory:(NSString *)gitDirectory commonDirectory:(NSString *)commonDirectory workingDirectory:(nullable NSString *)workingDirectory;
- (NSInteger)categoryForPath:(NSString *)path NS_SWIFT_NAME(category(for:));
@end

@interface PBSourceViewGitWorktreeItem : PBSourceViewItem
@property (readonly, strong) PBGitWorktree *worktree;
@property (readonly, copy) NSData *identity;
@end

@interface PBHistoryMenuBuilder : NSObject
- (instancetype)initWithRepository:(PBGitRepository *)repository;
- (nullable NSArray<NSMenuItem *> *)menuItemsForRef:(nullable PBGitRef *)ref NS_SWIFT_NAME(menuItems(for:));
- (NSArray<NSMenuItem *> *)menuItemsForWorktree:(PBGitWorktree *)worktree NS_SWIFT_NAME(menuItems(forWorktree:));
- (NSArray<NSMenuItem *> *)menuItemsForWorktreeGroup;
@end

@interface PBGitRefLabelColors : NSObject
+ (NSColor *)colorForRef:(PBGitRef *)ref repository:(nullable PBGitRepository *)repository NS_SWIFT_NAME(color(for:repository:));
@end

@interface PBGitWindowController (WorktreeTests)
- (IBAction)openWorktree:(nullable id)sender;
- (IBAction)lockWorktree:(nullable id)sender;
- (IBAction)unlockWorktree:(nullable id)sender;
- (IBAction)removeWorktree:(nullable id)sender;
- (IBAction)pruneWorktrees:(nullable id)sender;
- (IBAction)addWorktree:(nullable id)sender;
- (IBAction)checkOutInNewWorktree:(nullable id)sender;
- (IBAction)repairWorktreeLinks:(nullable id)sender;
- (IBAction)locateWorktreeFolder:(nullable id)sender;
- (void)windowDidBecomeMain:(NSNotification *)notification;
@end

NS_ASSUME_NONNULL_END
