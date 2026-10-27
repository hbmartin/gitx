// Objective-C initialization and selectors remain stable while Swift owns discovery.
#import "PBGitBinary.h"
#import "GitX-Swift.h"

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
	NSString *searchPathsString = [[PBGitBinary searchLocations] componentsJoinedByString:@"\n\t"];
	return [NSString stringWithFormat:
						 NSLocalizedString(
							 @"Could not find a git binary version " MIN_GIT_VERSION " or higher.\n"
							 @"Please make sure there is a git binary in one of the following locations:"
							 @"\n\n\t%@",
							 @"Error message when no git client can be found."),
						 searchPathsString];
}

@end
