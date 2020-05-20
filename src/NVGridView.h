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
#include "neovim.hpp"

NS_ASSUME_NONNULL_BEGIN

@interface NVGridView : NSView<CALayerDelegate>

- (instancetype)initWithFrame:(NSRect)frame
                renderContext:(NVRenderContext *)renderContext
                 neovimHandle:(neovim *)neovimHandle;

- (void)setGrid:(ui::grid*)grid;
- (void)setFont:(font_family)font;

- (NSSize)getCellSize;

@end

NS_ASSUME_NONNULL_END
