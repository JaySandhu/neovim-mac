//
//  Neovim Mac
//  NVGridView.h
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Cocoa/Cocoa.h>
#import "NVWindowController.h"

#include "ui.hpp"
#include "font.hpp"

NS_ASSUME_NONNULL_BEGIN

@interface NVGridView : NSView<CALayerDelegate>

- (instancetype)initWithGrid:(ui::grid *)grid
                  fontFamily:(font_family)font
               renderContext:(NVRenderContext *)renderContext;

- (void)setGrid:(ui::grid*)grid;

- (void)setFont:(font_family)font;
- (font_family*)getFont;

- (NSSize)getCellSize;

- (NSSize)desiredFrameSize;

- (ui::grid_size)desiredGridSize;

- (ui::grid_point)cellLocation:(NSPoint)windowLocation;

@end

NS_ASSUME_NONNULL_END
