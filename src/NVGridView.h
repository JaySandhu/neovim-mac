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

/// @class NVGridView
/// @abstract Renders Neovim grids.
///
/// A NVGridView renders Neovim grids as represented by nvim::grid objects.
/// Rendering requires a grid, a font family, and a render context, each of
/// which should be set before the view's first redraw cycle - failing to do
/// so will result in a runtime crash.
///
/// Rendering is independent of the view's size. If the view is too small,
/// the output is cropped. If the view is too large, the output is padded.
@interface NVGridView : NSView<CALayerDelegate>

/// The view's render context.
/// For optimum performance, always use the render context associated with the
/// screen displaying the view.
@property (nonatomic) NVRenderContext *renderContext;

/// The view's grid.
/// Setting a grid will cause the view to redraw itself. It will also reset
/// the cursor blink loop. When the grid size changes the result of
/// - [desiredFrameSize:] changes accordingly.
@property (nonatomic) const nvim::grid *grid;

/// The view's font family.
/// The view's scale factor is also set by the font's scale factor. Changing a
/// view's font may cause the view's cell size to change.
@property (nonatomic) const font_family &font;

/// Returns the size of a single width cell.
- (NSSize)cellSize;

/// Returns the frame size required to fit the current grid.
/// The value returned by this method changes whenever the grid size or
/// cell size change.
- (NSSize)desiredFrameSize;

/// Returns the maximum grid size that can fit in the view's current frame size.
/// The value returned by this method changes whenever the cell size or
/// frame size changes.
- (nvim::grid_size)desiredGridSize;

/// Translates a window location to a grid point.
/// @returns The grid position of the cell at window location.
/// Note: The returned value is calculated as if the grid extended to +/- inf
/// starting at the cell (0, 0). Thus, the returned grid position may be out of
/// the current grids bounds.
- (nvim::grid_point)cellLocation:(NSPoint)windowLocation;

/// Translates a window location to a grid point clamped to a given grid size.
/// @returns The grid position of the cell at window location.
- (nvim::grid_point)cellLocation:(NSPoint)windowLocation
                         clampTo:(nvim::grid_size)gridSize;

/// Set the view to inactive.
/// An inactive view disables cursor blinking and always uses a block outline
/// cursor shape. The behavior mimics macOS's terminal.app.
- (void)setInactive;

/// Set the view to active.
/// Restores the cursor style from the current grid object.
- (void)setActive;

@end

NS_ASSUME_NONNULL_END
