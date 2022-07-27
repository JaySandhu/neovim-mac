//
//  Neovim Mac
//  NVPreferences.h
//
//  Copyright © 2022 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Controls access to user preferences.
@interface NVPreferences : NSObject

+ (BOOL)titlebarAppearsTransparent;
+ (BOOL)externalizeTabline;

@end

/// Window controller for the preferences window.
@interface NVPreferencesController : NSWindowController
@end

NS_ASSUME_NONNULL_END
