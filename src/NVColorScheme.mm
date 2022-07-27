//
//  Neovim Mac
//  NVColorScheme.mm
//
//  Copyright © 2022 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import "NVColorScheme.h"

@implementation NVColorScheme

static NVColorScheme *makeDefaultLightColorScheme() {
    NVColorScheme *colorScheme = [[NVColorScheme alloc] init];

    colorScheme.tabButtonColor          = [NSColor colorWithSRGBRed:0.40 green:0.40 blue:0.40 alpha:1.00];
    colorScheme.tabButtonHoverColor     = [NSColor colorWithSRGBRed:0.76 green:0.76 blue:0.76 alpha:1.00];
    colorScheme.tabButtonHighlightColor = [NSColor colorWithSRGBRed:0.66 green:0.66 blue:0.66 alpha:1.00];
    colorScheme.tabSeparatorColor       = [NSColor colorWithSRGBRed:0.56 green:0.56 blue:0.56 alpha:1.00];
    colorScheme.tabBackgroundColor      = [NSColor colorWithSRGBRed:0.92 green:0.92 blue:0.92 alpha:1.00];
    colorScheme.tabSelectedColor        = [NSColor colorWithSRGBRed:1.00 green:1.00 blue:1.00 alpha:1.00];
    colorScheme.tabHoverColor           = [NSColor colorWithSRGBRed:0.96 green:0.96 blue:0.96 alpha:1.00];
    colorScheme.tabTitleColor           = [NSColor colorWithSRGBRed:0.00 green:0.00 blue:0.00 alpha:0.75];
    colorScheme.titleBarColor           = [NSColor colorWithSRGBRed:1.00 green:1.00 blue:1.00 alpha:1.00];

    return colorScheme;
}

static NVColorScheme *makeDefaultDarkColorScheme() {
    NVColorScheme *colorScheme = [[NVColorScheme alloc] init];

    colorScheme.tabButtonColor          = [NSColor colorWithSRGBRed:1.00 green:1.00 blue:1.00 alpha:1.00];
    colorScheme.tabButtonHoverColor     = [NSColor colorWithSRGBRed:0.27 green:0.27 blue:0.27 alpha:1.00];
    colorScheme.tabButtonHighlightColor = [NSColor colorWithSRGBRed:0.36 green:0.36 blue:0.36 alpha:1.00];
    colorScheme.tabSeparatorColor       = [NSColor colorWithSRGBRed:0.37 green:0.37 blue:0.37 alpha:1.00];
    colorScheme.tabBackgroundColor      = [NSColor colorWithSRGBRed:0.13 green:0.13 blue:0.13 alpha:1.00];
    colorScheme.tabSelectedColor        = [NSColor colorWithSRGBRed:0.24 green:0.24 blue:0.24 alpha:1.00];
    colorScheme.tabHoverColor           = [NSColor colorWithSRGBRed:0.20 green:0.20 blue:0.20 alpha:1.00];
    colorScheme.tabTitleColor           = [NSColor colorWithSRGBRed:1.00 green:1.00 blue:1.00 alpha:1.00];
    colorScheme.titleBarColor           = [NSColor colorWithSRGBRed:0.18 green:0.18 blue:0.18 alpha:1.00];

    return colorScheme;
}

static NVColorScheme* getDefaultLightColorScheme() {
    static NVColorScheme *lightColorScheme = makeDefaultLightColorScheme();
    return lightColorScheme;
}

static NVColorScheme *getDefaultDarkColorScheme() {
    static NVColorScheme *darkColorScheme = makeDefaultDarkColorScheme();
    return darkColorScheme;
}

static NSColor* NSColorFromRGBColor(nvim::rgb_color rgb, NSColor *defaultColor) {
    if (rgb.is_default()) {
        return defaultColor;
    }

    return [NSColor colorWithSRGBRed:((CGFloat)rgb.red())   / 255.0
                               green:((CGFloat)rgb.green()) / 255.0
                                blue:((CGFloat)rgb.blue())  / 255.0
                               alpha:1];
}

+ (NVColorScheme*)defaultColorSchemeForAppearance:(NSAppearance *)appearance {
    NSString *name = appearance.name;

    if ([name isEqualToString:NSAppearanceNameDarkAqua] ||
        [name isEqualToString:NSAppearanceNameVibrantDark] ||
        [name isEqualToString:NSAppearanceNameAccessibilityHighContrastDarkAqua] ||
        [name isEqualToString:NSAppearanceNameAccessibilityHighContrastVibrantDark]) {
        return getDefaultDarkColorScheme();
    } else {
        return getDefaultLightColorScheme();
    }
}

- (instancetype)initWithColorScheme:(nvim::colorscheme *)colorscheme
                         appearance:(NSAppearance *)appearance {
    NVColorScheme *defaults = [NVColorScheme defaultColorSchemeForAppearance:appearance];
    self = [super init];

    self.tabButtonColor          = NSColorFromRGBColor(colorscheme->tab_button,             defaults.tabButtonColor);
    self.tabButtonHoverColor     = NSColorFromRGBColor(colorscheme->tab_button_hover,       defaults.tabButtonHoverColor);
    self.tabButtonHighlightColor = NSColorFromRGBColor(colorscheme->tab_button_highlight,   defaults.tabButtonHighlightColor);
    self.tabSeparatorColor       = NSColorFromRGBColor(colorscheme->tab_separator,          defaults.tabSeparatorColor);
    self.tabBackgroundColor      = NSColorFromRGBColor(colorscheme->tab_background,         defaults.tabBackgroundColor);
    self.tabSelectedColor        = NSColorFromRGBColor(colorscheme->tab_selected,           defaults.tabSelectedColor);
    self.tabHoverColor           = NSColorFromRGBColor(colorscheme->tab_hover,              defaults.tabHoverColor);
    self.tabTitleColor           = NSColorFromRGBColor(colorscheme->tab_title,              defaults.tabTitleColor);
    self.titleBarColor           = NSColorFromRGBColor(colorscheme->titlebar,               defaults.titleBarColor);

    return self;
}

@end
