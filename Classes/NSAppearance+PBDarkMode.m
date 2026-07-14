//
//  NSAppearance+PBDarkMode.m
//  GitX
//

#import "NSAppearance+PBDarkMode.h"
#import <objc/runtime.h>

NSString *const PBEffectiveAppearanceChanged = @"PBEffectiveAppearanceChanged";

static void *PBAppearanceObservationContext = &PBAppearanceObservationContext;

@interface PBAppearanceObserver : NSObject

@property (nonatomic, weak) NSApplication *application;
@property (nonatomic, strong) id notificationObject;

- (instancetype)initWithApplication:(NSApplication *)application notificationObject:(id)notificationObject;

@end

@implementation PBAppearanceObserver

- (instancetype)initWithApplication:(NSApplication *)application notificationObject:(id)notificationObject
{
	self = [super init];
	if (self) {
		_application = application;
		_notificationObject = notificationObject;
		[application addObserver:self
					  forKeyPath:@"effectiveAppearance"
						 options:NSKeyValueObservingOptionNew
						 context:PBAppearanceObservationContext];
	}
	return self;
}

- (void)dealloc
{
	[_application removeObserver:self forKeyPath:@"effectiveAppearance" context:PBAppearanceObservationContext];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
					  ofObject:(id)object
						change:(NSDictionary *)change
					   context:(void *)context
{
	if (context == PBAppearanceObservationContext) {
		[[NSNotificationCenter defaultCenter] postNotificationName:PBEffectiveAppearanceChanged
															object:self.notificationObject];
	} else {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

@end

@implementation NSAppearance (PBDarkMode)

- (BOOL)isDarkMode
{
	NSAppearanceName bestMatch = [self bestMatchFromAppearancesWithNames:@[ NSAppearanceNameDarkAqua, NSAppearanceNameAqua ]];
	return [bestMatch isEqualToString:NSAppearanceNameDarkAqua];
}

@end

@implementation NSApplication (PBDarkMode)

- (BOOL)isDarkMode
{
	return self.effectiveAppearance.isDarkMode;
}

static char kAppearanceObserverAssociationKey;

- (void)registerObserverForAppearanceChanges:(id)observer
{
	PBAppearanceObserver *appearanceObserver = [[PBAppearanceObserver alloc] initWithApplication:self
																			  notificationObject:observer];
	objc_setAssociatedObject(self,
							 &kAppearanceObserverAssociationKey,
							 appearanceObserver,
							 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
