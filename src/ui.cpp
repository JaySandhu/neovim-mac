//
//  ui.cpp
//  Neovim
//
//  Created by Jay Sandhu on 4/8/20.
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//

#include <algorithm>
#include <utility>
#include <iostream>
#include <type_traits>

#include "log.h"
#include "ui.hpp"

#define NOINLINE [[gnu::noinline]]

namespace {

NOINLINE void log_row_overrun(const grid &grid, size_t row) {
    os_log_error(rpc, "Redraw error: Row overflow - Row=%zu", row);
}

NOINLINE void log_cell_type_error(const msg::object &object) {
    os_log_error(rpc, "Redraw error: Type error - Event=grid_line, CellType=%s",
                 msg::type_string(object).c_str());
}

NOINLINE void log_grid_out_of_bounds(const grid &grid, const char *event,
                                     size_t row, size_t col) {
    os_log_error(rpc, "Redraw error: Grid index out of bounds - "
                      "Event=%s, Grid=%zux%zu, Index=[row=%zu, col=%zu]",
                      event, grid.width, grid.height, row, col);
}

template<typename T>
bool is(const msg::object &object) {
    if constexpr (std::is_integral_v<T>) {
        return object.is<msg::integer>();
    } else {
        return object.is<T>();
    }
}

template<typename T>
T get(const msg::object &object) {
    if constexpr (std::is_integral_v<T>) {
        return object.get<msg::integer>().as<T>();
    } else {
        return object.get<T>();
    }
}

template<typename ...Ts, size_t ...Indexes>
void call(ui_state &state,
          void(ui_state::*member_function)(Ts...),
          const msg::array &array,
          std::integer_sequence<size_t, Indexes...>) {
    (state.*member_function)(get<Ts>(array[Indexes])...);
}

template<typename ...Ts>
void apply_one(ui_state *state,
               void(ui_state::*member_function)(Ts...),
               const msg::string &name, const msg::object &object) {
    if (object.is<msg::array>()) {
        msg::array args = object.get<msg::array>();
        
        constexpr size_t size = sizeof...(Ts);
        size_t index = 0;
        
        if (size <= args.size() && (is<Ts>(args[index++]) && ...)) {
            return call(*state, member_function, args,
                        std::make_integer_sequence<size_t, size>());
        }
    }
    
    os_log_error(rpc, "Redraw error: Type error - Event=%.*s, ArgTypes=%s",
                 (int)name.size(), name.data(),
                 msg::type_string(object).c_str());
}

template<typename ...Ts>
void apply(ui_state *state,
           void(ui_state::*member_function)(Ts...),
           const msg::string &name, const msg::array &array) {
    for (const msg::object &tuple : array) {
        apply_one(state, member_function, name, tuple);
    }
}

template<typename ...Ts>
bool type_check(const msg::array &array) {
    size_t index = 0;
    return array.size() == sizeof...(Ts) && (array[index++].is<Ts>() && ...);
}

inline void update_cells(grid::cell *cells, msg::string text,
                         size_t hlid, size_t repeat=1) {
    cells->set(text);
    
    for (int i=1; i<repeat; ++i) {
        cells[i] = *cells;
    }
}

inline bool is_single_cell(const msg::array &array,
                           msg::string &text, size_t &highlight_id) {
    if (type_check<msg::string>(array)) {
        text = array[0].get<msg::string>();
        return true;
    }
    
    if (type_check<msg::string, msg::integer>(array)) {
        text = array[0].get<msg::string>();
        highlight_id = array[1].get<msg::integer>();
        return true;
    }
    
    return false;
}

inline bool is_repeated_cell(const msg::array &array, msg::string &text,
                             size_t &highlight_id, size_t &repeat) {
    if (type_check<msg::string, msg::integer, msg::integer>(array)) {
        text = array[0].get<msg::string>();
        highlight_id = array[1].get<msg::integer>();
        repeat = array[2].get<msg::integer>();
        return true;
    }
    
    return false;
}

} // namespace

void ui_state::redraw_event(const msg::object &event_object) {
    const msg::array *event = event_object.get_if<msg::array>();
    
    if (!event || !event->size() || !event->at(0).is<msg::string>()) {
        return os_log_error(rpc, "Redraw error: Type error - Type=%s",
                            msg::type_string(event_object).c_str());
    }
    
    msg::string name = event->at(0).get<msg::string>();
    msg::array args = event->subarray(1);
    
    if (name == "grid_line") {
        return apply(this, &ui_state::grid_line, name, args);
    } else if (name == "grid_resize") {
        return apply(this, &ui_state::grid_resize, name, args);
    } else if (name == "grid_scroll") {
        return apply(this, &ui_state::grid_scroll, name, args);
    } else if (name == "flush") {
        return apply(this, &ui_state::flush, name, args);
    }
    
    os_log_info(rpc, "Redraw info: Unhandled event - Event=%.*s",
                (int)std::min(name.size(), 128ul), name.data());
}

void ui_state::redraw(msg::array events) {
    for (const msg::object &event : events) {
        redraw_event(event);
    }
}

void ui_state::grid_resize(size_t grid, size_t width, size_t height) {
    global_grid.resize(width, height);
}

inline grid::cell* grid::get(size_t row, size_t col) {
    return cells.data() + (row * width) + col;
}

inline void grid::cell::set(const msg::string &text) {
    const size_t copy = std::min(text.size(), sizeof(buffer));
    memcpy(buffer, text.data(), size);
    size = copy;
}

void ui_state::grid_line(size_t grid, size_t row,
                         size_t col, msg::array cells) {
    if (row >= global_grid.height || col >= global_grid.width) {
        return log_grid_out_of_bounds(global_grid, "grid_line", row, col);
    }
    
    grid::cell *cell = global_grid.get(row, col);
    size_t remaining = global_grid.width - col;
    
    msg::string text;
    size_t highlight_id = 0;
    size_t repeat = 0;
    
    for (const msg::object &object : cells) {
        if (!object.is<msg::array>()) {
            return log_cell_type_error(object);
        }
        
        msg::array args = object.get<msg::array>();
        
        if (is_single_cell(args, text, highlight_id)) {
            if (!remaining) {
                return log_row_overrun(global_grid, row);
            }
            
            update_cells(cell, text, highlight_id);
            cell += 1;
            remaining -= 1;
            continue;
        }
        
        if (is_repeated_cell(args, text, highlight_id, repeat)) {
            if (repeat > remaining) {
                return log_row_overrun(global_grid, row);
            }
        
            update_cells(cell, text, highlight_id, repeat);
            cell += repeat;
            remaining -= repeat;
            continue;
        }
        
        return log_cell_type_error(args);
    }
}

void ui_state::grid_scroll(size_t grid, size_t top, size_t bottom,
                           size_t left, size_t right, long rows) {
    if (bottom < top || right < left) {
        return os_log_error(rpc,
                            "Redraw error: Invalid args - "
                            "Event=grid_scroll, "
                            "Args=[top=%zu, bottom=%zu, left=%zu, right=%zu]",
                            top, bottom, left, right);
    }
    
    size_t height = bottom - top;
    size_t width = right - left;
    
    if (bottom > global_grid.height || right > global_grid.width) {
        return log_grid_out_of_bounds(global_grid, "grid_scroll", bottom, right);
    }
    
    long count;
    long row_width;
    grid::cell *dest;
    
    if (rows >= 0) {
        dest = global_grid.get(top, left);
        row_width = global_grid.width;
        count = height - rows;
    } else {
        dest = global_grid.get(bottom - 1, left);
        row_width = -global_grid.width;
        count = height + rows;
    }

    grid::cell *src = dest + ((long)global_grid.width * rows);
    size_t copy_size = sizeof(grid::cell) * width;
    
    for (long i=0; i<count; ++i) {
        memcpy(dest, src, copy_size);
        dest += row_width;
        src += row_width;
    }
}

void grid::resize(size_t new_width, size_t new_heigth) {
    width = new_width;
    height = new_heigth;
    cells.resize(new_width * new_heigth);
}

void ui_state::flush() {
    for (size_t i=0; i<global_grid.height; ++i) {
        grid::cell *row = global_grid.get(i, 0);

        for (size_t i=0; i<global_grid.width; ++i) {
            std::cout.write(row[i].buffer, row[i].size);
        }

        std::cout << '\n';
    }
}
