//
//  GitXApplicationLocator.h
//  GitX
//
//  Locates the GitX application bundle that owns the embedded gitx tool.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Derives the path of the GitX application bundle that contains the embedded
/// command-line tool at the given path.
///
/// The tool ships at GitX.app/Contents/Resources/gitx, so the bundle is the
/// grandparent of its enclosing directory. Returns nil unless the tool sits at
/// exactly that location, which happens when it runs straight from a build
/// directory; callers fall back to a bundle-identifier lookup in that case.
///
/// Resolving the app by bundle identifier alone is unreliable: when another
/// bundle on disk claims net.phere.GitX, LaunchServices can return a bundle
/// without GitX's scripting definition and every command fails.
static inline NSString *_Nullable GitXApplicationBundlePathForToolPath(NSString *_Nullable toolPath)
{
	if (toolPath.length == 0)
		return nil;

	NSString *resourcesPath = [[toolPath stringByStandardizingPath] stringByDeletingLastPathComponent];
	if (![[resourcesPath lastPathComponent] isEqualToString:@"Resources"])
		return nil;

	NSString *contentsPath = [resourcesPath stringByDeletingLastPathComponent];
	if (![[contentsPath lastPathComponent] isEqualToString:@"Contents"])
		return nil;

	NSString *bundlePath = [contentsPath stringByDeletingLastPathComponent];
	if (![[bundlePath pathExtension] isEqualToString:@"app"])
		return nil;

	return bundlePath;
}

NS_ASSUME_NONNULL_END
