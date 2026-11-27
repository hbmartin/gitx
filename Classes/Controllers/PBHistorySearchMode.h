//
//  PBHistorySearchMode.h
//  GitX
//
//  Created by Sven-S. Porst on 2016-12-14
//

#import <Foundation/NSObjCRuntime.h>

#ifndef PBHistorySearchMode_h
#define PBHistorySearchMode_h

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PBHistorySearchMode) {
	PBHistorySearchModeBasic = 1,
	PBHistorySearchModePickaxe,
	PBHistorySearchModeRegex,
	PBHistorySearchModePath,
	PBHistorySearchModeRaw,
	PBHistorySearchModeMax // always keep this item last
};


PBHistorySearchMode PBSearchModeForInteger(NSInteger modeInteger);

NS_ASSUME_NONNULL_END

#endif /* PBHistorySearchMode_h */
