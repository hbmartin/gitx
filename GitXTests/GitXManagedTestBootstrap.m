#import <Foundation/Foundation.h>

// XCTest bundle loading is the only lifecycle seam here; the observer itself is Swift.
@interface GitXManagedTestObserver : NSObject
+ (void)install;
@end

__attribute__((constructor)) static void GitXInstallManagedTestObserver(void)
{
	@autoreleasepool {
		[GitXManagedTestObserver install];
	}
}
