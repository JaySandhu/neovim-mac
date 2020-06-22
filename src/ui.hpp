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
#include "unfair_lock.hpp"
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
    
    uint32_t opaque() const {
        return value | 0xFF000000;
    }
    
    operator uint32_t() const {
        return value;
    }
};

enum class cursor_shape : uint8_t {
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
    bool blinks;
    uint16_t percentage;
    uint16_t blinkwait;
    uint16_t blinkon;
    uint16_t blinkoff;
};

struct mode_info {
    cursor_attributes cursor_attrs;
    std::string mode_name;
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
            // Fallback to default colors
            return table.data();
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

using grapheme_cluster = std::array<char, 24>;

struct grapheme_cluster_view {
    const grapheme_cluster *graphemes;
    size_t length;
    
    grapheme_cluster_view(const grapheme_cluster &graphemes, size_t length):
        graphemes(&graphemes), length(length) {}
    
    grapheme_cluster value() const {
        return *graphemes;
    }
    
    const char* data() const {
        return graphemes->data();
    }
    
    size_t size() const {
        return length;
    }
};

struct cell {
    grapheme_cluster text;
    uint16_t size;
    attributes attrs;
    
    grapheme_cluster graphemes() const {
        return text;
    }
    
    grapheme_cluster_view graphemes_view() const {
        return grapheme_cluster_view(text, size);
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
    
    uint32_t cellwidth() const {
        return (bool)(attrs.flags & attributes::doublewidth) + 1;
    }
};

struct grid_size {
    size_t width;
    size_t height;
};

struct grid_point {
    size_t row;
    size_t column;
};

inline bool operator==(const grid_size &left, const grid_size &right) {
    return memcmp(&left, &right, sizeof(grid_size)) == 0;
}

inline bool operator!=(const grid_size &left, const grid_size &right) {
    return memcmp(&left, &right, sizeof(grid_size)) != 0;
}

inline bool operator==(const grid_point &left, const grid_point &right) {
    return memcmp(&left, &right, sizeof(grid_point)) == 0;
}

inline bool operator!=(const grid_point &left, const grid_point &right) {
    return memcmp(&left, &right, sizeof(grid_point)) != 0;
}

struct cursor {
    cursor_attributes attrs;
    size_t row;
    size_t col;
    cell *cellptr;

    cursor(): attrs(), row(0), col(0), cellptr(nullptr) {}

    cursor(size_t cursor_row, size_t cursor_col,
           cell *cursor_cell, cursor_attributes cursor_attrs) {
        row = cursor_row;
        col = cursor_col;
        attrs = cursor_attrs;
        cellptr = cursor_cell;
        
        if (attrs.background.is_default() && attrs.foreground.is_default()) {
            attrs.background = cellptr->foreground();
            attrs.foreground = cellptr->background();
            return;
        }
            
        if (attrs.background.is_default()) {
            attrs.background = cellptr->background();
        }
            
        if (attrs.foreground.is_default()) {
            attrs.foreground = cellptr->foreground();
        }
    }

    ui::cell* cell() const {
        return cellptr;
    }

    bool blinks() const {
        return attrs.blinks;
    }

    uint16_t blinkwait() const {
        return attrs.blinkwait;
    }

    uint16_t blinkoff() const {
        return attrs.blinkoff;
    }

    uint16_t blinkon() const {
        return attrs.blinkon;
    }

    void toggle_off() {
        attrs.shape = static_cast<cursor_shape>((uint8_t)attrs.shape | 128);
    }

    void toggle_on() {
        attrs.shape = static_cast<cursor_shape>((uint8_t)attrs.shape & 127);
    }

    void toggle() {
        attrs.shape = static_cast<cursor_shape>((uint8_t)attrs.shape ^ 128);
    }
};

struct grid {
    std::vector<cell> cells;
    size_t width = 0;
    size_t height = 0;
    cursor_attributes cursor_attrs;
    size_t cursor_row;
    size_t cursor_col;
    uint64_t draw_tick = 0;
    
    ui::cursor cursor() {
        return ui::cursor(cursor_row,
                          cursor_col,
                          get(cursor_row, cursor_col),
                          cursor_attrs);
    }
    
    ui::grid_size size() const {
        return ui::grid_size{width, height};
    }
    
    void resize(size_t width, size_t heigth);
        
    cell* get(size_t row, size_t col) {
        return cells.data() + (row * width) + col;
    }
};

struct options {
    bool ext_cmdline;
    bool ext_hlstate;
    bool ext_linegrid;
    bool ext_messages;
    bool ext_multigrid;
    bool ext_popupmenu;
    bool ext_tabline;
    bool ext_termcolors;
};

inline bool operator==(const options &left, const options &right) {
    return memcmp(&left, &right, sizeof(options)) == 0;
}

inline bool operator!=(const options &left, const options &right) {
    return memcmp(&left, &right, sizeof(options)) != 0;
}

struct guifont {
    std::string_view name;
    double size;
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
    
    unfair_lock option_lock;
    std::string title;
    std::string opt_guifont;
    options opts;
    
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
    
    void set_title(msg::string title);
    
    void set_option(msg::string name, msg::object object);
    
    std::vector<guifont> get_fonts(double default_size);
};

} // namespace ui

#endif // UI_HPP
