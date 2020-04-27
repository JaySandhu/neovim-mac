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
    simd_float2 pixel;
    simd_float2 cell;
    simd_float2 baseline;
    uint32_t grid_width;
};

struct glyph_data {
    simd_short2 grid_position;
    simd_short2 texture_position;
    simd_short2 glyph_position;
    simd_short2 size;
    uint32_t color;
};

#endif // SHADER_TYPES_H
