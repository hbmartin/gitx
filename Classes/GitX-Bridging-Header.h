//
//  GitX-Bridging-Header.h
//  GitX
//
//  Exposes Objective-C headers to Swift.
//
//  RULE: only add a header here when a Swift file actually needs to reference
//  the type/symbol.  Do NOT bulk-import everything — it breaks archive builds.
//  External/ headers are imported via framework imports only (no bare filenames).
//

// ── System ───────────────────────────────────────────────────────────────────
#import <Cocoa/Cocoa.h>

// ── External frameworks (framework imports only — no bare filenames) ──────────
#import <ObjectiveGit/ObjectiveGit.h>

// ── Converted files: headers kept so ObjC callers continue to compile ────────
#if defined(__swift__) && !defined(GITX_SWIFT_H)
// Swift callers use the Objective-C dark-mode compatibility category.
#import "NSAppearance+PBDarkMode.h"
// NSColor+RGB.swift owns the implementation.
#import "NSColor+RGB.h"
// NSSplitView+GitX.swift owns the implementation.
#import "NSSplitView+GitX.h"
// GitXRelativeDateFormatter.swift owns the implementation.
#import "GitXRelativeDateFormatter.h"
// PBHistoryArrayController.swift owns the implementation.
#import "PBHistoryArrayController.h"
#endif

// ── Add further headers below only when a Swift source file needs them ────────
// PBCommitList.swift needs these:
#import "PBMacros.h"
#if defined(__swift__) && !defined(GITX_SWIFT_H)
#import "PBCommitList.h"
#endif
#import "PBGitRevisionCell.h"
#import "PBWebHistoryController.h"
#import "PBHistorySearchController.h"
#import "PBGitHistoryController.h"
#import "PBViewController.h"
#import "PBGitCommit.h"
#import "PBGitRef.h"
#if defined(__swift__) && !defined(GITX_SWIFT_H)
#import "PBHighlighting.h"
#endif
#import "PBGitDefaults.h"
#import "PBGitRepository.h"
#import "PBGitRepositoryDocument.h"
#import "PBGitIndex.h"
#import "PBChangedFile.h"
#import "PBGitRepository_PBGitBinarySupport.h"
#import "PBGitRevSpecifier.h"
#import "PBGitStash.h"
#import "PBUncommittedChanges.h"
#import "PBGitRevisionRow.h"
#import "PBGitSidebarController.h"
#import "PBRepositoryFinder.h"
#import "PBError.h"
#import "PBTask.h"
#import "PBGitBinary.h"
#import "PBAddRemoteSheet.h"
#import "PBAutoFetchManager.h"
#import "PBCreateBranchSheet.h"
#import "PBCreateTagSheet.h"
#import "PBDiffWindowController.h"
#import "PBRemoteProgressSheet.h"
#import "PBTerminalUtil.h"
#import "PBNativeContentView.h"
#import "PBSourceViewItem.h"
#import "PBGitTree.h"
#import "PBCommitHookFailedSheet.h"
#import "PBGitXMessageSheet.h"
// StagingViewController.swift needs these:
#import "PBCommitMessageView.h"

// The bridging header declares no APIs of its own, but retain an explicit
// nullability region so it follows the same interoperability contract as
// first-party declaration headers.
NS_ASSUME_NONNULL_BEGIN

// PBGitWindowController+Dialogs.swift uses this narrow compatibility wrapper so the converted
// controller never has to import its own Objective-C forward declaration through the sheet API.
extern void PBShowGitXErrorSheet(NSError *error, NSWindowController *windowController);

// StagingDiffPaneController.swift snapshots this existing private index
// decision before dispatching immutable diff work off the main thread.
@interface PBGitIndex (PBStagingDiffLoading)
@property (nonatomic, copy, readonly) NSString *parentTree;
@end

NS_ASSUME_NONNULL_END
