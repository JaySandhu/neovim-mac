//
//  Neovim Mac
//  Font.hpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef GLYPH_HPP
#define GLYPH_HPP

#include <simd/simd.h>
#include <Metal/Metal.h>
#include <unordered_map>
#include <memory>
#include <vector>
#include <string>
#include "ui.hpp"

template<typename T>
class arc_ptr {
private:
    T ptr;

public:
    arc_ptr(): ptr(nullptr) {}
    arc_ptr(T ptr): ptr(ptr) {}

    arc_ptr(const arc_ptr &other) {
        ptr = other.ptr;
        CFRetain(ptr);
    }

    arc_ptr& operator=(const arc_ptr &other) {
        if (ptr) CFRelease(ptr);
        ptr = other.ptr;
        CFRetain(ptr);
        return *this;
    }

    arc_ptr(arc_ptr &&other) {
        ptr = other.ptr;
        other.ptr = nullptr;
    }

    arc_ptr& operator=(arc_ptr &&other) {
        if (ptr) CFRelease(ptr);
        ptr = other.ptr;
        other.ptr = nullptr;
        return *this;
    }

    ~arc_ptr() {
        if (ptr) CFRelease(ptr);
    }

    void reset() {
        if (ptr) {
            CFRelease(ptr);
            ptr = nullptr;
        };
    }
    
    explicit operator bool() const {
        return ptr;
    }

    T get() const {
        return ptr;
    }
};

class font_family {
private:
    arc_ptr<CTFontRef> fonts[(size_t)ui::font_attributes::bold_italic + 1];
    size_t font_id;
    
public:
    font_family() = default;
    font_family(std::string_view name, CGFloat size);
    
    CTFontRef regular() const {
        return fonts[(size_t)ui::font_attributes::none].get();
    }
    
    CTFontRef bold() const {
        return fonts[(size_t)ui::font_attributes::bold].get();
    }
    
    CTFontRef italic() const {
        return fonts[(size_t)ui::font_attributes::italic].get();
    }
    
    CTFontRef bold_italic() const {
        return fonts[(size_t)ui::font_attributes::bold_italic].get();
    }
    
    CTFontRef get(ui::font_attributes attrs) const {
        return fonts[(size_t)attrs].get();
    }
    
    CGFloat size() const {
        return CTFontGetSize(regular());
    }
    
    CGFloat leading() const {
        return CTFontGetLeading(regular());
    }
    
    CGFloat ascent() const {
        return CTFontGetAscent(regular());
    }
    
    CGFloat descent() const {
        return CTFontGetDescent(regular());
    }
    
    CGFloat underline_position() const {
        return CTFontGetUnderlinePosition(regular());
    }
    
    CGFloat underline_thickness() const {
        return CTFontGetUnderlineThickness(regular());
    }

    CGFloat width() const;
};

class font_manager {
private:
    struct font_entry {
        std::string name;
        CGFloat size;
        font_family font;
        
        explicit font_entry(std::string_view name, CGFloat size):
            name(name), size(size), font(name, size) {}
    };
    
    std::vector<font_entry> used_fonts;

public:
    font_family get(std::string_view name, CGFloat size);
};

struct glyph_metrics {
    int16_t left_bearing;
    int16_t ascent;
    int16_t width;
    int16_t height;
    
    int16_t descent() const {
        return ascent - height;
    }
};

struct glyph_bitmap {
    unsigned char *buffer;
    size_t stride;
    int16_t left_bearing;
    int16_t ascent;
    int16_t width;
    int16_t height;
    
    int16_t descent() const {
        return ascent - height;
    }
};

struct glyph_rasterizer {
    static constexpr size_t pixel_size = 4;
    
    arc_ptr<CGContextRef> context;
    std::unique_ptr<unsigned char[]> buffer;
    size_t buffer_size;
    size_t midx;
    size_t midy;

    glyph_rasterizer() = default;
    glyph_rasterizer(size_t width, size_t height);
        
    glyph_bitmap rasterize(uint32_t clear_pixel, CFAttributedStringRef string);
    
    glyph_bitmap rasterize_alpha(CTFontRef font,
                                 ui::rgb_color foreground,
                                 std::string_view text);
    
    size_t stride() const {
        return midx * 2 * pixel_size;
    }
};

struct cached_glyph {
    simd_short2 glyph_position;
    simd_short2 glyph_size;
    simd_short2 texture_position;
    uint32_t texture_index;
};

struct glyph_texture_cache {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLTexture> texture;
    size_t page_count;
    size_t page_index;
    size_t x_size;
    size_t y_size;
    size_t x_used;
    size_t y_used;
    size_t row_height;
    
    size_t width() const {
        return x_size;
    }
    
    size_t height() const {
        return y_size;
    }
    
    MTLPixelFormat pixel_format() const {
        return [texture pixelFormat];
    }
    
    glyph_texture_cache() = default;
    
    glyph_texture_cache(id<MTLCommandQueue> queue, MTLPixelFormat format,
                        size_t page_width, size_t page_height);
    
    void erase_front(size_t count);
    
    simd_short3 add_new_page(const glyph_bitmap &bitmap);
    simd_short3 add(const glyph_bitmap &bitmap);
};

struct glyph_manager {
    struct key_type {
        size_t hash;
        char text[24];
        CTFontRef font;
        uint64_t foreground;
        
        key_type(CTFontRef font, const ui::cell &cell): font(font) {
            memcpy(text, cell.text, ui::cell::max_text_size);
            foreground = cell.foreground().rgb();
            hash = cell.hash ^ ((uintptr_t)font >> 3) ^ foreground;
        }
    };
    
    struct key_hash {
        size_t operator()(const key_type &key) const {
            return key.hash;
        }
    };
    
    struct key_equal {
        bool operator()(const key_type &left, const key_type &right) const {
            return memcmp(&left, &right, sizeof(key_type)) == 0;
        }
    };
    
    using glyph_map = std::unordered_map<key_type,
                                         cached_glyph,
                                         key_hash,
                                         key_equal>;
    
    glyph_rasterizer rasterizer;
    glyph_texture_cache texture_cache;
    glyph_map map;
    
    cached_glyph get(const font_family &font_family, const ui::cell &cell) {
        CTFontRef font = font_family.get(cell.font_attributes());
        key_type key(font, cell);
        
        if (auto iter = map.find(key); iter != map.end()) {
            return iter->second;
        }

        glyph_bitmap glyph = rasterizer.rasterize_alpha(font,
                                                        cell.foreground(),
                                                        cell.text_view());
        
        auto texture_position = texture_cache.add(glyph);
        
        cached_glyph cached;
        cached.texture_position  = texture_position.xy;
        cached.texture_index = texture_position.z;
        cached.glyph_position.x = glyph.left_bearing;
        cached.glyph_position.y = -glyph.ascent;
        cached.glyph_size.x = glyph.width;
        cached.glyph_size.y = glyph.height;

        map.emplace(key, cached);
        return cached;
    }
     
    void evict();
    
    id<MTLTexture> texture() const {
        return texture_cache.texture;
    }
};

#endif // GLYPH_HPP