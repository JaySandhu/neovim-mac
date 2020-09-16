//
//  Neovim Mac
//  neovim.cpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <unistd.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <limits>
#include <thread>

#include "log.h"
#include "neovim.hpp"
#include "spawn.hpp"

namespace nvim {

// RPC implementation strategy
//
// The process of making remote calls is split into two parts.
//  1. Registering response handlers.
//  2. Making remote calls.
//
// The Msgpack-RPC spec allows clients to associate 32bit ids with RPC
// requests. Servers echo this id back to us as part of their response
// message. To use this mechanism, we have to map response handlers to ids.
// That's where the response handler table comes in. It maps handlers to ids,
// and ids to handlers.
//
// When we register a response handler, we get back its associated id. We pass
// this id to rpc_request, which uses it to construct the request message. When
// we receive a RPC response, we use its id the recover the accompanying
// response handler.
//
// There's a special id, null_msgid, which indicates that a request / response
// has no response handler associated with it.
//
// Response handlers are stored in response contexts. Response contexts do
// additional bookkeeping to track timed out requests.
static constexpr uint32_t null_msgid = std::numeric_limits<uint32_t>::max();

/// Allocate a new response context. Should be freed with free_context().
process::response_context* process::response_handler_table::alloc_context() {
    if (freelist.size()) {
        response_context *back = freelist.back();
        freelist.pop_back();
        return back;
    }

    response_context &back = contexts.emplace_back();
    return &back;
}

/// Map a response context to a msgid.
/// The context can be accessed using get_context(msgid).
uint32_t process::response_handler_table::store_context(response_context *ctx) {
    const size_t table_size = handler_table.size();

    size_t empty_slot = [&](){
        for (size_t i=last_index + 1; i<table_size; ++i) {
            if (!handler_table[i]) return i;
        }

        for (size_t i=0; i<last_index; ++i) {
            if (!handler_table[i]) return i;
        }

        return table_size;
    }();

    if (empty_slot == table_size) {
        handler_table.resize(table_size * 2);
    }

    last_index = empty_slot;
    handler_table[empty_slot] = ctx;

    return (uint32_t)empty_slot;
}

/// Registers a response handler.
/// @returns The response handlers msgid.
uint32_t process::store_handler(response_handler &&handler) {
    std::lock_guard lock(*handler_table);

    response_context *context = handler_table->alloc_context();
    context->table = handler_table;
    context->handler = std::move(handler);
    context->complete = false;
    context->timed_out = false;
    context->has_timeout = false;

    return handler_table->store_context(context);
}

/// Registers a response handler with a timeout.
/// @returns The response handlers msgid.
uint32_t process::store_handler(dispatch_time_t timeout,
                                response_handler &&handler) {
    std::lock_guard lock(*handler_table);

    // Timeouts are implemented using dispatch_after. We register the handler
    // and fire off an accompanying dispatch_after block, which will either:
    //   1. Handle a timeout.
    //   2. Release the response context.
    //
    // The context is freed when it's timeout has expired and the server has
    // responded. This means that a context will live, at minimum, until its
    // timeout has fired. In the worst case, where we never receive a response
    // from the server, a context will live for the lifetime of the process
    // object.
    response_context *context = handler_table->alloc_context();
    context->table = handler_table;
    context->handler = std::move(handler);
    context->complete = false;
    context->timed_out = false;
    context->has_timeout = true;

    dispatch_after_f(timeout, queue, context, [](void *ptr) {
        response_context *context = static_cast<response_context*>(ptr);
        std::lock_guard lock(*context->table);

        if (context->complete) {
            // The request has completed. We're done, free and return.
            context->table->free_context(context);
        } else {
            // We've timed out. Mark the context as having timed out and call
            // the response handler. We overwrite the handler so we can free any
            // resources it may be holding. We can't free this context yet, we
            // might still receive a server response somewhere down the line.
            context->timed_out = true;
            context->handler(msg::object(), msg::object(), true);
            context->handler = response_handler();
        }
    });

    return handler_table->store_context(context);
}

process::process() {
    queue = nullptr;
    read_source = nullptr;
    write_source = nullptr;
    read_fd = -1;
    write_fd = -1;
    semaphore = dispatch_semaphore_create(0);
}

process::~process() {
    if (!queue) return;

    assert(dispatch_source_testcancel(read_source));
    assert(dispatch_source_testcancel(write_source));
    assert(read_fd != -1 && write_fd != -1);

    dispatch_release(queue);
    dispatch_release(read_source);
    dispatch_release(write_source);
    dispatch_release(semaphore);
    close(read_fd);

    // Read and write file descriptors may be the same. For example, when using
    // a socket. In that case avoid closing the file descriptor twice.
    if (read_fd != write_fd) {
        close(write_fd);
    }
}

int process::spawn(const char *path, const char *argv[],
                   const char *env[], const char *workingdir) {
    unnamed_pipe read_pipe;
    unnamed_pipe write_pipe;

    if (int ec = read_pipe.open()) return ec;
    if (int ec = write_pipe.open()) return ec;

    standard_streams streams;
    streams.input = write_pipe.read_end.get();
    streams.output = read_pipe.write_end.get();

    subprocess process = process_spawn(path, argv, env, workingdir, streams);

    if (process.error) {
        return process.error;
    }

    return io_init(read_pipe.read_end.release(),
                   write_pipe.write_end.release());
}

int process::connect(std::string_view addr) {
    if (addr.size() >= sizeof(sockaddr_un::sun_path)) {
        return EINVAL;
    }

    int sock = socket(AF_UNIX, SOCK_STREAM, 0);

    if (sock == -1) {
        return errno;
    }

    fcntl(sock, F_SETFD, FD_CLOEXEC);

    sockaddr_un unaddr = {};
    unaddr.sun_family = AF_UNIX;
    unaddr.sun_len = addr.size() + 1;
    memcpy(unaddr.sun_path, addr.data(), addr.size());

    if (::connect(sock, (sockaddr*)&unaddr, sizeof(unaddr)) == -1) {
        return errno;
    }

    return io_init(sock, sock);
}

/// Initializes and starts the IO loop.
/// Creates the dispatch queue, dispatch sources and response handler table.
///
/// After this function call:
///  - When readfd is readable, io_can_read() is called.
///  - When writefd is writable, io_can_write() is called.
///
/// The read source is activated immediately and is never suspended.
/// The write source is only active while there is data waiting to be written.
///
/// @param readfd   Read file descriptor.
/// @param writefd  Write file descriptor.
///
/// Note: readfd and writefd may be the same.
/// Note: This function should only be called once.
/// @returns Zero, for now.
int process::io_init(int readfd, int writefd) {
    read_fd = readfd;
    write_fd = writefd;
    queue = dispatch_queue_create(nullptr, DISPATCH_QUEUE_SERIAL);

    // Response contexts may be referenced by dispatch_after blocks (timeout
    // handlers), which can outlive the process object. To prevent dangling
    // references, we heap allocate the response_handler_table and free it when
    // we can be sure no timeout handlers are remaining.
    handler_table = new response_handler_table;
    dispatch_set_context(queue, handler_table);
    dispatch_set_finalizer_f(queue, [](void *context) {
        delete static_cast<response_handler_table*>(context);
    });

    read_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, readfd, 0, queue);

    write_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_WRITE, writefd, 0, queue);

    dispatch_set_context(read_source, this);
    dispatch_set_context(write_source, this);

    dispatch_source_set_event_handler_f(read_source, [](void *context) {
        static_cast<process*>(context)->io_can_read();
    });

    dispatch_source_set_event_handler_f(write_source, [](void *context) {
        static_cast<process*>(context)->io_can_write();
    });

    dispatch_source_set_cancel_handler_f(read_source, [](void *context) {
        process *ptr = static_cast<process*>(context);
        ptr->ui.shutdown();
    });

    dispatch_source_set_cancel_handler_f(write_source, [](void *context) {
        process *ptr = static_cast<process*>(context);
        dispatch_source_cancel(ptr->read_source);
        ptr->read_state = dispatch_source_state::cancelled;
    });

    dispatch_resume(read_source);
    read_state = dispatch_source_state::resumed;
    write_state = dispatch_source_state::suspended;

    return 0;
}

void process::io_can_read() {
    ssize_t bytes = read(read_fd, read_buffer, sizeof(read_buffer));

    if (bytes <= 0) {
        if (bytes == -1) {
            return io_error();
        }

        ui.window.close();
        return io_cancel();
    }

    unpacker.feed(read_buffer, bytes);

    while (msg::object *obj = unpacker.unpack()) {
        on_rpc_message(*obj);
    }
}

void process::io_can_write() {
    std::lock_guard lock(write_lock);
    ssize_t bytes = write(write_fd, packer.data(), packer.size());

    if (bytes == -1) {
        return io_error();
    }

    packer.consume(bytes);

    if (!packer.size()) {
        dispatch_suspend(write_source);
        write_state = dispatch_source_state::suspended;
    }
}

void process::io_error() {
    std::abort();
}

void process::io_cancel() {
    // The read source is cancelled by write_source's cancellation handler.
    // Read source's cancellation handler will in turn call shutdown.
    if (write_state != dispatch_source_state::cancelled) {
        if (write_state == dispatch_source_state::suspended) {
            dispatch_resume(write_source);
        }

        dispatch_source_cancel(write_source);
        write_state = dispatch_source_state::cancelled;
    }
}

static inline bool is_notification(const msg::array &array) {
    return array.size() == 3 &&
           array[0].is<msg::integer>() &&
           array[1].is<msg::string>() &&
           array[2].is<msg::array>() &&
           array[0].get<msg::integer>() == 2;
}

static inline bool is_response(const msg::array &array) {
    return array.size() == 4 &&
           array[0].is<msg::integer>() &&
           array[1].is<msg::integer>() &&
           array[0].get<msg::integer>() == 1;
}

void process::on_rpc_message(const msg::object &obj) {
    if (obj.is<msg::array>()) {
        msg::array array = obj.get<msg::array>();

        if (is_notification(array)) {
            return on_rpc_notification(array);
        } else if (is_response(array)) {
            return on_rpc_response(array);
        }
    }

    os_log_error(rpc, "Message type error - Type=%s, Value=%s",
                 msg::type_string(obj).c_str(), msg::to_string(obj).c_str());
}

void process::on_rpc_response(msg::array array) {
    size_t msgid = array[1].get<msg::integer>();

    if (msgid == null_msgid) {
        return;
    }

    std::lock_guard lock(*handler_table);

    if (!handler_table->has_handler(msgid)) {
        return os_log_error(rpc, "No response handler - ID=%zu, Response=%s",
                            msgid, msg::to_string(array).c_str());
    }

    response_context *context = handler_table->get(msgid);

    // If we've timed out, the response came too late. Free and return.
    if (context->timed_out) {
        handler_table->free_context(context);
        return;
    }

    // We haven't timed out. Call the handler then overwrite it. Overwriting
    // the handler here allows us to free any resources it may be referencing.
    context->handler(array[2], array[3], false);
    context->handler = response_handler();

    // If the context has an associated time out, there's still a dispatch_after
    // block that's coming. Mark it as complete and let the timeout handler
    // free it. If there's no time out, we're done, free it now.
    if (context->has_timeout) {
        context->complete = true;
    } else {
        handler_table->free_context(context);
    }
}

void process::on_rpc_notification(msg::array array) {
    msg::string name = array[1].get<msg::string>();
    msg::array args = array[2].get<msg::array>();

    if (name == "redraw") {
        return ui.redraw(args);
    } else if (name == "vimenter") {
        return ui.vimenter();
    }

    os_log_info(rpc, "Unhanled notification - Name=%.*s, Args=%s",
                (int)std::min(name.size(), 128ul), name.data(),
                msg::to_string(args).c_str());
}


template<typename ...Args>
void process::rpc_request(uint32_t msgid,
                          std::string_view method, const Args& ...args) {
    std::lock_guard lock(write_lock);

    packer.start_array(4);
    packer.pack_uint64(0);
    packer.pack_uint64(msgid);
    packer.pack_string(method);
    packer.start_array(sizeof...(Args));
    (packer.pack(args), ...);

    if (write_state == dispatch_source_state::suspended) {
        dispatch_resume(write_source);
        write_state = dispatch_source_state::resumed;
    }
}

/// Packs a string into a uint64_t at compile time.
/// Note: The string must be less than 8 bytes long.
static constexpr uint64_t constant(std::string_view shortstr) {
    size_t size = shortstr.size();
    uint64_t val = 0;
    uint64_t shift = 0;

    // Hackish. Assumes little endian memory layouts.
    // It'll have to do while we wait for std::bitcast.
    for (size_t i=0; i<size; ++i) {
        val |= ((uint64_t)shortstr[i] << shift);
        shift += 8;
    }

    return val;
}

/// Maps a Vim mode shortname to a nvim::mode enum.
static mode to_mode(std::string_view shortname) {
    if (shortname.size() > 8) {
        return mode::unknown;
    }

    uint64_t val = 0;
    memcpy(&val, shortname.data(), shortname.size());

    switch (val) {
        case constant("n"):        return mode::normal;
        case constant("niI"):      return mode::normal_ctrli_insert;
        case constant("niR"):      return mode::normal_ctrli_replace;
        case constant("niV"):      return mode::normal_ctrli_virtual_replace;
        case constant("no"):       return mode::operator_pending;
        case constant("nov"):      return mode::operator_pending_forced_char;
        case constant("noV"):      return mode::operator_pending_forced_line;
        case constant("noCTRL-V"): return mode::operator_pending_forced_block;
        case constant("v"):        return mode::visual_char;
        case constant("V"):        return mode::visual_line;
        case constant("CTRL-V"):   return mode::visual_block;
        case constant("s"):        return mode::select_char;
        case constant("S"):        return mode::select_line;
        case constant("CTRL-S"):   return mode::select_block;
        case constant("i"):        return mode::insert;
        case constant("ic"):       return mode::insert_completion;
        case constant("ix"):       return mode::insert_completion_ctrlx;
        case constant("R"):        return mode::replace;
        case constant("Rc"):       return mode::replace_completion;
        case constant("Rx"):       return mode::replace_completion_ctrlx;
        case constant("Rv"):       return mode::replace_virtual;
        case constant("c"):        return mode::command_line;
        case constant("cv"):       return mode::ex_mode_vim;
        case constant("ce"):       return mode::ex_mode;
        case constant("r"):        return mode::prompt_enter;
        case constant("rm"):       return mode::prompt_more;
        case constant("r?"):       return mode::prompt_confirm;
        case constant("!"):        return mode::shell;
        case constant("t"):        return mode::terminal;
    }

    return mode::unknown;
}

/// Maps the result of nvim_get_mode to a nvim::mode enum.
static mode to_mode(const msg::object &error, const msg::object &result) {
    if (!error.is<msg::null>() || !result.is<msg::map>()) {
        return mode::unknown;
    }

    msg::map map = result.get<msg::map>();

    for (const auto& [key, val] : map) {
        if (key.is<msg::string>()) {
            msg::string keystr = key.get<msg::string>();

            if (keystr == "mode" && val.is<msg::string>()) {
                return to_mode(val.get<msg::string>());
            }
        }
    }

    return mode::unknown;
}

mode process::get_mode() {
    mode mode;
    auto timeout = dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC);

    auto id = store_handler(timeout, [this, &mode](const msg::object &error,
                                                   const msg::object &result,
                                                   bool timed_out) {
        if (timed_out) {
            if (write_state == dispatch_source_state::cancelled) {
                mode = mode::cancelled;
            } else {
                mode = mode::timed_out;
            }
        } else {
            mode = to_mode(error, result);
        }

        dispatch_semaphore_signal(this->semaphore);
    });

    rpc_request(id, "nvim_get_mode");
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return mode;
}

void process::set_controller(window_controller window) {
    ui.window = window;
}

static constexpr std::array<std::pair<msg::string, bool>, 1> attach_options{{
    {"ext_linegrid", true}
}};

void process::ui_attach(size_t width, size_t height) {
    ui.signal_on_flush(semaphore);
    rpc_request(null_msgid, "nvim_ui_attach", width, height, attach_options);
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

void process::ui_attach_wait(size_t width, size_t height,
                             dispatch_time_t timeout) {
    ui.signal_on_entered_flush(semaphore);

    rpc_request(null_msgid, "nvim_command",
                "autocmd VimEnter * call rpcnotify(1, 'vimenter')");

    rpc_request(null_msgid, "nvim_ui_attach", width, height, attach_options);

    if (!dispatch_semaphore_wait(semaphore, timeout)) {
        return;
    }

    dispatch_sync_f(queue, this, [](void *ptr) {
        process *self = static_cast<process*>(ptr);

        // If a grid is availible, signal now, otherwise wait for a flush.
        if (self->ui.is_drawable()) {
            self->ui.signal();
        } else {
            self->ui.vimenter();
        }
    });

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

void process::try_resize(size_t width, size_t height) {
    rpc_request(null_msgid, "nvim_ui_try_resize", width, height);
}

void process::input(std::string_view input) {
    rpc_request(null_msgid, "nvim_input", input);
}

void process::feedkeys(std::string_view keys) {
    rpc_request(null_msgid, "nvim_feedkeys", keys, "n", true);
}

void process::command(std::string_view command) {
    rpc_request(null_msgid, "nvim_command", command);
}

void process::command(std::string_view command, response_handler handler) {
    auto msgid = store_handler(std::move(handler));
    rpc_request(msgid, "nvim_command", command);
}

void process::paste(std::string_view data) {
    rpc_request(null_msgid, "nvim_paste", data, false, -1);
}

void process::eval(std::string_view expr,
                   dispatch_time_t timeout, response_handler handler) {
    auto id = store_handler(timeout, std::move(handler));
    rpc_request(id, "nvim_eval", expr);
}

void process::error_writeln(std::string_view error) {
    rpc_request(null_msgid, "nvim_err_writeln", error);
}

void process::input_mouse(std::string_view button, std::string_view action,
                          std::string_view modifiers, size_t row, size_t col) {
    rpc_request(null_msgid, "nvim_input_mouse",
                button, action, modifiers, 0, row, col);
}

void process::drop_text(const std::vector<std::string_view> &text) {
    rpc_request(null_msgid, "nvim_call_function", "neovim_mac#DropText",
                std::tuple<const std::vector<std::string_view>&>(text));
}

void process::open_tabs(const std::vector<std::string_view> &paths) {
    rpc_request(null_msgid, "nvim_call_function", "neovim_mac#OpenTabs",
                std::tuple<const std::vector<std::string_view>&>(paths));
}

void process::open_count(const std::vector<std::string_view> &paths,
                         dispatch_time_t timeout, response_handler handler) {
    auto msgid = store_handler(timeout, std::move(handler));
    rpc_request(msgid, "nvim_call_function", "neovim_mac#OpenCount",
                std::tuple<const std::vector<std::string_view>&>(paths));
}

} // namespace nvim
