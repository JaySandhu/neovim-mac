//
//  Neovim Mac
//  neovim.hpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef NEOVIM_HPP
#define NEOVIM_HPP

#include <dispatch/dispatch.h>
#include <functional>
#include <deque>
#include <string>
#include <vector>

#include "msgpack.hpp"
#include "unfair_lock.hpp"
#include "ui.hpp"

namespace nvim {

/// RPC response handler
///
/// @param error        Null if no error occurred, otherwise an error object.
/// @param result       Null if an error occurred, otherwise a result object.
/// @param timed_out    True if the request timed out, otherwise false. If the
///                     request timed out the values of error and result
///                     are undefined. If the request had no time out this value
///                     can be ignored.
using response_handler = std::function<void(const msg::object &error,
                                            const msg::object &result,
                                            bool timed_out)>;

/// Neovim modes. See nvim :help mode() for more information.
enum class mode : uint64_t {
    cancelled,
    timed_out,
    unknown,
    ex_mode_vim,
    ex_mode,
    prompt_enter,
    prompt_more,
    prompt_confirm,
    terminal,
    command_line,
    normal,
    normal_ctrli_insert,
    normal_ctrli_replace,
    normal_ctrli_virtual_replace,
    operator_pending,
    operator_pending_forced_char,
    operator_pending_forced_line,
    operator_pending_forced_block,
    visual_char,
    visual_line,
    visual_block,
    select_char,
    select_line,
    select_block,
    insert,
    insert_completion,
    insert_completion_ctrlx,
    replace,
    replace_completion,
    replace_completion_ctrlx,
    replace_virtual,
    shell
};

/// Returns true if mode is an ex mode, otherwise false.
inline bool is_ex_mode(nvim::mode mode) {
    return mode == mode::ex_mode ||
           mode == mode::ex_mode_vim;
}

/// Returns true if mode is a visual mode, otherwise false.
inline bool is_visual_mode(nvim::mode mode) {
    return mode == mode::visual_block ||
           mode == mode::visual_char  ||
           mode == mode::visual_line;
}

/// Returns true if mode is a normal mode, otherwise false.
inline bool is_normal_mode(nvim::mode mode) {
    return mode == mode::normal               ||
           mode == mode::normal_ctrli_insert  ||
           mode == mode::normal_ctrli_replace ||
           mode == mode::normal_ctrli_virtual_replace;
}

/// Returns true if mode is a select mode, otherwise false.
inline bool is_select_mode(nvim::mode mode) {
    return mode == mode::select_block ||
           mode == mode::select_char  ||
           mode == mode::select_line;
}

/// Returns true if mode is an insert mode, otherwise false.
inline bool is_insert_mode(nvim::mode mode) {
    return mode == mode::insert            ||
           mode == mode::insert_completion ||
           mode == mode::insert_completion_ctrlx;
}

/// Returns true if mode is a replace mode, otherwise false.
inline bool is_replace_mode(nvim::mode mode) {
    return mode == mode::replace                  ||
           mode == mode::replace_completion       ||
           mode == mode::replace_completion_ctrlx ||
           mode == mode::replace_virtual;
}

/// Returns true if mode is a command line mode, otherwise false.
inline bool is_command_line_mode(nvim::mode mode) {
    return mode == mode::command_line;
}

/// Returns true if mode is a terminal mode, otherwise false.
inline bool is_terminal_mode(nvim::mode mode) {
    return mode == mode::terminal;
}

/// Returns true if an operator is currently pending, otherwise false.
inline bool is_operator_pending(nvim::mode mode) {
    return mode == mode::operator_pending ||
           mode == mode::operator_pending_forced_char ||
           mode == mode::operator_pending_forced_line ||
           mode == mode::operator_pending_forced_block;
}

/// Returns true if mode represents a user prompt, otherwise false.
inline bool is_prompt(nvim::mode mode) {
    return mode == mode::prompt_enter ||
           mode == mode::prompt_more  ||
           mode == mode::prompt_confirm;
}

/// Returns true if mode indicates that Neovim is currently busy.
inline bool is_busy(nvim::mode mode) {
    return mode == mode::cancelled ||
           mode == mode::timed_out ||
           mode == mode::unknown;
}

/// A Neovim RPC client. Represents a connection to a Neovim process.
///
/// Only one remote connection should be established per process object. That is
/// to say only call spawn / connect once per object. Before a remote connection
/// is made be sure to set the window_controller.
///
/// The lifetime of the process object should extend form the point the
/// connection is established until the window controller receives a shutdown()
/// message. Should the lifetime end before that, it will result in a runtime
/// crash.
class process {
private:
    struct response_handler_table;

    struct response_context {
        response_handler_table *table;
        response_handler handler;
        bool complete;
        bool has_timeout;
        bool timed_out;
    };

    struct response_handler_table {
        unfair_lock table_lock;
        std::deque<response_context> contexts;
        std::vector<response_context*> freelist;
        std::vector<response_context*> handler_table;
        size_t last_index;

        response_handler_table():
            handler_table(16),
            last_index(0) {}

        response_context* alloc_context();
        uint32_t store_context(response_context *context);

        void free_context(response_context *context) {
            freelist.push_back(context);
        }

        void lock() {
            table_lock.lock();
        }

        void unlock() {
            table_lock.unlock();
        }

        bool has_handler(size_t msgid) {
            return msgid < handler_table.size() && handler_table[msgid];
        }

        response_context* get(size_t msgid) {
            response_context *context = handler_table[msgid];
            handler_table[msgid] = nullptr;
            return context;
        }
    };

    /// Tracks the current state of dispatch_sources.
    enum class dispatch_source_state {
        resumed,
        suspended,
        cancelled
    };

    nvim::ui_controller ui;
    dispatch_queue_t queue;
    dispatch_source_t read_source;
    dispatch_source_t write_source;
    dispatch_semaphore_t semaphore;
    dispatch_source_state read_state;
    dispatch_source_state write_state;
    int read_fd;
    int write_fd;
    char read_buffer[16384];
    msg::packer packer;
    msg::unpacker unpacker;
    unfair_lock write_lock;
    response_handler_table *handler_table;

    int  io_init(int readfd, int writefd);
    void io_can_read();
    void io_can_write();
    void io_error();
    void io_cancel();

    uint32_t store_handler(response_handler &&handler);
    uint32_t store_handler(dispatch_time_t timeout, response_handler &&handler);

    void on_rpc_message(const msg::object &obj);
    void on_rpc_response(msg::array obj);
    void on_rpc_notification(msg::array obj);

    template<typename ...Args>
    void rpc_request(uint32_t id, std::string_view method, const Args& ...args);

public:
    process();
    process(const process&) = delete;
    process& operator=(const process&) = delete;
    ~process();

    /// Returns a pointer to the most up to date global grid object.
    /// Calling this function invalidates pointers previously returned by this
    /// function.
    const nvim::grid* get_global_grid() {
        return ui.get_global_grid();
    }

    /// Returns the current Neovim options.
    nvim::ui_options get_ui_options() {
        return ui.get_ui_options();
    }

    /// Returns the Neovim window title.
    std::string get_title() {
        return ui.get_title();
    }

    /// Returns the guifont option.
    std::string get_guifont() {
        return ui.get_guifont();
    }

    /// Set the window controller.
    ///
    /// The window controller receives various UI related messages.
    /// Note: The window controller must be set before connecting to a Neovim
    /// process. Failing to do so will result in a runtime crash.
    void set_controller(window_controller controller);

    /// Spawns and connects to a new Neovim process.
    /// @param path         Path to Neovim executable.
    /// @param argv         Arguments passed to the new process.
    /// @param env          Environment variables passed to the new process.
    /// @param workingdir   The new process's working directory.
    /// @returns An errno code if an error occurred, 0 if no error occurred.
    int spawn(const char *path, const char *argv[],
              const char *env[], const char *workingdir);

    /// Connect to an existing Neovim process via a Unix domain socket.
    /// @returns An errno code if an error occurred, 0 if no error occurred.
    int connect(std::string_view addr);

    /// Synchronously attaches to the remote UI process.
    /// @param width    Requested screen columns.
    /// @param height   Requested screen rows.
    /// Blocks until the first UI flush event. Once this function returns, the
    /// first grid is ready to be drawn. Attaches using nvim_ui_attach with
    /// ext_linegrid enabled and all other ext options disabled.
    void ui_attach(size_t width, size_t height);

    /// Synchronously attach to the remote UI process and wait for VimEnter.
    ///
    /// @param width    Requested screen columns.
    /// @param height   Requested screen rows.
    /// @param timeout  Maximum time to wait for VimEnter.
    ///
    /// Similar to ui_attach, except this function blocks until the first UI
    /// flush event following VimEnter. The first grid following VimEnter is
    /// usually closer to what the user expects to see (colorschemes are applied
    /// and files are loaded). Neovim may be blocked before VimEnter, so use
    /// a small timeout value.
    ///
    /// Note: This function only makes sense for Neovim processes started with
    /// the --embed flag that are waiting for a UI to attach.
    void ui_attach_wait(size_t width, size_t height, dispatch_time_t timeout);

    /// Calls API method nvim_try_resize. Resizes the global grid.
    /// @param width    The new requested width.
    /// @param height   The new requested height.
    void try_resize(size_t width, size_t height);

    /// Calls API method nvim_input.
    /// Used for raw keyboard input. Input should be escaped.
    /// @param input Keyboard input.
    void input(std::string_view input);

    /// Calls API method nvim_feedkeys.
    /// Keys is assumed to contain CSI bytes. Keys are not remapped.
    void feedkeys(std::string_view keys);

    /// Calls API method nvim_command. Executes an ex command.
    /// Note: Neovim may not process this command immediately. For example,
    /// commands are not processed while Neovim is waiting for prompt input.
    void command(std::string_view command);

    /// Calls API method nvim_command with a response handler.
    /// On execution error fails with VimL error, does not update v:errmsg.
    /// No timeout is set on the request.
    void command(std::string_view command, response_handler handler);

    /// Calls API method nvim_eval. Evaluates a VimL expression.
    /// @param expr     VimL expression.
    /// @param timeout  Request timeout.
    /// @param handler  The response handler. Error is the VimL error. Result
    ///                 is the evaulation result.
    void eval(std::string_view expr,
              dispatch_time_t timeout,
              response_handler handler);

    /// Calls API method nvim_paste. Pastes at cursor, in any mode.
    /// @param data Multi-line input, may be binary and contain NUL bytes.
    void paste(std::string_view data);

    /// Calls API method nvim_error_writeln.
    /// Writes a message to the nvim error buffer. Appends a new line character
    /// and flushes the buffer.
    /// @param error The error string.
    void error_writeln(std::string_view error);

    /// Drops text as though it was drag and dropped into Neovim.
    ///
    /// Replicates the native macOS behavior, that is drops the text at the
    /// current cursor position and selects it. For best results ensure that
    /// Neovim is in normal mode before calling this function.
    /// @param text A list of lines.
    void drop_text(const std::vector<std::string_view> &text);

    /// Opens a list of files in tabs.
    ///
    /// This function attempts to emulate MacVim's behavior. That is:
    ///   - If in an untitled empty window, edit in the current buffer.
    ///   - If the file is open in another tab, switch to the tab and make it's
    ///     window active.
    ///   - Other wise open the file in a new tab.
    void open_tabs(const std::vector<std::string_view> &paths);

    /// Returns the current Neovim mode.
    ///
    /// Synchronously calls the API method nvim_get_mode and returns the result
    /// as a nvim::mode. On a successful call, the time taken is in the order of
    /// nanoseconds. This call will timeout in 100ms and return mode::timed_out.
    /// If the Neovim connection has shutdown, or is in the process of shutting
    /// down, mode::cancelled is returned.
    nvim::mode get_mode();

    /// Calls API method nvim_input_mouse. Used for real time mouse input.
    ///
    /// @param button   One of "left", "right", "middle", or "wheel".
    /// @param action   For non wheel mouse buttons, one of "press", "drag"
    ///                 or "release". For mouse wheel, pass the direction,
    ///                 "left", "right", "up", or "down".
    /// @param row      Mouse row position.
    /// @param col      Mouse column position.
    ///
    /// Note: All indexes are zero based.
    void input_mouse(std::string_view button,
                     std::string_view action,
                     std::string_view modifiers,
                     size_t row, size_t col);

    /// Tests how many of the given files are currently open.
    /// @param paths    Absolute paths of the files to consider.
    /// @param timeout  The timeout for the request.
    /// @param handler  The response handler. On success the result object is
    ///                 an msg::integer representing the number of open files.
    void open_count(const std::vector<std::string_view> &paths,
                    dispatch_time_t timeout, response_handler handler);
};

} // namesapce nvim

#endif // NEOVIM_HPP
