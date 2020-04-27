//
//  Neovim Mac
//  glyph.cpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef GLYPH_HPP
#define GLYPH_HPP

#import <Metal/Metal.h>
#include <memory>
#include <string>

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
    arc_ptr<CTFontRef> font;
    arc_ptr<CFDictionaryRef> attributes;
    std::unique_ptr<unsigned char[]> buffer;
    size_t buffer_size;
    size_t pixel_size;
    size_t midx;
    size_t midy;

    void set_canvas(size_t width, size_t height, CGImageAlphaInfo format);
    void set_font(CFStringRef name, CGFloat size);
    glyph_bitmap rasterize(std::string_view text);
    
    size_t stride() const {
        return midx * 2 * pixel_size;
    }
    
    CTFontRef get_font() const {
        return font.get();
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

#endif // GLYPH_HPP
