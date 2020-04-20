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

#include <CoreFoundation/CoreFoundation.h>
#include <vector>
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
    unsigned char *buffer;
    int16_t ascent;
    int16_t descent;
    int16_t left_bearing;
    int16_t width;
    
    int16_t height() const {
        return ascent - descent;
    }
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
    glyph_metrics rasterize(std::string_view text);
    
    size_t stride() const {
        return midx * 2 * pixel_size;
    }
    
    CTFontRef get_font() const {
        return font.get();
    }
};

#endif // GLYPH_HPP
