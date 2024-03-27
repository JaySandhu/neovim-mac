//
//  Neovim Mac
//  ui.cpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <algorithm>
#include <utility>
#include <iostream>
#include <type_traits>

#include "log.h"
#include "ui.hpp"

namespace nvim {
namespace {

/// A table of highlight attributes.
/// The Neovim UI API predefines highlight groups in a table and refers to them
/// by their index. We store the highlight table as a vector of cell_attributes.
/// The default highlight group is stored at index 0.
using highlight_table = std::vector<cell_attributes>;

/// Returns the highlight group with the given ID.
/// If the highlight ID is not defined, returns the default highlight group.
inline const cell_attributes* hl_get_entry(const highlight_table &table,
                                           size_t hlid) {
    if (hlid < table.size()) {
        return &table[hlid];
    }

    return &table[0];
}

/// Create new entry for the given id.
/// If the ID has been used before, the old entry is replaced.
/// Any gaps created in the table are filled by default initialized entries.
/// Note: ID 0 is reserved for the default highlight group.
inline cell_attributes* hl_new_entry(highlight_table &table, size_t hlid) {
    const size_t table_size = table.size();

    if (hlid == table_size) {
        table.push_back(table[0]);
        return &table.back();
    }

    if (hlid < table_size) {
        table[hlid] = table[0];
        return &table[hlid];
    }

    cell_attributes default_attrs = table[0];
    table.resize(hlid, default_attrs);
    return &table.back();
}

void log_grid_out_of_bounds(const grid *grid, const char *event,
                            size_t row, size_t col) {
    os_log_error(rpc, "Redraw error: Grid index out of bounds - "
                      "Event=%s, Grid=%zux%zu, Index=[row=%zu, col=%zu]",
                      event, grid->width(), grid->height(), row, col);
}

/// Type checking wrapper that:
/// Allows narrowing integer conversions.
/// Allows msg::object pass through.
template<typename T>
bool is(const msg::object &object) {
    if constexpr (!std::is_same_v<T, msg::boolean> && std::is_integral_v<T>) {
        return object.is<msg::integer>();
    } else if constexpr (std::is_same_v<T, msg::object>) {
        return true;
    } else {
        return object.is<T>();
    }
}

/// Object unwrapping wrapper that:
/// Allows narrowing integer conversions.
/// Allows msg::object pass through.
template<typename T>
T get(const msg::object &object) {
    if constexpr (!std::is_same_v<T, msg::boolean> && std::is_integral_v<T>) {
        return object.get<msg::integer>().as<T>();
    } else if constexpr (std::is_same_v<T, msg::object>) {
        return object;
    } else {
        return object.get<T>();
    }
}

template<typename ...Ts, size_t ...Indexes>
void call(ui_controller &controller,
          void(ui_controller::*member_function)(Ts...),
          const msg::array &array,
          std::integer_sequence<size_t, Indexes...>) {
    (controller.*member_function)(get<Ts>(array[Indexes])...);
}

/// Invokes member function with an array of arguments.
/// If object is an array of objects whose types match the member function's
/// signature, the member function is invoked. Otherwise a type error is logged.
template<typename ...Ts>
void apply_one(ui_controller *controller,
               void(ui_controller::*member_function)(Ts...),
               const msg::string &name, const msg::object &object) {
    if (object.is<msg::array>()) {
        msg::array args = object.get<msg::array>();
        
        constexpr size_t size = sizeof...(Ts);
        size_t index = 0;
        
        if (size <= args.size() && (is<Ts>(args[index++]) && ...)) {
            return call(*controller, member_function, args,
                        std::make_integer_sequence<size_t, size>());
        }
    }
    
    os_log_error(rpc, "Redraw error: Argument type error - "
                      "Event=%.*s, ArgTypes=%s",
                      (int)name.size(), name.data(),
                      msg::type_string(object).c_str());
}

/// Invokes member function once for each parameter tuple in array.
template<typename ...Ts>
void apply(ui_controller *controller,
           void(ui_controller::*member_function)(Ts...),
           const msg::string &name, const msg::array &array) {
    for (const msg::object &tuple : array) {
        apply_one(controller, member_function, name, tuple);
    }
}

} // namespace

grid* ui_controller::get_grid(size_t index) {
    // We don't support ext_multigrid, so index should always be 1.
    // If it isn't, we don't exaclty fail gracefully.
    if (index != 1) {
        std::abort();
    }
    
    return writing;
}

void ui_controller::redraw_event(const msg::object &event_object) {
    const msg::array *event = event_object.get_if<msg::array>();
    
    if (!event || !event->size() || !event->at(0).is<msg::string>()) {
        return os_log_error(rpc, "Redraw error: Event type error - Type=%s",
                            msg::type_string(event_object).c_str());
    }

    // Neovim update events are arrays where:
    //  - The first element is the event name
    //  - The remainining elements are an array of argument tuples.
    msg::string name = event->at(0).get<msg::string>();
    msg::array args = event->subarray(1);
    
    if (name == "grid_line") {
        return apply(this, &ui_controller::grid_line, name, args);
    } else if (name == "grid_resize") {
        return apply(this, &ui_controller::grid_resize, name, args);
    } else if (name == "grid_scroll") {
        return apply(this, &ui_controller::grid_scroll, name, args);
    } else if (name == "flush") {
        return apply(this, &ui_controller::flush, name, args);
    } else if (name == "grid_clear") {
        return apply(this, &ui_controller::grid_clear, name, args);
    } else if (name == "hl_attr_define") {
        return apply(this, &ui_controller::hl_attr_define, name, args);
    } else if (name == "default_colors_set") {
        return apply(this, &ui_controller::default_colors_set, name, args);
    } else if (name == "mode_info_set") {
        return apply(this, &ui_controller::mode_info_set, name, args);
    } else if (name == "mode_change") {
        return apply(this, &ui_controller::mode_change, name, args);
    } else if (name == "grid_cursor_goto") {
        return apply(this, &ui_controller::grid_cursor_goto, name, args);
    } else if (name == "tabline_update") {
        return apply(this, &ui_controller::tabline_update, name, args);
    } else if (name == "set_title") {
        return apply(this, &ui_controller::set_title, name, args);
    } else if (name == "busy_start") {
        return apply(this, &ui_controller::busy_start, name, args);
    } else if (name == "busy_stop") {
        return apply(this, &ui_controller::busy_stop, name, args);
    }

    // When options change, we should inform the delegate. Neovim tends to
    // send redundant option change events, so only call the delegate if the
    // options actually changed.
    if (name == "option_set") {
        std::lock_guard lock(option_lock);
        ui_options oldopts = ui_opts;
        apply(this, &ui_controller::set_option, name, args);

        if (ui_opts != oldopts && send_option_change()) {
            window.options_set();
        }
        
        return;
    }

    // The following events are ignored for now.
    if (name == "mouse_on"     ||
        name == "mouse_off"    ||
        name == "set_icon"     ||
        name == "hl_group_set" ||
        name == "win_viewport" ) {
        return;
    }
    
    os_log_info(rpc, "Redraw info: Unhandled event - Name=%.*s Args=%s",
                (int)std::min(name.size(), 128ul), name.data(),
                msg::to_string(args).c_str());
}

void ui_controller::redraw(msg::array events) {
    for (const msg::object &event : events) {
        redraw_event(event);
    }
}

void ui_controller::grid_resize(size_t grid_id, size_t width, size_t height) {
    grid *grid = get_grid(grid_id);
    grid->grid_width = width;
    grid->grid_height = height;
    grid->cells.resize(width * height);
}

template<typename ...Ts>
static bool type_check(const msg::array &array) {
    size_t index = 0;
    return array.size() == sizeof...(Ts) && (array[index++].is<Ts>() && ...);
}

/// Represents a cell update from the grid_line event.
struct cell_update {
    msg::string text;
    const cell_attributes *hlattr;
    size_t repeat;
    
    cell_update(): hlattr(nullptr), repeat(0) {}

    /// Set the cell_update from a msg::object.
    /// @param object   An object from the cells array in a grid_line event.
    /// @param hl_table  The highlight table.
    /// @returns True if object type checked correctly, otherwise false.
    bool set(const msg::object &object, const highlight_table &hl_table) {
        if (!object.is<msg::array>()) {
            return false;
        }
        
        msg::array array = object.get<msg::array>();
        
        if (type_check<msg::string>(array)) {
            text = array[0].get<msg::string>();
            repeat = 1;
            return true;
        }
        
        if (type_check<msg::string, msg::integer>(array)) {
            text = array[0].get<msg::string>();
            hlattr = hl_get_entry(hl_table, array[1].get<msg::integer>());
            repeat = 1;
            return true;
        }
            
        if (type_check<msg::string, msg::integer, msg::integer>(array)) {
            text = array[0].get<msg::string>();
            hlattr = hl_get_entry(hl_table, array[1].get<msg::integer>());
            repeat = array[2].get<msg::integer>();
            return true;
        }
        
        return false;
    }
};

void ui_controller::grid_line(size_t grid_id, size_t row,
                              size_t col, msg::array cells) {
    grid *grid = get_grid(grid_id);
    
    if (row >= grid->height() || col >= grid->width()) {
        return log_grid_out_of_bounds(grid, "grid_line", row, col);
    }
    
    cell *rowbegin = grid->get(row, 0);
    cell *cell = rowbegin + col;
    
    size_t remaining = grid->width() - col;
    cell_update update;
    
    for (const msg::object &object : cells) {
        if (!update.set(object, hl_table)) {
            return os_log_error(rpc, "Redraw error: Cell update type error - "
                                     "Event=grid_line, Type=%s",
                                     msg::type_string(object).c_str());
        }
        
        if (update.repeat > remaining) {
            return os_log_error(rpc, "Redraw error: Row overflow - "
                                     "Event=grid_line");
        }

        // Empty cells are the right cell of a double width char.
        if (update.text.size() == 0) {
            // This should never happen. We'll be defensive about it.
            if (cell == rowbegin) {
                return;
            }
            
            nvim::cell *left = cell - 1;
            left->attrs.flags |= cell_attributes::doublewidth;
            cell->attrs = left->attrs;
            cell->size = 0;

            // Double width chars never repeat.
            cell += 1;
            remaining -= 1;
        } else if (update.repeat > 0) {
            const auto updated = nvim::cell(update.text, update.hlattr);
            *cell = updated;

            for (int i=1; i<update.repeat; ++i) {
                cell[i] = updated;
            }

            cell += update.repeat;
            remaining -= update.repeat;
        }
    }
}

void ui_controller::grid_clear(size_t grid_id) {
    grid *grid = get_grid(grid_id);

    cell empty;
    empty.attrs.background = hl_table[0].background;

    for (cell &cell : grid->cells) {
        cell = empty;
    }
}

void ui_controller::grid_cursor_goto(size_t grid_id, size_t row, size_t col) {
    grid *grid = get_grid(grid_id);
    
    if (row >= grid->height() || col >= grid->width()) {
        return os_log_error(rpc, "Redraw error: Cursor out of bounds - "
                                 "Event=grid_cursor_goto, "
                                 "Grid=[%zu, %zu], Row=%zu, Col=%zu",
                                 grid->width(), grid->height(), row, col);
    }
    
    grid->cursor_row = row;
    grid->cursor_col = col;
}

void ui_controller::grid_scroll(size_t grid_id, size_t top, size_t bottom,
                                size_t left, size_t right, long rows) {
    if (bottom < top || right < left) {
        os_log_error(rpc, "Redraw error: Invalid args - "
                          "Event=grid_scroll, "
                          "Args=[top=%zu, bottom=%zu, left=%zu, right=%zu]",
                          top, bottom, left, right);
        return;
    }
    
    grid *grid = get_grid(grid_id);
    size_t height = bottom - top;
    size_t width = right - left;
    
    if (bottom > grid->height() || right > grid->width()) {
        return log_grid_out_of_bounds(grid, "grid_scroll", bottom, right);
    }
    
    long count;
    long row_width;
    cell *dest;
    
    if (rows >= 0) {
        dest = grid->get(top, left);
        row_width = grid->width();
        count = height - rows;
    } else {
        dest = grid->get(bottom - 1, left);
        row_width = -grid->width();
        count = height + rows;
    }

    cell *src = dest + ((long)grid->width() * rows);
    size_t copy_size = sizeof(cell) * width;
    
    for (long i=0; i<count; ++i) {
        memcpy(dest, src, copy_size);
        dest += row_width;
        src += row_width;
    }
}

void ui_controller::busy_start() {
    writing->cursor_hidden = true;
}

void ui_controller::busy_stop() {
    writing->cursor_hidden = false;
}

void ui_controller::flush() {
    grid *completed = writing;
    completed->draw_tick += 1;
    
    writing = complete.exchange(completed);
    *writing = *completed;

    if (signal_flush) {
        dispatch_semaphore_signal(signal_flush);
        signal_flush = nullptr;
    } else {
        window.redraw();
    }
}

static inline void adjust_defaults(const cell_attributes &def,
                                   cell_attributes &attrs) {
    bool reversed = attrs.flags & cell_attributes::reverse;
    
    if (attrs.foreground.is_default()) {
        attrs.foreground = reversed ? def.background : def.foreground;
    }
    
    if (attrs.background.is_default()) {
        attrs.background = reversed ? def.foreground : def.background;
    }
    
    if (attrs.special.is_default()) {
        attrs.special = def.special;
    }
}

void ui_controller::default_colors_set(uint32_t fg, uint32_t bg, uint32_t sp) {
    cell_attributes &def = hl_table[0];
    def.foreground = rgb_color(fg, rgb_color::default_tag);
    def.background = rgb_color(bg, rgb_color::default_tag);
    def.special = rgb_color(sp, rgb_color::default_tag);
    def.flags = 0;
    
    for (cell_attributes &attrs : hl_table) {
        adjust_defaults(def, attrs);
    }
    
    for (cell &cell : writing->cells) {
        adjust_defaults(def, cell.attrs);
    }
}

static inline void set_rgb_color(rgb_color &color, const msg::object &object) {
    if (!object.is<msg::integer>()) {
        return os_log_error(rpc, "Redraw error: RGB type error - "
                                 "Event=hl_attr_define, Type=%s",
                                 msg::type_string(object).c_str());
    }
    
    uint32_t rgb = object.get<msg::integer>().as<uint32_t>();
    color = rgb_color(rgb);
}

void ui_controller::hl_attr_define(size_t hlid, msg::map definition) {
    cell_attributes *attrs = hl_new_entry(hl_table, hlid);
    
    for (const auto& [key, value] : definition) {
        if (!key.is<msg::string>()) {
            os_log_error(rpc, "Redraw error: Map key type error - "
                              "Event=hl_attr_define, KeyType=%s, Key=%s",
                              msg::type_string(key).c_str(),
                              msg::to_string(key).c_str());
            continue;
        }

        msg::string name = key.get<msg::string>();

        if (name == "foreground") {
            set_rgb_color(attrs->foreground, value);
        } else if (name == "background") {
            set_rgb_color(attrs->background, value);
        } else if (name == "underline") {
            attrs->flags |= cell_attributes::underline;
        } else if (name == "bold") {
            attrs->flags |= cell_attributes::bold;
        } else if (name == "italic") {
            attrs->flags |= cell_attributes::italic;
        } else if (name == "strikethrough") {
            attrs->flags |= cell_attributes::strikethrough;
        } else if (name == "undercurl") {
            attrs->flags |= cell_attributes::undercurl;
        } else if (name == "special") {
            set_rgb_color(attrs->special, value);
        } else if (name == "reverse") {
            attrs->flags |= cell_attributes::reverse;
        } else {
            os_log_info(rpc, "Redraw info: Ignoring highlight attribute - "
                             "Event=hl_attr_define, Name=%.*s",
                             (int)name.size(), name.data());
        }
    }
    
    if (attrs->flags & cell_attributes::reverse) {
        std::swap(attrs->background, attrs->foreground);
    }
}

static inline cursor_shape to_cursor_shape(msg::string name) {
    if (name == "block") {
        return cursor_shape::block;
    } else if (name == "vertical") {
        return cursor_shape::vertical;
    } else if (name == "horizontal") {
        return cursor_shape::horizontal;
    }

    os_log_error(rpc, "Redraw error: Unknown cursor shape - "
                      "Event=mode_info_set CursorShape=%.*s",
                      (int)name.size(), name.data());

    return cursor_shape::block;
};

static inline void set_color_attrs(cursor_attributes *cursor_attrs,
                                   const highlight_table &hl_table,
                                   size_t hlid) {
    const cell_attributes *hl_attrs = hl_get_entry(hl_table, hlid);
    cursor_attrs->special = hl_attrs->special;
    
    if (hlid != 0) {
        cursor_attrs->foreground = hl_attrs->foreground;
        cursor_attrs->background = hl_attrs->background;
    } else {
        cursor_attrs->foreground = hl_attrs->background;
        cursor_attrs->background = hl_attrs->foreground;
    }
}

template<typename T>
bool match(std::string_view name, msg::string key, const msg::object &value) {
    if (key == name) {
        if (is<T>(value)) {
            return true;
        }

        os_log_error(rpc, "Redraw error: Map value type error - "
                          "Event=mode_info_set, Key=%s, ValueType=%s, Value=%s",
                          name.data(), msg::type_string(key).c_str(),
                          msg::to_string(value).c_str());
    }

    return false;
}

static cursor_attributes to_cursor_attributes(const highlight_table &hl_table,
                                              const msg::map &map) {
    cursor_attributes attrs = {};
    
    for (const auto& [key, value] : map) {
        if (!key.is<msg::string>()) {
            os_log_error(rpc, "Redraw error: Map key type error - "
                              "Event=mode_info_set, KeyType=%s, Key=%s",
                              msg::type_string(key).c_str(),
                              msg::to_string(key).c_str());
            continue;
        }

        msg::string name = key.get<msg::string>();

        if (match<msg::integer>("cell_percentage", name, value)) {
            attrs.percentage = get<uint16_t>(value);
        } else if (match<msg::integer>("blinkwait", name, value)) {
            attrs.blinkwait = get<uint16_t>(value);
        } else if (match<msg::integer>("blinkon", name, value)) {
            attrs.blinkon = get<uint16_t>(value);
        } else if (match<msg::integer>("blinkoff", name, value)) {
            attrs.blinkoff = get<uint16_t>(value);
        } else if (match<msg::string>("cursor_shape", name, value)) {
            attrs.shape = to_cursor_shape(value.get<msg::string>());
        } else if (match<msg::integer>("attr_id", name, value)) {
            set_color_attrs(&attrs, hl_table, get<size_t>(value));
        } else if (match<msg::string>("short_name", name, value)) {
            msg::string shortname = value.get<msg::string>();
            memcpy(&attrs.shortname, shortname.data(),
                   std::min(sizeof(attrs.shortname), shortname.size()));
        }
    }

    if (attrs.blinkwait && attrs.blinkoff  && attrs.blinkon) {
        attrs.blinks = true;
    }
    
    return attrs;
}

void ui_controller::mode_info_set(bool enabled, msg::array property_maps) {
    uint16_t current_mode_name = writing->cursor_attrs.shortname;
    mode_table.clear();
    mode_table.reserve(property_maps.size());
    
    for (const msg::object &object : property_maps) {
        if (!object.is<msg::map>()) {
            os_log_error(rpc, "Redraw error: Cursor property map type error - "
                              "Event=mode_info_set, Type=%s",
                              msg::type_string(object).c_str());
        } else {
            msg::map map = object.get<msg::map>();
            cursor_attributes attrs = to_cursor_attributes(hl_table, map);

            if (attrs.shortname == current_mode_name) {
                writing->cursor_attrs = attrs;
            }

            mode_table.push_back(attrs);
        }
    }
}

void ui_controller::mode_change(msg::string name, size_t index) {
    if (index >= mode_table.size()) {
        return os_log_error(rpc, "Redraw error: Mode index out of bounds - "
                                 "Event=mode_change, TableSize=%zu, Index=%zu",
                                 mode_table.size(), index);
    }

    writing->cursor_attrs = mode_table[index];
}

void ui_controller::set_title(msg::string new_title) {
    {
        std::lock_guard lock(option_lock);
        option_title = new_title;
    }

    if (send_option_change()) {
        window.title_set();
    }
}

std::string ui_controller::get_title() {
    std::lock_guard lock(option_lock);
    return option_title;
}

std::string ui_controller::get_guifont() {
    std::lock_guard lock(option_lock);
    return option_guifont;
}

nvim::ui_options ui_controller::get_ui_options() {
    std::lock_guard lock(option_lock);
    return ui_opts;
}

nvim::showtabline ui_controller::get_showtabline() {
    std::lock_guard lock(option_lock);
    return option_showtabline;
}

nvim::colorscheme ui_controller::get_colorscheme() {
    std::lock_guard lock(option_lock);
    return option_colorscheme;
}

static inline void set_font_option(std::string &opt_guifont,
                                   const msg::object &value,
                                   window_controller &window,
                                   bool send_option_change) {
    if (!value.is<msg::string>()) {
        return os_log_info(rpc, "Redraw info: Option type error - "
                                "Option=guifont Type=%s",
                                msg::type_string(value).c_str());
    }

    opt_guifont = value.get<msg::string>();

    if (send_option_change) {
        window.font_set();
    }
}

static inline void set_showtabline_option(showtabline &stal,
                                          const msg::object &value,
                                          window_controller &window,
                                          bool send_option_change) {

    if (!value.is<msg::integer>()) {
        return os_log_info(rpc, "Redraw info: Option type error - "
                                "Option=showtabline Type=%s",
                                msg::type_string(value).c_str());
    }

    int intval = value.get<msg::integer>().as<int>();

    if (intval < 0 || intval > 2) {
        return os_log_info(rpc, "Redraw info: Option enum error - "
                                "Option=showtabline IntVal=%i", intval);
    }

    stal = static_cast<showtabline>(intval);

    if (send_option_change) {
        window.showtabline_set();
    }
}

static inline void set_ext_option(bool &opt, const msg::object &value) {
    if (!value.is<msg::boolean>()) {
        return os_log_info(rpc, "Redraw info: Option type error - "
                                "Option=ext Type=%s",
                                msg::type_string(value).c_str());
    }

    opt = value.get<msg::boolean>();
}

void ui_controller::set_option(msg::string name, msg::object value) {
    if (name == "guifont") {
        set_font_option(option_guifont, value, window, send_option_change());
    } else if (name == "ext_cmdline")  {
        set_ext_option(ui_opts.ext_cmdline, value);
    } else if (name == "ext_hlstate")  {
        set_ext_option(ui_opts.ext_hlstate, value);
    } else if (name == "ext_linegrid")  {
        set_ext_option(ui_opts.ext_linegrid, value);
    } else if (name == "ext_messages")  {
        set_ext_option(ui_opts.ext_messages, value);
    } else if (name == "ext_multigrid")  {
        set_ext_option(ui_opts.ext_multigrid, value);
    } else if (name == "ext_popupmenu")  {
        set_ext_option(ui_opts.ext_popupmenu, value);
    } else if (name == "ext_tabline")  {
        set_ext_option(ui_opts.ext_tabline, value);
    } else if (name == "ext_termcolors")  {
        set_ext_option(ui_opts.ext_termcolors, value);
    } else if (name == "showtabline") {
        set_showtabline_option(option_showtabline, value,
                               window, send_option_change());
    }
}

struct tabpage_data {
    int handle;
    msg::string name;
    msg::string filetype;
};

static std::optional<int> to_tabpage_handle(msg::extension handle) {
    if (handle.type() != 2) {
        return std::nullopt;
    }

    auto payload = handle.payload();
    auto integer = msg::unpack_integer(payload.data(), payload.size());

    if (!integer) {
        return std::nullopt;
    }

    return integer->as<int>();
}

static std::optional<tabpage_data> to_tabpage_data(msg::object object) {
    if (!object.is<msg::map>()) {
        return std::nullopt;
    }

    msg::map map = object.get<msg::map>();
    std::optional<int> handle = std::nullopt;
    const msg::string *name = nullptr;
    msg::string filetype = "";

    for (const auto& [k, value] : map) {
        if (!k.is<msg::string>()) {
            os_log_error(rpc, "Redraw error: Map key type error - "
                              "Event=tabline_update, KeyType=%s, Key=%s",
                              msg::type_string(k).c_str(),
                              msg::to_string(k).c_str());
            continue;
        }

        msg::string key = k.get<msg::string>();

        if (key == "tab" && value.is<msg::extension>()) {
            handle = to_tabpage_handle(value.get<msg::extension>());
        } else if (key == "name") {
            name = value.get_if<msg::string>();
        } else if (key == "filetype" && value.is<msg::string>()) {
            filetype = value.get<msg::string>();
        } else {
            os_log_info(rpc, "Redraw info: Ignoring tab attribute - "
                             "Event=tabline_update, Name=%.*s, Data=%s",
                             (int)key.size(), key.data(),
                             msg::to_string(value).c_str());
        }
    }

    if (!handle || !name) {
        return std::nullopt;
    }

    tabpage_data data;
    data.handle = *handle;
    data.name = *name;
    data.filetype = filetype;
    return data;
}

static tabpage* get_tabpage(std::unordered_map<int, tabpage> &tabpage_map,
                            msg::extension handle_object) {
    auto handle = to_tabpage_handle(handle_object);

    if (!handle) {
        return nullptr;
    }

    auto iter = tabpage_map.find(*handle);

    if (iter == tabpage_map.end()) {
        return nullptr;
    }

    return &(iter->second);
}

void ui_controller::tabline_update(msg::extension selected, msg::array tabs) {
    size_t previous_tabs_count = tabpages.size();
    auto previous_tabpage_selected = tabpage_selected;
    bool have_changes = false;

    for (auto &kv : tabpage_map) {
        kv.second.closed = true;
    }

    for (const msg::object &object : tabs) {
        auto tab_data = to_tabpage_data(object);

        if (!tab_data) {
            os_log_error(rpc, "Redraw error: Tabpage data malformed - "
                              "Event=tabline_update, TabIndex=%zu, TabData=%s",
                              tabs.size(), msg::to_string(object).c_str());
            continue;
        }

        tabpage &tab = tabpage_map[tab_data->handle];
        tab.handle = tab_data->handle;
        tab.closed = false;

        if (tab.name != tab_data->name) {
            tab.name = tab_data->name;
            tab.name_changed = true;
            have_changes = true;
        }

        if (tab.filetype != tab_data->filetype) {
            tab.filetype = tab_data->filetype;
            tab.filetype_changed = true;
            have_changes = true;
        }

        tabpages.push_back(&tab);
    }

    if (tabpages.size() == previous_tabs_count) {
        return os_log_error(rpc, "Redraw error: Empty tapages array - "
                                 "Event=tabline_update");
    }

    tabpage_selected = get_tabpage(tabpage_map, selected);

    if (!tabpage_selected) {
        return os_log_error(rpc, "Redraw error: Missing selected tabpage - "
                                 "Event=tabline_update");
    }

    auto begin = tabpages.begin();
    auto previous_end = begin + previous_tabs_count;
    auto end = tabpages.end();

    if (!have_changes && previous_tabpage_selected == tabpage_selected &&
        std::equal(begin, previous_end, previous_end, end)) {
        tabpages.erase(previous_end, end);
    } else {
        tabpages.erase(begin, previous_end);
        window.tabline_update();
    }
}

static int hex_char_to_decimal(char value) {
    switch (value) {
        case '0': return 0;
        case '1': return 1;
        case '2': return 2;
        case '3': return 3;
        case '4': return 4;
        case '5': return 5;
        case '6': return 6;
        case '7': return 7;
        case '8': return 8;
        case '9': return 9;
        case 'a': return 10;
        case 'b': return 11;
        case 'c': return 12;
        case 'd': return 13;
        case 'e': return 14;
        case 'f': return 15;
        case 'A': return 10;
        case 'B': return 11;
        case 'C': return 12;
        case 'D': return 13;
        case 'E': return 14;
        case 'F': return 15;
        default:  return -1;
    }
}

static std::optional<int> to_rgb_value(char a, char b) {
    int d1 = hex_char_to_decimal(a);
    int d2 = hex_char_to_decimal(b);

    if (d1 == -1 || d2 == -1) {
        return std::nullopt;
    }

    return (d1 * 16) + d2;
}

static std::optional<rgb_color> to_rgb_color(msg::string value) {
    if (value.size() != 7 || value[0] != '#') {
        return std::nullopt;
    }

    auto red = to_rgb_value(value[1], value[2]);
    auto green = to_rgb_value(value[3], value[4]);
    auto blue = to_rgb_value(value[5], value[6]);

    if (!red || !green || !blue) {
        return std::nullopt;
    }

    return rgb_color(*red, *green, *blue);
}

static void set_color(rgb_color &color, msg::string value) {
    if (value.size() == 0) {
        color = rgb_color(0, rgb_color::default_tag);
        return;
    }

    auto rgb = to_rgb_color(value);

    if (!rgb) {
        return os_log_error(rpc, "Redraw error: Invalid color - "
                                 "Event=colorscheme_update Color=%.*s",
                                 (int)value.size(), value.data());
    }

    color = *rgb;
}

static void set_appearance(nvim::appearance &app, msg::string value) {
    if (value == "light") {
        app = nvim::appearance::light;
    } else if (value == "dark") {
        app = nvim::appearance::dark;
    } else {
        return os_log_error(rpc, "Redraw error: Invalid appearance value - "
                                 "Event=colorscheme_update Value=%.*s",
                                 (int)value.size(), value.data());
    }
}

void ui_controller::colorscheme_update(msg::array args) {
    if (args.size() != 1 || !args[0].is<msg::map>()) {
        return os_log_error(rpc, "Redraw error: Invalid args - "
                                 "Event=colorscheme_update Args=%s",
                                 msg::to_string(args).c_str());
    }

    auto map = args[0].get<msg::map>();
    std::lock_guard<unfair_lock> lock(option_lock);

    for (const auto& [k, v] : map) {
        if (!k.is<msg::string>() || !v.is<msg::string>()) {
            os_log_error(rpc, "Redraw error: Map type error - "
                              "Event=colorscheme_update, "
                              "KeyType=%s, KeyValue=%s, "
                              "ValueType=%s, Value=%s",
                              msg::type_string(k).c_str(),
                              msg::to_string(k).c_str(),
                              msg::type_string(v).c_str(),
                              msg::to_string(v).c_str());
            continue;
        }

        auto key = k.get<msg::string>();
        auto value = v.get<msg::string>();

        if (key == "titlebar") {
            set_color(option_colorscheme.titlebar, value);
        } else if (key == "tab_button") {
            set_color(option_colorscheme.tab_button, value);
        } else if (key == "tab_button_hover") {
            set_color(option_colorscheme.tab_button_hover, value);
        } else if (key == "tab_button_highlight") {
            set_color(option_colorscheme.tab_button_highlight, value);
        } else if (key == "tab_separator") {
            set_color(option_colorscheme.tab_separator, value);
        } else if (key == "tab_background") {
            set_color(option_colorscheme.tab_background, value);
        } else if (key == "tab_selected") {
            set_color(option_colorscheme.tab_selected, value);
        } else if (key == "tab_hover") {
            set_color(option_colorscheme.tab_hover, value);
        } else if (key == "tab_title") {
            set_color(option_colorscheme.tab_title, value);
        } else if (key == "appearance") {
            set_appearance(option_colorscheme.appearance, value);
        }
    }

    window.colorscheme_update();
}

/// Makes a font object from a Vim font string.
/// If size is not given in fontstr, default_size is used.
static font make_font(std::string_view fontstr, double default_size) {
    size_t index = fontstr.size();
    size_t multiply = 1;
    size_t size = 0;

    while (index) {
        index -= 1;
        char digit = fontstr[index];

        if (isdigit(digit)) {
            size = size + (multiply * (digit - '0'));
            multiply *= 10;
        } else {
            break;
        }
    }

    if (size && index && fontstr[index] == 'h' && fontstr[index - 1] == ':') {
        return font{fontstr.substr(0, index - 1), double(size)};
    } else {
        return font{fontstr, default_size};
    }
}

static inline size_t find_unescaped_comma(std::string_view string, size_t pos) {
    for (;;) {
        pos = string.find(',', pos);

        if (pos == std::string_view::npos) {
            return pos;
        }

        // TODO: We're probably not handling multiple backslashes properly.
        //       Replace with a more robust solution.
        if (pos != 0 && string[pos - 1] != '\\') {
            return pos;
        }

        pos += 1;
    }
}

std::vector<font> parse_guifont(std::string_view guifont, double default_size) {
    std::vector<font> fonts;

    if (!guifont.size()) {
        return fonts;
    }

    size_t index = 0;

    for (;;) {
        size_t pos = find_unescaped_comma(guifont, index);

        if (pos == std::string_view::npos) {
            auto fontstr = guifont.substr(index);
            fonts.push_back(make_font(fontstr, default_size));
            break;
        }

        auto fontstr = guifont.substr(index, pos - index);
        fonts.push_back(make_font(fontstr, default_size));

        index = guifont.find_first_not_of(' ', pos + 1);

        if (pos == std::string_view::npos) {
            break;
        }
    }

    return fonts;
}

} // namespace ui
