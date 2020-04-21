//
//  Neovim Mac
//  glyph.hpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <CoreText/CoreText.h>
#include "glyph.hpp"

void glyph_rasterizer::set_font(CFStringRef name, CGFloat size) {
    extern CFStringRef NSFontAttributeName;
    font = CTFontCreateWithName(name, size, nullptr);

    const void *keys[] = {NSFontAttributeName};
    const void *values[] = {font.get()};

    attributes = CFDictionaryCreate(nullptr, keys, values, 1,
                                    &kCFTypeDictionaryKeyCallBacks,
                                    &kCFTypeDictionaryValueCallBacks);
}

void glyph_rasterizer::set_canvas(size_t width, size_t height, CGImageAlphaInfo format) {
    midx = std::min(width, 4096ul);
    midy = std::min(height, 4096ul);
    width = midx * 2;
    height = midy * 2;

    arc_ptr<CGColorSpaceRef> color_space;

    switch (format) {
        case kCGImageAlphaOnly:
            pixel_size = 1;
            break;

        case kCGImageAlphaPremultipliedLast:
            pixel_size = 4;
            color_space = CGColorSpaceCreateDeviceRGB();
            break;

        default:
            std::abort();
            break;
    }

    buffer_size = width * height * pixel_size;
    buffer.reset(new unsigned char[buffer_size]);

    context = CGBitmapContextCreate(buffer.get(), width, height, 8,
                                    width * pixel_size,
                                    color_space.get(), format);
}

static inline CGFloat clamp_abs(CGFloat value, CGFloat limit) {
    if (value > limit) {
        return limit;
    } else if (value < -limit) {
        return -limit;
    } else {
        return value;
    }
}

glyph_metrics glyph_rasterizer::rasterize(std::string_view text) {
    // TODO: We can optimize this memset
    memset(buffer.get(), 0, buffer_size);
    CGContextSetTextPosition(context.get(), midx, midy);

    arc_ptr text_str = CFStringCreateWithBytes(nullptr, (UInt8*)text.data(),
                                               text.size(), kCFStringEncodingUTF8, 0);

    // TODO: Implement fast path for strings that don't require shaping.
    arc_ptr attr_str = CFAttributedStringCreate(nullptr, text_str.get(), attributes.get());
    arc_ptr line = CTLineCreateWithAttributedString(attr_str.get());
    CTLineDraw(line.get(), context.get());

    CGRect bounds = CTLineGetBoundsWithOptions(line.get(), kCTLineBoundsUseGlyphPathBounds);
    CGFloat descent = bounds.origin.y - 2;
    CGFloat ascent  = bounds.size.height + bounds.origin.y + 2;
    CGFloat leftx   = bounds.origin.x - 2;
    CGFloat width   = bounds.size.width + 5;

    glyph_metrics metrics;
    metrics.left_bearing = clamp_abs(leftx, midx);
    metrics.width = clamp_abs(width, midx - metrics.left_bearing);
    metrics.ascent = clamp_abs(ascent, midy);
    metrics.descent = clamp_abs(descent, midy);
    metrics.stride = midx * 2;

    size_t col = (midy - metrics.ascent) * metrics.stride;
    size_t row = midx + metrics.left_bearing;
    metrics.buffer = buffer.get() + ((col + row) * pixel_size);

    return metrics;
}

void glyph_texture_cache::create(id<MTLDevice> device, MTLPixelFormat format,
                                 size_t width, size_t height) {
    x_size = width;
    y_size = height;
    x_used = 0;
    y_used = 0;
    row_height = 0;

    auto *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                    width:width
                                                                   height:height
                                                                mipmapped:NO];

    [desc setUsage:MTLTextureUsageShaderRead];
    texture = [device newTextureWithDescriptor:desc];
}

glyph_texture_position glyph_texture_cache::add(glyph_metrics *glyph) {
    size_t glyph_height = glyph->height();
    size_t glyph_width  = glyph->width;

    row_height = std::max(glyph_height, row_height);

    for (;;) {
        size_t newx = glyph_width + x_used;
        size_t newy = row_height + y_used;

        if (newx <= x_size && newy <= y_size) {
            [texture replaceRegion:MTLRegionMake2D(x_used, y_used, glyph_width, glyph_height)
                       mipmapLevel:0
                         withBytes:glyph->buffer
                       bytesPerRow:glyph->stride];

            glyph_texture_position position;
            position.x = x_used;
            position.y = y_used;
            
            x_used = newx + 1;
            return position;
        }

        y_used = y_used + row_height + 1;
        x_used = 0;
        row_height = glyph_height;

        if (glyph_width > x_size || glyph_height + y_used > y_size) {
            return not_added;
        }
    }
}
