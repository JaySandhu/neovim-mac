//
//  Neovim Mac
//  shader_types.hpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef SHADER_TYPES_H
#define SHADER_TYPES_H

#include <simd/simd.h>

struct uniform_data {
    simd_float2 pixel_size;
    simd_float2 cell_pixel_size;
    simd_float2 cell_size;
    simd_float2 baseline;
    simd_short2 cursor_position;
    uint32_t cursor_color;
    uint32_t cursor_line_width;
    uint32_t cursor_cell_width;
    uint32_t grid_width;
};

/// A rasterized glyph stored in a Metal texture.
struct glyph_rect {
    /// The size of the glyph's bounding rect.
    simd_short2 size;

    /// Translation vector from the font baseline to the glyph's top left corner.
    simd_short2 position;

    /// The texture position of the rasterized glyph's top left corner where:
    ///   x - The x position in pixel coordinates.
    ///   y - The y position in pixel coordinates.
    ///   z - The cache page the glyph is on.
    simd_short3 texture_origin;
};

struct glyph_data {
    simd_short2 grid_position;
    uint32_t cell_width;
    glyph_rect rect;

    glyph_data() = default;

    glyph_data(simd_short2 grid_position, uint32_t cell_width, glyph_rect rect):
        grid_position(grid_position), cell_width(cell_width), rect(rect) {}
};

struct line_metrics {
    /// Y position of the line as an offset from the font baseline.
    int16_t ytranslate;

    /// For dotted lines, controls the size of the dashes. Use 0 for solid lines.
    uint16_t period;

    /// The line's thickness in pixels.
    uint16_t thickness;
};

/// Describes an underline, undercurl, or a strikethrough.
/// Lines have the same width as cells. Adjacent line_data objects as used to
/// draw continuous lines that are longer than a cell.
struct line_data {
    simd_short2 grid_position;
    uint32_t color;
    int16_t ytranslate;
    uint16_t period;
    uint16_t thickness;
    uint16_t count;

    line_data() = default;

    /// Constructs a new line_data object.
    /// @param grid_position    The grid position of the line.
    /// @param color            The color of the line.
    /// @param metrics          The line's metrics.
    /// @param count            The position of the cell in the overall line.
    ///
    /// The count paramter is a zero based index of the cell's position in the
    /// overall line. For example, given the 5th cell in a row with an underline
    /// stretching from the 4th cell to the 8th, count would be 1. This is
    /// required to correctly render dotted lines. For solid lines, pass 0.
    line_data(simd_short2 grid_position, uint32_t color,
              line_metrics metrics, uint16_t count = 0):
        grid_position(grid_position),
        color(color),
        ytranslate(metrics.ytranslate),
        period(metrics.period),
        thickness(metrics.thickness),
        count(count) {}
};

#endif // SHADER_TYPES_H
