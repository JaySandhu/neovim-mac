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

struct cell_location {
    size_t row;
    size_t column;
};

inline bool operator==(const cell_location &left, const cell_location &right) {
    return memcmp(&left, &right, sizeof(cell_location)) == 0;
}

inline bool operator!=(const cell_location &left, const cell_location &right) {
    return memcmp(&left, &right, sizeof(cell_location)) != 0;
}

@interface NVGridView : NSView<CALayerDelegate>

- (instancetype)initWithGrid:(ui::grid *)grid
                  fontFamily:(font_family)font
               renderContext:(NVRenderContext *)renderContext
                neovimHandle:(neovim *)neovimHandle;

- (void)setGrid:(ui::grid*)grid;
- (void)setFont:(font_family)font;

- (NSSize)getCellSize;

- (cell_location)cellLocation:(NSPoint)windowLocation;

@end

NS_ASSUME_NONNULL_END
