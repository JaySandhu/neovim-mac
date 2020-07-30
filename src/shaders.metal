//
//  Neovim Mac
//  shaders.metal
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <metal_stdlib>
#include "shader_types.hpp"

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
    float2 texture_position;
    uint32_t texture_index;
};

// Our vertex data represents rectangles as an origin + size tuple. To translate
// this into vertices we start with the origin and apply a vertex offset. The
// vertex offset is the size vector multiplied by the appropriate vertex
// transform.
constant float2 transforms[4] = {
    {0, 0}, // Top left     - Same as the origin, no offset required.
    {0, 1}, // Bottom right - Offset the y coordinate only.
    {1, 0}, // Top right    - Offset the x coordinate only.
    {1, 1}, // Bottom right - Offset both the x and y coordinates,
};

constant float2 cursor_transforms[5][4] = {
    {{ 0,  0}, { 0,  0}, { 1,  0}, { 1,  0}},
    {{ 0, -1}, { 0,  0}, { 0, -1}, { 0,  0}},
    {{ 0,  0}, { 0,  1}, { 0,  0}, { 0,  1}},
    {{-1,  0}, {-1,  0}, { 0,  0}, { 0,  0}},
};

vertex extern grid_rasterizer_data background_render(uint vertex_id [[vertex_id]],
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

/// Renders the cursor.
/// The cursor shape is controlled by the instance_id where:
///   1. A right anchored vertical bar.
///   2. A bottom anchored horizontal bar.
///   3. A left anchored vertical bar.
///   4. A top anchored horizontal bar.
/// Draw all four instances to create a block outline.
vertex extern grid_rasterizer_data cursor_render(uint vertex_id [[vertex_id]],
                                                 uint instance_id [[instance_id]],
                                                 constant uniform_data &uniforms [[buffer(0)]]) {
    // The cursor cell size in pixels. Account for possible double width cell.
    float2 cell_pixel_size = uniforms.cell_pixel_size;
    cell_pixel_size.x *= uniforms.cursor_cell_width;

    // Position of the cursor cell's top left corner in pixel coordinates.
    float2 cell_position = float2(uniforms.cursor_position.xy) * uniforms.cell_pixel_size;

    // Position of the current vertex in pixel coordinates.
    float2 cell_vertex = cell_position + (cell_pixel_size * transforms[vertex_id]);

    // To draw cursor lines we start with the cell rect and subtract away an
    // inner rect such that the remaining rect is in the correct position and
    // is of the correct size.
    float2 base_translation = cell_pixel_size - float2(uniforms.cursor_line_width);
    float2 translate = base_translation * cursor_transforms[instance_id][vertex_id];

    float2 pixel_position = cell_vertex - translate;
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
    int16_t row = line.grid_position.y;
    int16_t col = line.grid_position.x;

    // Lines have the same width as a cell.
    // Their height is given by their thickness.
    float2 line_size = float2(uniforms.cell_pixel_size.x, line.thickness);

    // The offset of the line's top left corner in pixel coordinates.
    float2 line_offset = uniforms.cell_pixel_size * float2(col, row);
    line_offset.y += uniforms.baseline.y - line.ytranslate;

    float2 pixel_position = line_offset + (line_size * transforms[vertex_id]);
    float2 position = float2(-1, 1) + (pixel_position * uniforms.pixel_size);

    float line_position = line.count + transforms[vertex_id].x;
    float period = uniforms.cell_pixel_size.x * line_position / line.period;

    line_rasterizer_data data;
    data.position = float4(position.xy, 0, 1);
    data.color = unpack_unorm4x8_srgb_to_float(line.color);
    data.period = select(0.5, period, line.period);
    return data;
}

vertex extern glyph_rasterizer_data glyph_render(uint vertex_id [[vertex_id]],
                                                 uint instance_id [[instance_id]],
                                                 constant uniform_data &uniforms [[buffer(0)]],
                                                 constant glyph_data *glyphs [[buffer(1)]]) {
    constant glyph_data &glyph = glyphs[instance_id];
    int16_t col = glyph.grid_position.x;
    int16_t row = glyph.grid_position.y;

    // The position of the cell's top right corner in pixel coordinates.
    float2 cell_position = uniforms.cell_pixel_size * float2(col, row);

    float2 glyph_position = float2(glyph.rect.position.xy);
    float2 glyph_size = float2(glyph.rect.size.xy);
    float2 vertex_offset = glyph_size * transforms[vertex_id];

    // Translate from the cell's top left corner to the glyph vertex.
    // Starting from the cell's top left corner:
    //   - Move to the baseline.
    //   - Move to glyph position.
    //   - Apply the glyph vertex offset.
    float2 glyph_offset_raw = uniforms.baseline +
                              glyph_position +
                              vertex_offset;

    // Ensure we don't draw outside of our current cell.
    // Handle the case of a double width cell.
    float2 cell_bounds = float2(uniforms.cell_pixel_size.x * glyph.cell_width,
                                uniforms.cell_pixel_size.y);

    float2 glyph_offset = clamp(glyph_offset_raw, float2(0, 0), cell_bounds);

    // If the glyph was cropped, we need to crop the texture quad too.
    float2 texture_offset = vertex_offset - (glyph_offset_raw - glyph_offset);

    float2 pixel_position = cell_position + glyph_offset;
    float2 position = float2(-1, 1) + (pixel_position * uniforms.pixel_size);

    glyph_rasterizer_data data;
    data.position = float4(position.xy, 0, 1);
    data.texture_position = float2(glyph.rect.texture_origin.xy) + texture_offset;
    data.texture_index = glyph.rect.texture_origin.z;
    return data;
}

fragment float4 background_fill(grid_rasterizer_data in [[stage_in]]) {
    return in.color;
}

fragment float4 line_fill(line_rasterizer_data in [[stage_in]]) {
    return float4(in.color.rgb, select(0.0, 1.0, sinpi(in.period) > 0));
}

fragment float4 glyph_fill(glyph_rasterizer_data in [[stage_in]],
                           texture2d_array<float> texture [[texture(0)]]) {
    constexpr sampler texture_sampler(mag_filter::nearest,
                                      min_filter::nearest,
                                      address::clamp_to_zero,
                                      coord::pixel);

    return texture.sample(texture_sampler, in.texture_position, in.texture_index);
}
