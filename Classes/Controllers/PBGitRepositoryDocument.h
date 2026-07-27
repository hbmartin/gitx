//
//  PBGitRepositoryDocument.h
//  GitX
//
//  Created by Etienne on 31/07/2014.
//
//

#import <Cocoa/Cocoa.h>

@class PBGitRepository;
@class PBGitRevSpecifier;
@class PBGitWindowController;

NS_ASSUME_NONNULL_BEGIN

extern NSString *PBGitRepositoryDocumentType;

@interface PBGitRepositoryDocument : NSDocument

@property (nonatomic, strong, readonly) PBGitRepository *repository;


// Scripting Bridge
- (void)findInModeScriptCommand:(NSScriptCommand *)command;

- (IBAction)showUncommittedChanges:(id)sender;
- (IBAction)showHistoryView:(id)sender;

- (void)selectRevisionSpecifier:(PBGitRevSpecifier *)specifier;

- (nullable PBGitWindowController *)windowController;

@end

NS_ASSUME_NONNULL_END
