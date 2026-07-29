//
//  PBCommitMessageView.h
//  GitX
//
//  Created by Jeff Mesnil on 13/10/08.
//  Copyright 2008 Jeff Mesnil (http://jmesnil.net/). All rights reserved.
//

#import "GitXTextView.h"

@class PBGitRepository;

NS_ASSUME_NONNULL_BEGIN

@interface PBCommitMessageView : GitXTextView

@property (nonatomic, weak, nullable) PBGitRepository *repository;

@end

NS_ASSUME_NONNULL_END
