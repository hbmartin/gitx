#import <Foundation/Foundation.h>

@class PBGitRepository;

NS_ASSUME_NONNULL_BEGIN

@interface PBRepositoryIgnoreInvocation : NSObject

@property (nonatomic, readonly) BOOL success;
@property (nonatomic, nullable, readonly) NSError *error;
@property (nonatomic, nullable, readonly) NSException *exception;

+ (instancetype)invokeRepository:(PBGitRepository *)repository paths:(NSArray<NSString *> *)paths;

@end

NS_ASSUME_NONNULL_END
