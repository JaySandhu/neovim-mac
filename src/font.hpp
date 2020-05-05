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
    arc_ptr<CTFontRef> regular_;
    arc_ptr<CTFontRef> bold_;
    arc_ptr<CTFontRef> italic_;
    arc_ptr<CTFontRef> bold_italic_;
    
public:
    font_family() = default;
    font_family(std::string_view name, CGFloat size);
    
    CTFontRef regular() const {
        return regular_.get();
    }
    
    CTFontRef bold() const {
        return bold_.get();
    }
    
    CTFontRef italic() const {
        return italic_.get();
    }
    
    CTFontRef bold_italic() const {
        return bold_italic_.get();
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
    glyph_metrics metrics;
};

struct glyph_rasterizer {
    arc_ptr<CGContextRef> context;
    arc_ptr<CFMutableDictionaryRef> attributes;
    std::unique_ptr<unsigned char[]> buffer;
    size_t buffer_size;
    size_t pixel_size;
    size_t midx;
    size_t midy;

    void set_canvas(size_t width, size_t height, CGImageAlphaInfo format);
    
    glyph_bitmap rasterize(CTFontRef font, std::string_view text);
    
    size_t stride() const {
        return midx * 2 * pixel_size;
    }
};

struct glyph_texture_cache {
    id<MTLTexture> texture;
    size_t x_size;
    size_t y_size;
    size_t x_used;
    size_t y_used;
    size_t row_height;
    
    struct point {
        int16_t x;
        int16_t y;
                
        explicit operator bool() const {
            return x != -1;
        }
    };
    
    void create(id<MTLDevice> device, MTLPixelFormat format, size_t width, size_t height);
    point add(const glyph_bitmap &bitmap);
};
    
struct glyph_key {
    size_t hash;
    char text[24];
    CTFontRef font;
    
    glyph_key(CTFontRef font, const ui::cell &cell): font(font) {
        memcpy(text, cell.text, ui::cell::max_text_size);
        hash = cell.hash ^ ((uintptr_t)font >> 3);
    }
    
    struct key_hash {
        size_t operator()(const glyph_key &key) const {
            return key.hash;
        }
    };
    
    struct key_equal {
        bool operator()(const glyph_key &left, const glyph_key &right) const {
            return memcmp(&left, &right, sizeof(glyph_key)) == 0;
        }
    };
};

struct glyph_cached {
    simd_short2 texture_position;
    simd_short2 glyph_position;
    simd_short2 size;
};

using glyph_cache_map = std::unordered_map<glyph_key,
                                           glyph_cached,
                                           glyph_key::key_hash,
                                           glyph_key::key_equal>;


#endif // GLYPH_HPP
