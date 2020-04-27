//
//  Neovim Mac
//  ShaderTypes.h
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct RasterizerData {
    float4 position [[position]];
    float2 textureCoords;
};

constant float2 transforms[4] = {
    {0, 0},
    {0, 1},
    {1, 0},
    {1, 1},
};

constant short2 ushort_transforms[4] = {
    {0, 0},
    {0, 1},
    {1, 0},
    {1, 1},
};

vertex extern RasterizerData vertexShader(uint vertexID [[vertex_id]],
                                          uint instanceID [[instance_id]],
                                          constant uniform_data &uniforms [[buffer(0)]],
                                          constant glyph_data *glyphs [[buffer(1)]]) {
    uint32_t row = glyphs[instanceID].grid_position.x;
    uint32_t col = glyphs[instanceID].grid_position.y;
    
    float2 glyph_position = float2(glyphs[instanceID].glyph_position.xy) * uniforms.pixel;
    float2 glyph_size = float2(glyphs[instanceID].size.xy) * uniforms.pixel;
    
    float2 cell_offset = uniforms.cell * float2(col, row);
    float2 vertex_offset = glyph_size * transforms[vertexID];
    float2 position = float2(-1, 1) + cell_offset + vertex_offset + uniforms.baseline + glyph_position;
    
    RasterizerData data;
    data.position = float4(position.xy, 0.0, 1.0);
    short2 val = glyphs[instanceID].texture_position + (glyphs[instanceID].size * ushort_transforms[vertexID]);
    data.textureCoords = float2(val.xy);
    
    return data;
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               texture2d<float> texture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::nearest,
                                     min_filter::nearest,
                                     address::clamp_to_zero,
                                     coord::pixel);
    
    return float4(0.0, 0.0, 0.0, texture.sample(textureSampler, in.textureCoords).a);
}
