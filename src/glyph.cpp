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
    
    size_t col = (midy - metrics.ascent) * (midx * 2);
    size_t row = midx + metrics.left_bearing;
    metrics.buffer = buffer.get() + ((col + row) * pixel_size);

    return metrics;
}
