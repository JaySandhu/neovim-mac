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

struct grid_rasterizer_data {
    float4 position [[position]];
    float4 color;
};

struct line_rasterizer_data {
    float4 position [[position]];
    float4 color;
    float period;
};

struct glyph_rasterizer_data {
    float4 position [[position]];
    float4 color;
    float2 texture_position;
    uint32_t texture_index;
};

constant float2 transforms[4] = {
    {0, 0},
    {0, 1},
    {1, 0},
    {1, 1},
};

vertex extern grid_rasterizer_data grid_background(uint vertex_id [[vertex_id]],
                                                   uint instance_id [[instance_id]],
                                                   constant uniform_data &uniforms [[buffer(0)]],
                                                   constant uint32_t *cell_colors [[buffer(1)]]) {
    uint32_t row = instance_id / uniforms.grid_width;
    uint32_t col = instance_id % uniforms.grid_width;
    
    float2 cell_vertex = float2(col, row) + transforms[vertex_id];
    float2 position = float2(-1, 1) + (uniforms.cell_size * cell_vertex);
    
    grid_rasterizer_data data;
    data.position = float4(position.xy, 0, 1);
    data.color = unpack_unorm4x8_srgb_to_float(cell_colors[instance_id]);
    return data;
}

vertex extern grid_rasterizer_data cursor_render(uint vertex_id [[vertex_id]],
                                                 uint instance_id [[instance_id]],
                                                 constant uniform_data &uniforms [[buffer(0)]]) {
    constexpr float2 translations[5][4] = {
        {{ 0,  0}, { 0,  0}, { 1,  0}, { 1,  0}},
        {{ 0, -1}, { 0,  0}, { 0, -1}, { 0,  0}},
        {{ 0,  0}, { 0,  1}, { 0,  0}, { 0,  1}},
        {{-1,  0}, {-1,  0}, { 0,  0}, { 0,  0}},
        {{ 0,  0}, { 0,  0}, { 0,  0}, { 0,  0}}
    };

    float2 base_translation = uniforms.cell_pixel_size - float2(uniforms.cursor_width);
    float2 translate = base_translation * translations[instance_id][vertex_id];
    
    float2 cell_vertex = float2(uniforms.cursor_position.xy) + transforms[vertex_id];
    float2 pixel_position = (uniforms.cell_pixel_size * cell_vertex) - translate;
    float2 position = float2(-1, 1) + (pixel_position * uniforms.pixel_size);
    
    grid_rasterizer_data data;
    data.position = float4(position.xy, 0.0, 1.0);
    data.color = unpack_unorm4x8_srgb_to_float(uniforms.cursor_color);
    return data;
}

vertex extern line_rasterizer_data line_render(uint vertex_id [[vertex_id]],
                                               uint instance_id [[instance_id]],
                                               constant uniform_data &uniforms [[buffer(0)]],
                                               constant line_data *lines [[buffer(1)]]) {
    constant line_data &line = lines[instance_id];
    uint32_t row = line.grid_position.x;
    uint32_t col = line.grid_position.y;
    
    float2 line_size = float2(uniforms.cell_pixel_size.x, line.thickness);
    float2 cell_offset = uniforms.cell_pixel_size * float2(col, row);
    cell_offset.y += uniforms.baseline.y - line.ytranslate;

    float2 pixel_position = cell_offset + (line_size * transforms[vertex_id]);
    float2 position = float2(-1, 1) + (pixel_position * uniforms.pixel_size);
    
    line_rasterizer_data data;
    data.position = float4(position.xy, 0, 1);
    data.color = unpack_unorm4x8_srgb_to_float(line.color);
    data.period = pixel_position.x * 3.14159265359 / line.period;
    return data;
}

fragment float4 fill_background(grid_rasterizer_data in [[stage_in]]) {
    return in.color;
}

vertex extern glyph_rasterizer_data glyph_render(uint vertex_id [[vertex_id]],
                                                 uint instance_id [[instance_id]],
                                                 constant uniform_data &uniforms [[buffer(0)]],
                                                 constant glyph_data *glyphs [[buffer(1)]]) {
    uint32_t row = glyphs[instance_id].grid_position.x;
    uint32_t col = glyphs[instance_id].grid_position.y;
    
    float2 glyph_position = float2(glyphs[instance_id].glyph_position.xy);
    float2 glyph_size = float2(glyphs[instance_id].glyph_size.xy);
    
    float2 cell_offset = uniforms.cell_pixel_size * float2(col, row);
    float2 vertex_offset = glyph_size * transforms[vertex_id];
    
    float2 pixel_position = cell_offset +
                            uniforms.baseline +
                            vertex_offset +
                            glyph_position;
    
    float2 position = float2(-1, 1) + (pixel_position * uniforms.pixel_size);
    
    glyph_rasterizer_data data;
    data.position = float4(position.xy, 0, 1);
    data.texture_position = float2(glyphs[instance_id].texture_position.xy) + vertex_offset;
    data.color = unpack_unorm4x8_srgb_to_float(glyphs[instance_id].color);
    data.texture_index = glyphs[instance_id].texture_index;
    return data;
}

fragment float4 fill_line(line_rasterizer_data in [[stage_in]]) {
    float2 test = float2(1, 0);
    return float4(in.color.rgb, test[sin(in.period) > 0.5]);
}

fragment float4 glyph_fill(glyph_rasterizer_data in [[stage_in]],
                           texture2d_array<float> texture [[texture(0)]]) {
    constexpr sampler texture_sampler(mag_filter::nearest,
                                      min_filter::nearest,
                                      address::clamp_to_zero,
                                      coord::pixel);
    
    float4 sampled = texture.sample(texture_sampler, in.texture_position, in.texture_index);
    return float4(in.color.rgb, sampled.a);
}
