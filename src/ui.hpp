//
//  Neovim Mac
//  ui.hpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef UI_HPP
#define UI_HPP

#include <atomic>
#include "msgpack.hpp"
#include "window_controller.hpp"

namespace ui {

struct rgb_color {
    uint32_t value;
    
    struct default_tag_type {};
    static constexpr default_tag_type default_tag;
    static constexpr uint32_t is_default_bit = (1 << 31);
    
    rgb_color() {
        value = 0;
    }
    
    explicit rgb_color(uint32_t rgb) {
        // TODO: Should we be doing this on the gpu?
        value = __builtin_bswap32(rgb << 8);
    }
    
    explicit rgb_color(uint32_t rgb, default_tag_type) : rgb_color(rgb) {
        value |= is_default_bit;
    };
    
    bool is_default() const {
        return value & is_default_bit;
    }
    
    uint8_t red() const {
        return value & 0xFF;
    }
    
    uint8_t green() const {
        return (value >> 8) & 0xFF;
    }
    
    uint8_t blue() const {
        return (value >> 16) & 0xFF;
    }
    
    uint32_t rgb() const {
        return value & 0xFFFFFF;
    }
    
    operator uint32_t() const {
        return value;
    }
};

enum class cursor_shape {
    block,
    horizontal,
    vertical,
    block_outline
};

struct cursor_attributes {
    rgb_color foreground;
    rgb_color background;
    rgb_color special;
    cursor_shape shape;
    uint16_t percentage;
    uint16_t blinkwait;
    uint16_t blinkon;
    uint16_t blinkoff;
};

struct mode_info {
    cursor_attributes cursor_attrs;
    std::string mode_name;
};

struct cursor {
    cursor_attributes attrs;
    size_t row;
    size_t col;
};

struct attributes {
    enum flag : uint16_t {
        bold          = 1 << 0,
        italic        = 1 << 1,
        emoji         = 1 << 2,
        underline     = 1 << 3,
        undercurl     = 1 << 4,
        strikethrough = 1 << 5,
        doublewidth   = 1 << 6,
        reverse       = 1 << 7
    };
    
    rgb_color background;
    rgb_color foreground;
    rgb_color special;
    uint16_t flags;
};

struct attribute_table {
    std::vector<attributes> table;
    
    attribute_table(): table(1) {}
        
    attributes* get_default() {
        return table.data();
    }
    
    const attributes* get_entry(size_t hlid) const {
        if (hlid >= table.size()) {
            return nullptr;
        }
        
        return table.data() + hlid;
    }
    
    attributes* new_entry(size_t hlid);
};

enum class font_attributes {
    none,
    bold        = attributes::bold,
    italic      = attributes::italic,
    bold_italic = attributes::bold | attributes::italic
};

enum class line_attributes {
    none,
    underline     = attributes::underline,
    undercurl     = attributes::undercurl,
    strikethrough = attributes::strikethrough
};

inline uint16_t operator&(line_attributes left, line_attributes right) {
    return (uint16_t)left & (uint16_t)right;
}

struct cell {
    static constexpr size_t max_text_size = 24;

    char text[max_text_size];
    uint16_t size;
    attributes attrs;
    uint64_t hash;
    
    std::string_view text_view() const {
        return std::string_view(text, size);
    }
    
    bool empty() const {
        return size == 0;
    }
    
    rgb_color foreground() const {
        return attrs.foreground;
    }
    
    rgb_color background() const {
        return attrs.background;
    }
    
    rgb_color special() const {
        return attrs.special;
    }
    
    font_attributes font_attributes() const {
        static constexpr uint16_t mask = attributes::bold |
                                         attributes::italic;
        
        return static_cast<enum font_attributes>(attrs.flags & mask);
    }
    
    line_attributes line_attributes() const {
        static constexpr uint16_t mask = attributes::underline |
                                         attributes::undercurl |
                                         attributes::strikethrough;
        
        return static_cast<enum line_attributes>(attrs.flags & mask);
    }
};

struct grid {
    std::vector<cell> cells;
    size_t width = 0;
    size_t height = 0;
    cursor cursor;
    uint64_t draw_tick = 0;
    
    void resize(size_t width, size_t heigth);
        
    cell* get(size_t row, size_t col) {
        return cells.data() + (row * width) + col;
    }
};

struct ui_state {
    window_controller window;
    attribute_table hltable;
    std::vector<mode_info> mode_info_table;
    size_t current_mode;
    
    grid triple_buffered[3];
    std::atomic<grid*> complete;
    grid *writing;
    grid *drawing;

    ui_state() {
        complete = &triple_buffered[0];
        writing  = &triple_buffered[1];
        drawing  = &triple_buffered[2];
    }
    
    grid* get_grid(size_t index);
    
    grid* get_global_grid() {
        uint64_t tick = drawing->draw_tick;
        
        for (;;) {
            drawing = complete.exchange(drawing);
         
            if (drawing->draw_tick >= tick) {
                return drawing;
            }
        }
    }
    
    void redraw(msg::array events);
    
    void redraw_event(const msg::object &event);
    
    void flush();
    void grid_resize(size_t grid, size_t width, size_t height);
    void grid_clear(size_t grid);
    void grid_line(size_t grid, size_t row, size_t col, msg::array cells);
    void grid_cursor_goto(size_t grid, size_t row, size_t col);
    
    void grid_scroll(size_t grid, size_t top, size_t bottom,
                     size_t left, size_t right, long rows);
    
    void hl_attr_define(size_t id, msg::map attrs);
    
    void mode_info_set(bool enabled, msg::array property_maps);
    void mode_change(msg::string name, size_t index);
    
    void default_colors_set(uint32_t fg, uint32_t bg, uint32_t sp);
};

} // namespace ui

#endif // UI_HPP
