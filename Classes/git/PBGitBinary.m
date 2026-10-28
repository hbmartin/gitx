// Objective-C initialization and selectors remain stable while Swift owns discovery.
#import "PBGitBinary.h"
#import "GitX-Swift.h"

NSString *const PBGitMinimumVersion = @MIN_GIT_VERSION;
NSNotificationName const PBGitBinaryDidChangeNotification = @"PBGitBinaryDidChangeNotification";

@implementation PBGitBinary
+ (void)initialize
{
	if (self == PBGitBinary.class) [PBGitBinaryDiscovery.shared start];
}
+ (NSString *)path
{
	return PBGitBinaryDiscovery.shared.path;
}
+ (NSString *)version
{
	return PBGitBinaryDiscovery.shared.version;
}
+ (NSArray<NSString *> *)searchLocations
{
	return PBGitBinaryDiscoveryPolicy.searchLocations;
}
+ (NSString *)extractGitVersion:(NSString *)value
{
	return [PBGitBinaryDiscoveryPolicy extractGitVersion:value];
}
+ (NSString *)versionForPath:(NSString *)path
{
	return [PBGitBinaryDiscovery.shared versionForPath:path];
}
+ (BOOL)acceptBinary:(NSString *)path
{
	return [PBGitBinaryDiscovery.shared acceptBinary:path];
}
+ (void)whenAvailable:(PBGitBinaryAvailabilityHandler)completion
{
	[PBGitBinaryDiscovery.shared whenAvailable:completion];
}

+ (NSString *)notFoundError
{
	return [PBGitBinaryDiscoveryPolicy failureReason:[PBGitBinary searchLocations]];
}

@end
