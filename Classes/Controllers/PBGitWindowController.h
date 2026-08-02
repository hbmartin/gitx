//
//  PBGitWindowController.h
//  GitX
//
//  Objective-C compatibility surface for the Swift window controller.
//

#import "GitX-Swift.h"

@class PBGitRepositoryDocument;

NS_ASSUME_NONNULL_BEGIN

/** Preserves the narrower Objective-C document type exposed before the Swift conversion. */
@interface PBGitWindowController (PBGitRepositoryDocumentCompatibility)

/* This is assign because that's what NSWindowController says :-S */
@property (assign, nullable) PBGitRepositoryDocument *document;

@end

NS_ASSUME_NONNULL_END
