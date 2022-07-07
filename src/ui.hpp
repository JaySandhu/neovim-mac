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

#include <dispatch/dispatch.h>
#include <array>
#include <atomic>
#include "msgpack.hpp"
#include "unfair_lock.hpp"

namespace nvim {

class ui_controller;

/// Represents a Neovim RGB color.
/// RGBA memory layout. Colors are in the sRGB color space.
class rgb_color {
private:
    uint32_t value;

    struct default_tag_type {};
    static constexpr uint32_t is_default_bit = (1 << 31);

public:
    static constexpr default_tag_type default_tag;

    /// Default initialized rgb_color. All components are zero.
    rgb_color() {
        value = 0;
    }

    /// Constructs an rgb_color from Neovim's packed 32bit integer format.
    explicit rgb_color(uint32_t rgb) {
        // Memory layout conversion: BGR -> RGB.
        value = __builtin_bswap32(rgb << 8);
    }

    /// Constructs an rgb_color with the default tag set.
    explicit rgb_color(uint32_t rgb, default_tag_type) : rgb_color(rgb) {
        value |= is_default_bit;
    };

    /// True if the default flag was set, otherwise false.
    bool is_default() const {
        return value & is_default_bit;
    }

    /// The red color component.
    uint8_t red() const {
        return value & 0xFF;
    }

    /// The green color component.
    uint8_t green() const {
        return (value >> 8) & 0xFF;
    }

    /// The blue color component.
    uint8_t blue() const {
        return (value >> 16) & 0xFF;
    }

    /// RGB value. The 8 highest bits are zero.
    uint32_t rgb() const {
        return value & 0xFFFFFF;
    }

    /// Returns an RGBA value with an alpha value of 255.
    uint32_t opaque() const {
        return value | 0xFF000000;
    }

    /// Raw 32bit value. The 8 highest bits are undefined.
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
    uint16_t shortname;
    uint16_t percentage;
    uint16_t blinkwait;
    uint16_t blinkon;
    uint16_t blinkoff;
};

struct cell_attributes {
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

/// Cell attributes that affect font rendering.
enum class font_attributes {
    none,
    bold,
    italic,
    bold_italic
};

/// A sequence of Unicode code points that represent a single grapheme.
/// Holds up to six (maxcombine in Neovim) UTF-8 encoded code points.
using grapheme_cluster = std::array<char, 24>;

/// A grid cell.
/// A cell consists of a grapheme and various attributes that control their
/// appearance.
class cell {
private:
    grapheme_cluster text;
    uint16_t size;
    cell_attributes attrs;

    friend class ui_controller;

public:
    /// Zero initialized cell.
    cell(): text{}, size{}, attrs{} {}

    /// Constructs a cell with the given text and attributes.
    ///
    /// @param cell_text    UTF-8 encoded text representing a single grapheme.
    /// @param cell_attrs   The new cell's attributes.
    ///
    /// Note: Text is stored in a grapheme_cluster and is trimmed if needed.
    cell(msg::string cell_text, const cell_attributes *cell_attrs) {
        text = {};
        attrs = *cell_attrs;

        if (cell_text.size() == 1 && *cell_text.data() == ' ') {
            size = 0;
        } else {
            size = std::min(cell_text.size(), sizeof(grapheme_cluster));

            for (size_t i=0; i<size; ++i) {
                text[i] = cell_text[i];
            }
        }
    }

    /// The cell's grapheme as a grapheme_cluster.
    grapheme_cluster grapheme() const {
        return text;
    }

    /// The cell's grapheme as a std::string_view.
    std::string_view grapheme_view() const {
        return std::string_view(text.data(), size);
    }

    /// True if the cell is empty, false otherwise.
    /// A cell is considered empty if it is entirely white space, or if it does
    /// not have an associated grapheme.
    bool empty() const {
        return size == 0;
    }

    /// Returns the cell's foreground color.
    rgb_color foreground() const {
        return attrs.foreground;
    }

    /// Returns the cell's background color.
    rgb_color background() const {
        return attrs.background;
    }

    /// Returns the cell's special (underline, undercurl, strikethrough) color.
    rgb_color special() const {
        return attrs.special;
    }

    /// Returns the cell's font attributes.
    font_attributes font_attributes() const {
        static constexpr uint16_t mask = cell_attributes::bold |
                                         cell_attributes::italic;

        return static_cast<enum font_attributes>(attrs.flags & mask);
    }

    /// True if the cell has an underline, undercurl, or strikethrough.
    bool has_line_emphasis() const {
        return attrs.flags & (cell_attributes::underline |
                              cell_attributes::undercurl |
                              cell_attributes::strikethrough);
    }

    /// True if the cell is underlined, false otherwise.
    bool has_underline() const {
        return attrs.flags & cell_attributes::underline;
    }

    /// True if the cell has an undercurl, false otherwise.
    bool has_undercurl() const {
        return attrs.flags & cell_attributes::undercurl;
    }

    /// True if the cell has been stroke through, false otherwise.
    bool has_strikethrough() const {
        return attrs.flags & cell_attributes::strikethrough;
    }

    /// Returns 1 for single width characters, 2 for full width characters.
    uint32_t width() const {
        return (bool)(attrs.flags & cell_attributes::doublewidth) + 1;
    }

    /// Returns a newly constructed cell with the given color attributes.
    cell recolored(rgb_color foreground,
                   rgb_color background,
                   rgb_color special) const {
        nvim::cell ret = *this;
        ret.attrs.foreground = foreground;
        ret.attrs.background = background;
        ret.attrs.special = special;
        return ret;
    }
};

struct grid_size {
    int32_t width;
    int32_t height;
};

inline bool operator==(const grid_size &left, const grid_size &right) {
    return memcmp(&left, &right, sizeof(grid_size)) == 0;
}

inline bool operator!=(const grid_size &left, const grid_size &right) {
    return memcmp(&left, &right, sizeof(grid_size)) != 0;
}

struct grid_point {
    int32_t row;
    int32_t column;
};

inline bool operator==(const grid_point &left, const grid_point &right) {
    return memcmp(&left, &right, sizeof(grid_point)) == 0;
}

inline bool operator!=(const grid_point &left, const grid_point &right) {
    return memcmp(&left, &right, sizeof(grid_point)) != 0;
}

/// A grid's cursor.
///
/// Every grid has an associated cursor. A cursor consists of a grid position,
/// an underlying cell, and various cursor attributes. Attributes control the
/// appearance and behavior of the cursor.
class cursor {
private:
    cursor_attributes attrs_;
    size_t row_;
    size_t col_;
    const cell *ptr_;

public:
    /// A default constructed cursor should only be assigned to or destroyed.
    /// This constructor is only provided because Objective-C++ requires C++
    /// instance variables to be default constructible.
    cursor(): attrs_(), row_(0), col_(0), ptr_(nullptr) {}

    /// Construct a new cursor object.
    /// @param row      The row position of the cursor.
    /// @param col      The column position of the cursor.
    /// @param ptr      A pointer to the cursor's underlying cell.
    /// @param attrs    The cursor's attributes.
    cursor(size_t row, size_t col, const cell *ptr, cursor_attributes attrs):
        attrs_(attrs), row_(row), col_(col), ptr_(ptr) {
        if (attrs_.special.is_default()) {
            attrs_.special = ptr->special();
        }

        if (attrs_.background.is_default()) {
            if (attrs_.foreground.is_default()) {
                attrs_.background = ptr->foreground();
                attrs_.foreground = ptr->background();
                return;
            }

            attrs_.background = ptr->background();
        }

        if (attrs_.foreground.is_default()) {
            attrs_.foreground = ptr->foreground();
        }
    }

    /// A reference to the underlying cell.
    const nvim::cell& cell() const {
        return *ptr_;
    }

    /// The width of the underlying cell.
    uint32_t width() const {
        return ptr_->width();
    }

    /// Get the cursor shape.
    cursor_shape shape() const {
        return attrs_.shape;
    }

    /// Set the cursor shape.
    void shape(cursor_shape new_shape) {
        attrs_.shape = new_shape;
    }

    /// The cursor's row in its parent grid.
    size_t row() const {
        return row_;
    }

    /// The cursor's column in its parent grid.
    size_t col() const {
        return col_;
    }

    /// The cursor's background color.
    rgb_color background() const {
        return attrs_.background;
    }

    /// The cursor's foreground color.
    rgb_color foreground() const {
        return attrs_.foreground;
    }

    /// The cursor's underline, undercurl, and strikethrough color.
    rgb_color special() const {
        return attrs_.special;
    }

    /// True if the cursor should blink, false otherwise.
    bool blinks() const {
        return attrs_.blinks;
    }

    /// The delay in ms before the cursor starts blinking.
    uint16_t blinkwait() const {
        return attrs_.blinkwait;
    }

    /// The time in ms that the cursor is not shown.
    uint16_t blinkoff() const {
        return attrs_.blinkoff;
    }

    /// The time in ms that the cursor is shown.
    uint16_t blinkon() const {
        return attrs_.blinkon;
    }

    /// Make the cursor invisible.
    /// When the cursor is invisible, shape() returns a value outside the range
    /// of the cursor_shape enum.
    void toggle_off() {
        attrs_.shape = static_cast<cursor_shape>((uint8_t)attrs_.shape | 128);
    }

    /// Make the cursor visible.
    void toggle_on() {
        attrs_.shape = static_cast<cursor_shape>((uint8_t)attrs_.shape & 127);
    }

    /// Toggles the cursor's visbility.
    void toggle() {
        attrs_.shape = static_cast<cursor_shape>((uint8_t)attrs_.shape ^ 128);
    }
};

/// A grid of cells.
///
/// Grid's are conceptually a 2d array of cells. They are created and updated
/// by a ui_controller in response to redraw events.
class grid {
private:
    std::vector<cell> cells;
    size_t grid_width;
    size_t grid_height;
    cursor_attributes cursor_attrs;
    size_t cursor_row;
    size_t cursor_col;
    uint64_t draw_tick;

    friend class ui_controller;

public:
    grid(): grid_width(0), grid_height(0), draw_tick(0) {}

    const cell* begin() const {
        return cells.data();
    }

    const cell* end() const {
        return cells.data() + cells.size();
    }

    /// A pointer to the cell at the given row and column.
    cell* get(size_t row, size_t col) {
        return cells.data() + (row * grid_width) + col;
    }

    /// A const pointer to the cell at the given row and column position.
    const cell* get(size_t row, size_t col) const {
        return cells.data() + (row * grid_width) + col;
    }

    /// Returns the grid's cursor.
    nvim::cursor cursor() const {
        return nvim::cursor(cursor_row,
                            cursor_col,
                            get(cursor_row, cursor_col),
                            cursor_attrs);
    }

    /// Returns the grid's width.
    size_t width() const {
        return grid_width;
    }

    /// Returns the grid's height.
    size_t height() const {
        return grid_height;
    }

    /// Returns The grid's size.
    nvim::grid_size size() const {
        return nvim::grid_size{(int32_t)grid_width, (int32_t)grid_height};
    }

    /// The total number of cells in grid, equal to width() * height().
    size_t cells_size() const {
        return cells.size();
    }
};

/// Neovim UI options. See nvim :help ui-ext-options.
struct ui_options {
    bool ext_cmdline;
    bool ext_hlstate;
    bool ext_linegrid;
    bool ext_messages;
    bool ext_multigrid;
    bool ext_popupmenu;
    bool ext_tabline;
    bool ext_termcolors;
};

inline bool operator==(const ui_options &left, const ui_options &right) {
    return memcmp(&left, &right, sizeof(ui_options)) == 0;
}

inline bool operator!=(const ui_options &left, const ui_options &right) {
    return memcmp(&left, &right, sizeof(ui_options)) != 0;
}

/// The Neovim window controller.
/// The window controller receives various UI related updates.
/// Note: This is a intended to be a thin C++ wrapper around NVWindowController,
/// as such it is implemented in NVWindowController.mm.
class window_controller {
private:
    void *controller;

public:
    window_controller() = default;
    window_controller(void *controller): controller(controller) {}

    /// Called when the UI closes.
    void close();

    /// Called when the UI process exits.
    void shutdown();

    /// Called when the global grid should be redrawn.
    /// Obtain a new pointer to the global grid by calling get_global_grid(),
    /// old grid pointers may be out of date.
    void redraw();

    /// Called when the Neovim title changes.
    void title_set();

    /// Called when the guifont option changes.
    void font_set();

    /// Called when any of the options listed in nvim::options change.
    void options_set();
};

/// Responsible for handling Neovim UI events.
///
/// The UI controller translates Neovim redraw events into grids, handles UI
/// related options, and communicates with the delegate.
class ui_controller {
private:
    dispatch_semaphore_t signal_flush;
    dispatch_semaphore_t signal_enter;
    std::vector<cell_attributes> hl_table;
    std::vector<cursor_attributes> mode_table;

    // We use a multi buffering scheme with our grid objects.
    //   * complete - The most recent complete grid.
    //   * writing  - The grid we're currently writing to.
    //   * drawing  - The grid the client is currently using.
    //
    // When we receive a flush event, we swap the complete and writing pointers.
    // When the client requests the global grid, we swap the drawing and
    // complete pointers. We track draw ticks to avoid handing out stale grids.
    grid triple_buffered[3];
    std::atomic<grid*> complete;
    grid *writing;
    grid *drawing;

    unfair_lock option_lock;
    std::string option_title;
    std::string option_guifont;
    ui_options ui_opts;

    grid* get_grid(size_t index);

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

    bool send_option_change() const {
        return !signal_flush && !signal_enter;
    }

public:
    window_controller window;

    ui_controller(): hl_table(1), option_title("NVIM") {
        signal_flush = nullptr;
        signal_enter = nullptr;
        complete = &triple_buffered[0];
        writing  = &triple_buffered[1];
        drawing  = &triple_buffered[2];
    }

    ui_controller(const ui_controller&) = delete;
    ui_controller& operator=(const ui_controller&) = delete;

    /// Returns a pointer the most up to date global grid object.
    /// Calling this function invalidates pointers previously returned by this
    /// function.
    const grid* get_global_grid() {
        uint64_t tick = drawing->draw_tick;

        for (;;) {
            drawing = complete.exchange(drawing);

            if (drawing->draw_tick >= tick) {
                return drawing;
            }
        }
    }

    /// Signals semaphore on the next flush event.
    /// Precondition: No signals are currently pending.
    /// Note: window.redraw() is not called when a waiter is signaled.
    void signal_on_flush(dispatch_semaphore_t semaphore) {
        signal_flush = semaphore;
    }

    /// Signals semaphore on the first flush event following VimEnter.
    /// Precondition: No signals are currently pending.
    /// Note: window.redraw() is not called when a waiter is signaled.
    void signal_on_entered_flush(dispatch_semaphore_t semaphore) {
        signal_enter = semaphore;
    }

    /// Signals any waiting clients immediately.
    void signal() {
        if (signal_enter) {
            dispatch_semaphore_signal(signal_enter);
            signal_enter = nullptr;
        } else if (signal_flush) {
            dispatch_semaphore_signal(signal_flush);
            signal_flush = nullptr;
        }
    }

    /// Signals any waiting clients and calls window.shutdown().
    /// Note: Signaling waiters is required to avoid deadlocks.
    void shutdown() {
        signal();
        window.shutdown();
    }

    /// Notify the controller of the VimEnter event.
    void vimenter() {
        if (signal_enter) {
            signal_flush = signal_enter;
            signal_enter = nullptr;
        }
    }

    /// Returns true if a grid is ready to be drawn, otherwise false.
    bool is_drawable() {
        return complete.load()->draw_tick > 0;
    }

    /// Returns the current Neovim options.
    nvim::ui_options get_ui_options();

    /// Returns the Neovim window title.
    std::string get_title();

    /// Returns the guifont option string.
    std::string get_guifont();

    /// Handle a Neovim RPC redraw notification.
    /// @param events The paramters of the RPC notification.
    void redraw(msg::array events);
};

/// Describes a user selected font.
struct font {
    std::string_view name;
    double size;
};

/// Returns a parsed representation of the guifont option.
/// @param guifont      The guifont option string.
/// @param default_size The default font size to use if one is not specified.
/// Note: nvim::font names are views into the guifont string, as such their
/// lifetimes are tied to the memory underlying guifont.
std::vector<nvim::font> parse_guifont(std::string_view guifont,
                                      double default_size);

} // namespace nvim

#endif // UI_HPP
