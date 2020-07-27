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
#include "shader_types.hpp"
#include "ui.hpp"

/// A smart pointer that manages CoreFoundation objects.
/// Works with any pointer compatible with CFRetain / CFRelease.
/// The interface mimics std::unique_ptr.
template<typename T>
class arc_ptr {
private:
    T ptr;

public:
    /// Constructs an arc_ptr that owns nothing, get() returns nullptr.
    arc_ptr(): ptr(nullptr) {}

    /// Assumes ownership of a retained pointer.
    /// @param ptr A pointer to a the reference counted object. Calling this 
    ///            constructor with nullptr is equivalent to calling the 
    ///            default constructor.
    arc_ptr(T ptr): ptr(ptr) {}

    arc_ptr(const arc_ptr &other) {
        ptr = other.ptr;
        if (ptr) CFRetain(ptr);
    }

    arc_ptr& operator=(const arc_ptr &other) {
        if (ptr) CFRelease(ptr);
        ptr = other.ptr;
        if (ptr) CFRetain(ptr);
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

/// A set of fonts of the same typeface in different variations.
/// Stores fonts in regular, bold, italic, and bold italic variations.
/// Font families should not be created directly. Instead use a font_manager. 
class font_family {
private:
    arc_ptr<CTFontRef> fonts[(size_t)nvim::font_attributes::bold_italic + 1];
    CGFloat unscaled_size_;
    CGFloat scale_factor_;
    
    friend class font_manager;

public:
    /// Default constructed objects should only be assigned to or destroyed. 
    /// This constructor is only provided because Objective-C++ requires C++
    /// instance variables to be default constructible. Use a font_manager to 
    /// create font_family objects.
    font_family() = default;
    
    /// Returns the regular font.
    CTFontRef regular() const {
        return fonts[(size_t)nvim::font_attributes::none].get();
    }
    
    /// Returns the bold font.
    CTFontRef bold() const {
        return fonts[(size_t)nvim::font_attributes::bold].get();
    }
    
    /// Returns the italic font.
    CTFontRef italic() const {
        return fonts[(size_t)nvim::font_attributes::italic].get();
    }
    
    /// Returns the bold italic font.
    CTFontRef bold_italic() const {
        return fonts[(size_t)nvim::font_attributes::bold_italic].get();
    }
    
    /// Returns the font matching the given font_attributes.
    /// @param attrs The font attributes. Passing a value out of the range of 
    ///              the font_attributes enum is undefined.
    CTFontRef get(nvim::font_attributes attrs) const {
        return fonts[(size_t)attrs].get();
    }
    
    /// Returns the scaled font size. Equal to unscaled_size() * scale_factor().
    CGFloat size() const {
        return CTFontGetSize(regular());
    }

    /// Returns the unscaled font size.
    CGFloat unscaled_size() const {
        return unscaled_size_;
    }

    /// Returns the scale factor.
    CGFloat scale_factor() const {
        return scale_factor_;
    }
    
    /// Returns the regular font's leading metric.
    CGFloat leading() const {
        return CTFontGetLeading(regular());
    }
    
    /// Returns the regular font's ascent metric.
    CGFloat ascent() const {
        return CTFontGetAscent(regular());
    }
    
    /// Returns the regular font's descent metric.
    CGFloat descent() const {
        return CTFontGetDescent(regular());
    }
    
    /// Returns the regular font's underline position.
    CGFloat underline_position() const {
        return CTFontGetUnderlinePosition(regular());
    }
    
    /// Returns the regular font's underline thickness.
    CGFloat underline_thickness() const {
        return CTFontGetUnderlineThickness(regular());
    }

    /// Returns the regular font's width.
    /// Note: Assumes monospaced fonts. If the font is not monospaced, returns
    /// a reasonable estimate.
    CGFloat width() const;
};

/// Creates CTFontDescriptor and font_family objects.
///
/// Font managers always use the same CTFont object for equivalent fonts, thus 
/// fonts can be uniquely identified by their address (for hashing and equality 
/// purposes). Ensuring fonts are cheap to compare and hash is the reason we 
/// use a font manager. CTFonts created by font managers are retained for the 
/// lifetime of the manager object.  
class font_manager {
private:
    struct font_entry {
        arc_ptr<CTFontRef> font;
        arc_ptr<CFStringRef> name;
        CGFloat size;
        
        font_entry(arc_ptr<CTFontRef> font,
                   arc_ptr<CFStringRef> name,
                   CGFloat size): font(font), name(name), size(size) {}
    };
    
    std::vector<font_entry> used_fonts;
    
    arc_ptr<CTFontRef> get_font(CTFontDescriptorRef descriptor, CGFloat size);

public:
    /// Returns a default font descriptor.
    static arc_ptr<CTFontDescriptorRef> default_descriptor();
    
    /// Returns a matching font descriptor.
    /// If no matching font descriptor is available, returns nullptr.
    static arc_ptr<CTFontDescriptorRef> make_descriptor(std::string_view name);

    /// Returns a font_family with the given font and size.
    /// @param descriptor   The font descriptor.
    /// @param size         The unscaled font size.
    /// @param scale_factor The amount to scale size by.
    font_family get(CTFontDescriptorRef descriptor,
                    CGFloat size, CGFloat scale_factor);

    /// Returns a resized font_family.
    /// The returned font_family is equivalent in all aspects other than size.
    /// @param font         The font family to be resized.
    /// @param new_size     The new unscaled size.
    /// @param scale_factor The amount to scale new_size by.
    font_family get_resized(const font_family &font,
                            CGFloat new_size, CGFloat scale_factor);
};

/// A rasterized glyph. 
/// Consists of a pixel buffer and glyph metrics. The pixel format is the same
/// as the glyph_rasterizer that created it.
struct glyph_bitmap {
    unsigned char *buffer; ///< Pointer to the pixel buffer.
    size_t stride;         ///< Bytes per row in the pixel buffer.
    int16_t left_bearing;  ///< The glyphs left bearing.
    int16_t ascent;        ///< The glyphs ascent metric.
    int16_t width;         ///< The width of the pixel buffer.
    int16_t height;        ///< The height of the pixel buffer.
    
    /// Returns the glyphs descent.
    int16_t descent() const {
        return ascent - height;
    }
};

/// Rasterizes text into glyph_bitmaps.
/// Uses the sRGB colorspace and the RGBA premultiplied alpha pixel format.
class glyph_rasterizer {
private:
    arc_ptr<CGContextRef> context;
    std::unique_ptr<unsigned char[]> buffer;
    size_t buffer_size;
    size_t midx;
    size_t midy;

public:
    static constexpr size_t pixel_size = 4;

    /// Default constructed objects should only be assigned to or destroyed. 
    /// This constructor is only provided because Objective-C++ requires C++
    /// instance variables to be default constructible.
    glyph_rasterizer() = default;

    /// Construct a glyph_rasterizer with the given canvas size.
    /// The glyph rasterizer canvas extends from -width to width along the x 
    /// axis, and from -height to height along the y axis. Glyphs are rasterized
    /// at the origin (0, 0). Thus the maximum glyph size is double the width 
    /// and height paramters. 
    glyph_rasterizer(size_t width, size_t height);
        
    /// Rasterize a string.
    /// @param font         The font to use.
    /// @param background   The glyph background color.
    /// @param foreground   The glyph foreground color.
    /// @param text         The text to rasterize.
    /// @returns A glyph bitmap containing the rasterized output.
    glyph_bitmap rasterize(CTFontRef font,
                           nvim::rgb_color background,
                           nvim::rgb_color foreground,
                           std::string_view text);
    
    /// The stride value for glyph_bitmaps produced by this rasterizer.
    size_t stride() const {
        return midx * 2 * pixel_size;
    }
};

/// Caches glyphs in a Metal texture.
/// Glyphs are cached in an array of 2d textures. Each texture in the texture 
/// array is a cache page. Cache pages are added and evicted as needed. 
class glyph_texture_cache {
private:
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

    simd_short3 add_new_page(const glyph_bitmap &bitmap);

public:
    /// Default constructed objects should only be assigned to or destroyed.
    /// This constructor is only provided because Objective-C++ requires C++
    /// instance variables to be default constructible.
    glyph_texture_cache() = default;

    /// Construct a new texture cache using the given queue and page size.
    /// @param queue        The Metal command queue.
    /// @param page_width   The cache's page width.
    /// @param page_height  The cache's page height.
    glyph_texture_cache(id<MTLCommandQueue> queue,
                        size_t page_width,
                        size_t page_height);

    /// Returns the cache's page width.
    size_t width() const {
        return x_size;
    }
    
    /// Returns the cache's page height.
    size_t height() const {
        return y_size;
    }
    
    /// Returns the pixel format for the cache's Metal texture.
    MTLPixelFormat pixel_format() const {
        return [texture pixelFormat];
    }

    /// Returns the Metal texture.
    id<MTLTexture> metal_texture() const {
        return texture;
    }

    /// Add the bitmap to the cache.
    /// @returns A vector representing the position the bitmap was stored:
    ///          x - The x coordinate of the bitmap's top right corner.
    ///          y - The y coordinate of the bitmap's top right corner.
    ///          z - The cache page the bitmap was stored in. 
    simd_short3 add(const glyph_bitmap &bitmap);
};

/// Rasterizes and caches glyphs.
/// Glyph managers rasterize text on demand and cache the resulting bitmaps in
/// glyph_texture_caches. A glyph manager will always ensure every glyph
/// required to render a frame is in GPU memory.
class glyph_manager {
private:
    struct key_type {
        size_t hash;
        nvim::grapheme_cluster graphemes;
        uint32_t background;
        uint32_t foreground;
        CTFontRef font;

        key_type(CTFontRef font,
                 const nvim::grapheme_cluster &graphemes,
                 nvim::rgb_color background,
                 nvim::rgb_color foreground):
            graphemes(graphemes),
            font(font),
            background(background.opaque()),
            foreground(foreground.opaque()) {
                            
            simd_ulong4 jumbled;
            memcpy(&jumbled, graphemes.data(), graphemes.size());
                
            jumbled *= simd_ulong4{41099511628211,
                                   41099511628211,
                                   41099511628211};
                
            jumbled.w = ((uintptr_t)font >> 3) ^ foreground ^ background;
            hash = jumbled.x ^ jumbled.y ^ jumbled.z ^ jumbled.w;
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
                                         glyph_rect,
                                         key_hash,
                                         key_equal>;
    
    glyph_rasterizer *rasterizer;
    glyph_texture_cache texture_cache;
    glyph_map map;

public:
    /// Default constructed objects should only be assigned to or destroyed.
    /// This constructor is only provided because Objective-C++ requires C++
    /// instance variables to be default constructible.
    glyph_manager() = default;

    /// Constructs a glyph manager.
    /// @param rasterizer   The shared glyph rasterizer to use.
    /// @param queue        The command queue used by the texture cache.
    /// @param page_width   The page width of the texture cache.
    /// @param page_height  The page height of the texture cache.
    glyph_manager(glyph_rasterizer *rasterizer,
                  id<MTLCommandQueue> queue,
                  size_t page_width,
                  size_t page_height):
        rasterizer(rasterizer),
        texture_cache(queue, page_width, page_height) {}

    /// Returns a cached glyph with the given attributes.
    /// @param font         The font.
    /// @param cell         The cell form which the text is obtained from.
    /// @param background   The background color.
    /// @param foreground   The foreground color.
    glyph_rect get(CTFontRef font,
                   const nvim::cell &cell,
                   nvim::rgb_color background,
                   nvim::rgb_color foreground) {
        key_type key(font, cell.grapheme(), background, foreground);
        
        if (auto iter = map.find(key); iter != map.end()) {
            return iter->second;
        }

        glyph_bitmap glyph = rasterizer->rasterize(font,
                                                   background,
                                                   foreground,
                                                   cell.grapheme_view());
        
        auto texture_position = texture_cache.add(glyph);
        
        glyph_rect cached;
        cached.texture_origin = texture_position;
        cached.position.x = glyph.left_bearing;
        cached.position.y = -glyph.ascent;
        cached.size.x = glyph.width;
        cached.size.y = glyph.height;

        map.emplace(key, cached);
        return cached;
    }
    
    /// Calls get using the background and foreground colors of cell.
    glyph_rect get(const font_family &font_family, const nvim::cell &cell) {
        CTFontRef font = font_family.get(cell.font_attributes());
        return get(font, cell, cell.background(), cell.foreground());
    }
    
    /// Returns the Metal texture containing the cached glyphs.
    id<MTLTexture> texture() const {
        return texture_cache.metal_texture();
    }
};

#endif // GLYPH_HPP
