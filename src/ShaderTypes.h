//
//  Neovim Mac
//  ShaderTypes.h
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

struct glyph_data {
    simd_short2 grid_position;
    simd_short2 texture_position;
    simd_short2 glyph_position;
    simd_short2 glyph_size;
    uint32_t texture_index;
    uint32_t cell_width;
};

struct line_data {
    simd_short2 grid_position;
    uint32_t color;
    int16_t ytranslate;
    uint16_t period;
    uint16_t thickness;
};

#endif // SHADER_TYPES_H
