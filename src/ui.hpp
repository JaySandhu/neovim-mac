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

#include "msgpack.hpp"
#include "window_controller.hpp"

struct grid {
    struct cell {
        char buffer[24];
        size_t size;
        
        void set(const msg::string &text);
    };
    
    std::vector<cell> cells;
    size_t width;
    size_t height;
    
    cell* get(size_t row, size_t col);
    void resize(size_t width, size_t heigth);
};

struct ui_state {
    window_controller window;
    grid global_grid;
    
    void redraw(msg::array events);
    
    void redraw_event(const msg::object &event);
    
    void flush();
    void grid_resize(size_t grid, size_t width, size_t height);
    void grid_clear(size_t grid);
    void grid_line(size_t grid, size_t row, size_t col, msg::array cells);
    
    void grid_scroll(size_t grid, size_t top, size_t bottom,
                     size_t left, size_t right, long rows);
};

#endif // UI_HPP
