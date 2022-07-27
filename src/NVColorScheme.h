//
//  Neovim Mac
//  NVColorScheme.h
//
//  Copyright © 2022 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Cocoa/Cocoa.h>

#ifdef __cplusplus
#include "ui.hpp"
#endif

NS_ASSUME_NONNULL_BEGIN

/// A color scheme for GUI elements.
@interface NVColorScheme : NSObject

/// Title bar color (for when the titlebar is transparent).
@property (nonatomic) NSColor *titleBarColor;

/// Tab button color (e.g. close button, new tab button).
@property (nonatomic) NSColor *tabButtonColor;

/// Tab button background color on mouse over.
@property (nonatomic) NSColor *tabButtonHoverColor;

/// Tab button background color on mouse click.
@property (nonatomic) NSColor *tabButtonHighlightColor;

/// Tab separator color.
@property (nonatomic) NSColor *tabSeparatorColor;

/// Tab background color.
@property (nonatomic) NSColor *tabBackgroundColor;

/// Selected tab background color.
@property (nonatomic) NSColor *tabSelectedColor;

/// Tab background color on mouse over.
@property (nonatomic) NSColor *tabHoverColor;

/// Tab title color.
@property (nonatomic) NSColor *tabTitleColor;

/// Returns a default color scheme for the given appearance.
+ (NVColorScheme*)defaultColorSchemeForAppearance:(NSAppearance *)appearance;

#ifdef __cplusplus

/// Create a NVColorScheme from a nvim::colorscheme.
/// @param colorscheme  Pointer to a nvim::colorscheme.
/// @param appearance   Appearance to use for default colors.
- (instancetype)initWithColorScheme:(nvim::colorscheme *)colorscheme
                         appearance:(NSAppearance *)appearance;

#endif

@end

NS_ASSUME_NONNULL_END
