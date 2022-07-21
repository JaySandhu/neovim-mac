//
//  Neovim Mac
//  NVWindow.m
//
//  Copyright © 2022 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import "NVWindow.h"

// Hacky solution to control the titlebar height.
// We're using some private APIs here, so this could break in the future.
@interface NSThemeFrame : NSView
- (instancetype)initWithFrame:(NSRect)frame styleMask:(NSWindowStyleMask)styleMask owner:(id)owner;
- (CGFloat)_titlebarHeight;
@end

@interface NVWindowThemeFrame : NSThemeFrame
- (void)setTitlebarHeight:(CGFloat)height;
@end

@implementation NVWindow {
    NVWindowThemeFrame __unsafe_unretained *themeFrame;
}

+ (Class)frameViewClassForStyleMask:(NSUInteger)windowStyle {
    return [NVWindowThemeFrame class];
}

- (BOOL)_usesCustomDrawing {
    return NO;
}

- (void)setThemeFrame:(NVWindowThemeFrame *)themeFrame {
    self->themeFrame = themeFrame;
}

- (void)setTitlebarHeight:(CGFloat)height {
    [themeFrame setTitlebarHeight:height];
}

- (CGFloat)titlebarHeight {
    return [themeFrame _titlebarHeight];
}

@end

@implementation NVWindowThemeFrame {
    CGFloat _overriddenTitlebarHeight;
}

- (instancetype)initWithFrame:(NSRect)frame styleMask:(NSWindowStyleMask)styleMask owner:(id)owner {
    self = [super initWithFrame:frame styleMask:styleMask owner:owner];
    _overriddenTitlebarHeight = [super _titlebarHeight];

    assert([owner isKindOfClass:[NVWindow class]]);
    [(NVWindow*)owner setThemeFrame:self];

    return self;
}

- (BOOL)_shouldCenterTrafficLights {
    return YES;
}

- (void)setTitlebarHeight:(CGFloat)height {
    if (height == NVWindowSystemTitleBarHeight) {
        _overriddenTitlebarHeight = [super _titlebarHeight];
    } else {
        _overriddenTitlebarHeight = height;
    }
}

- (CGFloat)_titlebarHeight {
    return _overriddenTitlebarHeight;
}

@end
