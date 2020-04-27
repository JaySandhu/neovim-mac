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
    uint8_t red;
    uint8_t green;
    uint8_t blue;
    bool is_default;
};

struct attributes {
    bool underline : 1;
    bool undercurl : 1;
    bool strikethrough : 1;
    bool doublewidth   : 1;

    bool has_attributes() const {
        return underline ||
               undercurl ||
               strikethrough ||
               doublewidth;
    }
    
    explicit operator bool() const {
        return has_attributes();
    }
};

struct font_attributes {
    bool bold   : 1;
    bool italic : 1;
    bool emoji  : 1;
    
    bool has_attributes() const {
        return bold || italic || emoji;
    }
    
    explicit operator bool() const {
        return has_attributes();
    }
};

struct cell {
    static constexpr size_t max_text_size = 24;
    
    char text[max_text_size];
    uint16_t size;
    font_attributes fontattrs;
    attributes attrs;
    rgb_color foreground;
    rgb_color background;
    rgb_color special;
    uint64_t hash;
    
    std::string_view text_view() const {
        return std::string_view(text, size);
    }
    
    bool empty() const {
        return size == 0;
    }
};

struct grid {
    std::vector<cell> cells;
    size_t width = 0;
    size_t height = 0;
    uint64_t draw_tick = 0;
    
    void resize(size_t width, size_t heigth);
        
    cell* get(size_t row, size_t col) {
        return cells.data() + (row * width) + col;
    }
};

struct ui_state {
    window_controller window;

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
        if (drawing->draw_tick < complete.load()->draw_tick) {
            drawing = complete.exchange(drawing);
        }
        
        return drawing;
    }
    
    void redraw(msg::array events);
    
    void redraw_event(const msg::object &event);
    
    void flush();
    void grid_resize(size_t grid, size_t width, size_t height);
    void grid_clear(size_t grid);
    void grid_line(size_t grid, size_t row, size_t col, msg::array cells);
    
    void grid_scroll(size_t grid, size_t top, size_t bottom,
                     size_t left, size_t right, long rows);
};

} // namespace ui

#endif // UI_HPP
