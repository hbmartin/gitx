#import "RepositoryIgnoreTestSupport.h"
#import "PBGitRepository.h"

@interface PBRepositoryIgnoreInvocation ()

@property (nonatomic) BOOL success;
@property (nonatomic, nullable) NSError *error;
@property (nonatomic, nullable) NSException *exception;

@end

@implementation PBRepositoryIgnoreInvocation

+ (instancetype)invokeRepository:(PBGitRepository *)repository paths:(NSArray<NSString *> *)paths
{
	PBRepositoryIgnoreInvocation *invocation = [[self alloc] init];
	@try {
		NSError *error = nil;
		invocation.success = [repository ignoreFilePaths:paths error:&error];
		invocation.error = error;
	} @catch (NSException *exception) {
		invocation.exception = exception;
	}
	return invocation;
}

@end
