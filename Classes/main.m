//
//  main.m
//  GitTest
//
//  Created by Pieter de Bie on 13-06-08.
//  Copyright __MyCompanyName__ 2008. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#if DEBUG
// Narrow declaration for the Debug-only Swift bootstrap; production Release has no hook.
@interface PBGitXTestProcessDiagnostics : NSObject
+ (void)installAtApplicationStartup;
@end
#endif

int main(int argc, const char **argv)
{
	int result;
	@autoreleasepool {
#if DEBUG
		[PBGitXTestProcessDiagnostics installAtApplicationStartup];
#endif
		result = NSApplicationMain(argc, argv);
	}
	return result;
}
