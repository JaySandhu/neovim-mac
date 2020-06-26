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

arc_ptr<CTFontRef> font_manager::get_font(CTFontDescriptorRef descriptor, CGFloat size) {
    arc_ptr name = (CFStringRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);
    
    for (const font_entry &entry : used_fonts) {
        if (entry.size == size && CFEqual(entry.name.get(), name.get())) {
            return entry.font;
        }
    }
    
    arc_ptr font = CTFontCreateWithFontDescriptorAndOptions(descriptor, size,
                                                            nullptr, kCTFontOptionsDefault);
    
    used_fonts.emplace_back(font, std::move(name), size);
    return font;
}

arc_ptr<CTFontDescriptorRef> font_manager::make_descriptor(std::string_view name) {
    arc_ptr fontname = CFStringCreateWithBytes(nullptr, (UInt8*)name.data(),
                                               name.size(), kCFStringEncodingUTF8, 0);
    
    const void *keys[] = {
        kCTFontNameAttribute,
    };
    
    const void *values[] = {
        fontname.get(),
    };
    
    arc_ptr attributes = CFDictionaryCreate(nullptr, keys, values, 1,
                                            &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks);
    
    arc_ptr font_descriptor = CTFontDescriptorCreateWithAttributes(attributes.get());
    return CTFontDescriptorCreateMatchingFontDescriptor(font_descriptor.get(), nullptr);
}

arc_ptr<CTFontDescriptorRef> font_manager::default_descriptor() {
    return make_descriptor("Menlo");
}

font_family font_manager::get(CTFontDescriptorRef descriptor,
                              CGFloat size, CGFloat scale_factor) {
    const CGFloat scaled_size = size * scale_factor;
    const CTFontSymbolicTraits mask = kCTFontBoldTrait | kCTFontItalicTrait;

    arc_ptr bold = CTFontDescriptorCreateCopyWithSymbolicTraits(descriptor, kCTFontBoldTrait, mask);
    arc_ptr italic = CTFontDescriptorCreateCopyWithSymbolicTraits(descriptor, kCTFontItalicTrait, mask);
    arc_ptr bold_italic = CTFontDescriptorCreateCopyWithSymbolicTraits(descriptor, mask, mask);
    
    font_family family;
    family.fonts[(size_t)ui::font_attributes::none] = get_font(descriptor, scaled_size);
    family.fonts[(size_t)ui::font_attributes::bold] = get_font(bold.get(), scaled_size);
    family.fonts[(size_t)ui::font_attributes::italic] = get_font(italic.get(), scaled_size);
    family.fonts[(size_t)ui::font_attributes::bold_italic] = get_font(bold_italic.get(), scaled_size);
    family.scale_factor_ = scale_factor;
    family.unscaled_size_ = size;

    return family;
}

font_family font_manager::get_resized(const font_family &family,
                                      CGFloat new_size, CGFloat scale_factor) {
    const CGFloat scaled_size = new_size * scale_factor;

    font_family resized;
    resized.unscaled_size_ = new_size;
    resized.scale_factor_ = scale_factor;

    for (int i=0; i<4; ++i) {
        arc_ptr descriptor = CTFontCopyFontDescriptor(family.fonts[i].get());
        resized.fonts[i] = get_font(descriptor.get(), scaled_size);
    }

    return resized;
}

glyph_rasterizer::glyph_rasterizer(size_t width, size_t height) {
    midx = std::min(width, 4096ul);
    midy = std::min(height, 4096ul);
    width = midx * 2;
    height = midy * 2;

    arc_ptr<CGColorSpaceRef> color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    buffer_size = width * height * pixel_size;
    buffer.reset(new unsigned char[buffer_size]);

    context = CGBitmapContextCreate(buffer.get(), width, height, 8,
                                    width * pixel_size, color_space.get(),
                                    kCGImageAlphaPremultipliedLast);
    
    CGContextSetAllowsAntialiasing(context.get(), true);
    CGContextSetShouldAntialias(context.get(), true);
    CGContextSetAllowsFontSmoothing(context.get(), true);
    CGContextSetShouldSmoothFonts(context.get(), true);
    CGContextSetAllowsFontSubpixelPositioning(context.get(), true);
    CGContextSetShouldSubpixelPositionFonts(context.get(), true);
    CGContextSetAllowsFontSubpixelQuantization(context.get(), true);
    CGContextSetShouldSubpixelQuantizeFonts(context.get(), true);
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

static inline void clear_bitmap(glyph_bitmap &bitmap, uint32_t clear_pixel) {
    const size_t row_size = bitmap.width * glyph_rasterizer::pixel_size;
    
    unsigned char *row = bitmap.buffer;
    unsigned char *endrow = row + (bitmap.height * bitmap.stride);

    for (; row != endrow; row += bitmap.stride) {
        unsigned char *endpixel = row + row_size;
        
        for (unsigned char *pixel = row; pixel != endpixel; pixel += 4) {
            memcpy(pixel, &clear_pixel, 4);
        }
    }
}

static inline arc_ptr<CTLineRef> make_line(CTFontRef font,
                                           ui::rgb_color foreground,
                                           ui::grapheme_cluster_view string) {
    arc_ptr fg_cgcolor = CGColorCreateSRGB((double)foreground.red()   / 255,
                                           (double)foreground.green() / 255,
                                           (double)foreground.blue()  / 255, 1);
        
    const void *keys[] = {
        kCTFontAttributeName,
        kCTForegroundColorAttributeName
    };
    
    const void *values[] = {
        font,
        fg_cgcolor.get()
    };
    
    arc_ptr attributes = CFDictionaryCreate(nullptr, keys, values, 2,
                                            &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks);
    
    arc_ptr cfstr = CFStringCreateWithBytes(nullptr, (UInt8*)string.data(),
                                            string.size(), kCFStringEncodingUTF8, 0);

    arc_ptr attr_str = CFAttributedStringCreate(nullptr, cfstr.get(), attributes.get());
    
    return CTLineCreateWithAttributedString(attr_str.get());
}

glyph_bitmap glyph_rasterizer::rasterize(CTFontRef font,
                                         ui::rgb_color background,
                                         ui::rgb_color foreground,
                                         ui::grapheme_cluster_view text) {
    CGContextSetTextPosition(context.get(), midx, midy);
    arc_ptr line = make_line(font, foreground, text);

    CGRect bounds = CTLineGetBoundsWithOptions(line.get(), kCTLineBoundsUseGlyphPathBounds);
    CGFloat descent = bounds.origin.y - 2;
    CGFloat ascent  = bounds.size.height + bounds.origin.y + 2;
    CGFloat leftx   = bounds.origin.x - 2;
    CGFloat width   = bounds.size.width + 5;
        
    glyph_bitmap bitmap;
    bitmap.left_bearing = clamp_abs(leftx, midx);
    bitmap.ascent = clamp_abs(ascent, midy);
    bitmap.width = clamp_abs(width, midx - bitmap.left_bearing);
    bitmap.height = bitmap.ascent - clamp_abs(descent, midy);

    size_t col = (midy - bitmap.ascent) * midx * 2;
    size_t row = midx + bitmap.left_bearing;
        
    bitmap.stride = stride();
    bitmap.buffer = buffer.get() + ((col + row) * pixel_size);
        
    clear_bitmap(bitmap, background.value | 0xFF000000);
    CTLineDraw(line.get(), context.get());
    
    return bitmap;
}

glyph_texture_cache::glyph_texture_cache(id<MTLCommandQueue> queue,
                                         size_t width,
                                         size_t height): queue(queue) {
    device = [queue device];
    
    x_used = 0;
    y_used = 0;
    row_height = 0;
    page_index = 0;
    page_count = 1;
    x_size = width;
    y_size = height;
    
    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType2DArray;
    desc.arrayLength = 1;
    desc.pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
    desc.width = width;
    desc.height = height;
    desc.mipmapLevelCount = 1;
    
    texture = [device newTextureWithDescriptor:desc];
}

simd_short3 glyph_texture_cache::add_new_page(const glyph_bitmap &bitmap) {
    const size_t new_page_count = page_count + 1;
    
    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType2DArray;
    desc.arrayLength = new_page_count;
    desc.pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
    desc.width = x_size;
    desc.height = y_size;
    desc.mipmapLevelCount = 1;
    
    id<MTLTexture> old_texture = texture;
    texture = [device newTextureWithDescriptor:desc];
    
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];

    [blitEncoder copyFromTexture:old_texture
                     sourceSlice:0
                     sourceLevel:0
                       toTexture:texture
                destinationSlice:0
                destinationLevel:0
                      sliceCount:page_count
                      levelCount:1];
    
    [blitEncoder endEncoding];
    [commandBuffer commit];
    
    x_used = std::min((size_t)bitmap.width + 1, x_size);
    y_used = std::min((size_t)bitmap.height, y_size);
    row_height = y_used;
    page_count = new_page_count;
    page_index += 1;
    
    [texture replaceRegion:MTLRegionMake2D(0, 0, x_used, y_used)
               mipmapLevel:0
                     slice:page_index
                 withBytes:bitmap.buffer
               bytesPerRow:bitmap.stride
             bytesPerImage:0];
    
    return simd_short3{0, 0, (int16_t)page_index};
}

simd_short3 glyph_texture_cache::add(const glyph_bitmap &bitmap) {
    size_t glyph_height = bitmap.height;
    size_t glyph_width  = bitmap.width;

    row_height = std::max(glyph_height, row_height);

    for (;;) {
        size_t newx = glyph_width + x_used;
        size_t newy = row_height + y_used;

        if (newx <= x_size && newy <= y_size) {
            [texture replaceRegion:MTLRegionMake2D(x_used, y_used, glyph_width, glyph_height)
                       mipmapLevel:0
                             slice:page_index
                         withBytes:bitmap.buffer
                       bytesPerRow:bitmap.stride
                     bytesPerImage:0];

            simd_short3 origin;
            origin.x = x_used;
            origin.y = y_used;
            origin.z = page_index;
        
            x_used = newx + 1;
            return origin;
        }

        y_used = y_used + row_height + 1;
        x_used = 0;
        row_height = glyph_height;

        if (glyph_width > x_size || glyph_height + y_used > y_size) {
            return add_new_page(bitmap);
        }
    }
}
