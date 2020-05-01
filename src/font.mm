//
//  Neovim Mac
//  Font.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <CoreText/CoreText.h>
#include "font.hpp"

font_family::font_family(std::string_view name, CGFloat size) {
    const CTFontSymbolicTraits mask = kCTFontBoldTrait | kCTFontItalicTrait;
    
    arc_ptr cfname = CFStringCreateWithBytes(nullptr, (UInt8*)name.data(),
                                             name.size(), kCFStringEncodingUTF8, false);
    
    regular_ = CTFontCreateWithName(cfname.get(), size, nullptr);
    italic_ = CTFontCreateCopyWithSymbolicTraits(regular(), size, nullptr, kCTFontItalicTrait, mask);
    bold_ = CTFontCreateCopyWithSymbolicTraits(regular(), size, nullptr, kCTFontBoldTrait, mask);
    bold_italic_ = CTFontCreateCopyWithSymbolicTraits(regular(), size, nullptr, mask, mask);
}

CGFloat font_family::width() const {
    unichar mchar = 'M';
    CGGlyph mglyph;
    CTFontGetGlyphsForCharacters(regular(), &mchar, &mglyph, 1);
    
    if (!mglyph) {
        CGRect rect = CTFontGetBoundingBox(regular());
        return rect.size.width;
    }
    
    CGSize advance;
    CTFontGetAdvancesForGlyphs(regular(), kCTFontOrientationHorizontal, &mglyph, &advance, 1);
    return advance.width;
}

font_family font_manager::get(std::string_view name, CGFloat size) {
    for (const font_entry &entry : used_fonts) {
        if (entry.name == name && entry.size == size) {
            return entry.font;
        }
    }
    
    font_entry &back = used_fonts.emplace_back(name, size);
    return back.font;
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
                                    color_space.get(), kCGImageAlphaOnly);
    
    CGContextSetAllowsFontSmoothing(context.get(), true);
    CGContextSetShouldSmoothFonts(context.get(), true);
    
    attributes = CFDictionaryCreateMutable(nullptr, 7,
                                           &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);

    CFDictionarySetValue(attributes.get(),
                         kCTForegroundColorFromContextAttributeName,
                         kCFBooleanTrue);
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

glyph_bitmap glyph_rasterizer::rasterize(CTFontRef font, std::string_view text) {
    // TODO: How much are we save by reusing this dictionary?
    extern CFStringRef NSFontAttributeName;
    CFDictionarySetValue(attributes.get(), NSFontAttributeName, font);
    
    // TODO: We can optimize this memset
    memset(buffer.get(), 0, buffer_size);
    
    CGContextSetTextPosition(context.get(), midx, midy);
    CGContextSetRGBFillColor(context.get(), 1, 1, 1, 1);
    
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
    metrics.ascent = clamp_abs(ascent, midy);
    metrics.width = clamp_abs(width, midx - metrics.left_bearing);
    metrics.height = metrics.ascent - clamp_abs(descent, midy);

    size_t col = (midy - metrics.ascent) * midx * 2;
    size_t row = midx + metrics.left_bearing;
    
    glyph_bitmap bitmap;
    bitmap.stride = stride();
    bitmap.buffer = buffer.get() + ((col + row) * pixel_size);
    bitmap.metrics = metrics;
    return bitmap;
}

void glyph_texture_cache::create(id<MTLDevice> device, MTLPixelFormat format,
                                 size_t width, size_t height) {
    x_size = width;
    y_size = height;
    x_used = 0;
    y_used = 0;
    row_height = 0;
    
    auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                   width:width
                                                                  height:height
                                                               mipmapped:NO];
    texture = [device newTextureWithDescriptor:desc];
}

glyph_texture_cache::point glyph_texture_cache::add(const glyph_bitmap &bitmap) {
    size_t glyph_height = bitmap.metrics.height;
    size_t glyph_width  = bitmap.metrics.width;

    row_height = std::max(glyph_height, row_height);

    for (;;) {
        size_t newx = glyph_width + x_used;
        size_t newy = row_height + y_used;

        if (newx <= x_size && newy <= y_size) {
            [texture replaceRegion:MTLRegionMake2D(x_used, y_used, glyph_width, glyph_height)
                       mipmapLevel:0
                         withBytes:bitmap.buffer
                       bytesPerRow:bitmap.stride];

            point origin;
            origin.x = x_used;
            origin.y = y_used;
        
            x_used = newx + 1;
            return origin;
        }

        y_used = y_used + row_height + 1;
        x_used = 0;
        row_height = glyph_height;

        if (glyph_width > x_size || glyph_height + y_used > y_size) {
            return point{-1, -1};
        }
    }
}
