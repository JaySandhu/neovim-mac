//
//  Neovim Mac
//  NVWindow.h
//
//  Copyright © 2022 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

#define NVWindowSystemTitleBarHeight -1.0

@interface NVWindow : NSWindow

/// Window's titlebar height. Pass NVWindowSystemTitleBarHeight to the titlebar
/// height to the default system value.
@property (nonatomic) CGFloat titlebarHeight;

@end

NS_ASSUME_NONNULL_END
