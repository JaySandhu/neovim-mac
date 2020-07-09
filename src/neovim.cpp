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

extern char **environ;

/// A file descriptor with unique ownership.
class file_descriptor {
private:
    int fd;

public:
    file_descriptor(): fd(-1) {}
    file_descriptor(int fd): fd(fd) {}

    file_descriptor(const file_descriptor&) = delete;
    file_descriptor& operator=(const file_descriptor&) = delete;

    file_descriptor(file_descriptor &&other) {
        fd = other.fd;
        other.fd = -1;
    }

    file_descriptor& operator=(file_descriptor &&other) {
        if (fd != -1) close(fd);
        fd = other.fd;
        other.fd = -1;
        return *this;
    }

    ~file_descriptor() {
        if (fd != -1) close(fd);
    }

    void reset(int new_fildes) {
        if (fd != -1) close(fd);
        fd = new_fildes;
    }

    explicit operator bool() const {
        return fd != -1;
    }

    int release() {
        int ret = fd;
        fd = -1;
        return ret;
    }

    int get() const {
        return fd;
    }
};

/// A Unix pipe, as created by pipe().
struct unnamed_pipe {
    file_descriptor read_end;
    file_descriptor write_end;

    /// Opens a new pipe. The close-on-exec flag is set on both the read
    /// and write file descriptors.
    ///
    /// @returns Zero on success. An Errno error code on failure.
    int open() {
        int fds[2];

        if (pipe(fds)) {
            return errno;
        }

        // Racey, but the best we can do.
        fcntl(fds[0], F_SETFD, FD_CLOEXEC);
        fcntl(fds[1], F_SETFD, FD_CLOEXEC);

        read_end = file_descriptor(fds[0]);
        write_end = file_descriptor(fds[1]);

        return 0;
    }
};

/// RAII wrapper around posix_spawn_file_actions_t
class spawn_file_actions {
private:
    posix_spawn_file_actions_t actions;

public:
    spawn_file_actions() {
        posix_spawn_file_actions_init(&actions);
    }

    spawn_file_actions(const spawn_file_actions&) = delete;
    spawn_file_actions& operator=(const spawn_file_actions&) = delete;

    ~spawn_file_actions() {
        posix_spawn_file_actions_destroy(&actions);
    }

    int add_dup(int fd, int newfd) {
        return posix_spawn_file_actions_adddup2(&actions, fd, newfd);
    }

    const posix_spawn_file_actions_t* get() const {
        return &actions;
    }
};

/// The result of spawning a new process with process_spawn.
///
/// @field pid      The process id of the new child process.
/// @field error    The error code associated with the spawn operation.
struct subprocess {
    int pid;
    int error;
};

/// Defines a child process's standard streams.
struct standard_streams {
    int input;
    int output;
};

/// Spawns a new child process that executes a specified file.
///
/// @param path     Path to the executable.
/// @param argv     Arguments passed to the new process.
/// @param env      Environment variables passed to the new process.
/// @param streams  The new process's standard streams.
///
/// Note: The argv and env arrays must be terminated by a null pointer.
///
/// @returns A new subprocess. If error is a non zero value, no process was
///          created and the value of pid is undefined.
subprocess process_spawn(const char *path, const char *argv[],
                         char *env[], standard_streams streams) {
    subprocess process = {};
    spawn_file_actions actions;

    if ((process.error = actions.add_dup(streams.input,  0))) return process;
    if ((process.error = actions.add_dup(streams.output, 1))) return process;

    process.error = posix_spawn(&process.pid, path, actions.get(), nullptr,
                                const_cast<char**>(argv), env);

    return process;
}

static constexpr uint32_t null_msgid = std::numeric_limits<uint32_t>::max();

neovim::response_context* neovim::response_handler_table::alloc_context() {
    if (freelist.size()) {
        response_context *back = freelist.back();
        freelist.pop_back();
        return back;
    }
    
    response_context &back = contexts.emplace_back();
    return &back;
}

uint32_t neovim::response_handler_table::store_context(response_context *ctx) {
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

uint32_t neovim::store_handler(response_handler &&handler) {
    std::lock_guard lock(*handler_table);
    
    response_context *context = handler_table->alloc_context();
    context->table = handler_table;
    context->handler = std::move(handler);
    context->complete = false;
    context->timed_out = false;
    context->has_timeout = false;
    
    return handler_table->store_context(context);
}

uint32_t neovim::store_handler(dispatch_time_t timeout,
                               response_handler &&handler) {
    std::lock_guard lock(*handler_table);
    
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
            context->table->free_context(context);
        } else {
            context->timed_out = true;
            context->handler(msg::object(), msg::object(), true);
            context->handler = response_handler();
        }
    });
    
    return handler_table->store_context(context);
}

neovim::neovim() {
    queue = nullptr;
    read_source = nullptr;
    write_source = nullptr;
    read_fd = -1;
    write_fd = -1;
    semaphore = dispatch_semaphore_create(0);
}

neovim::~neovim() {
    puts("neovim destructor");
    if (!queue) return;

    assert(dispatch_source_testcancel(read_source));
    assert(dispatch_source_testcancel(write_source));
    assert(read_fd != -1 && write_fd != -1);
    
    dispatch_release(queue);
    dispatch_release(read_source);
    dispatch_release(write_source);
    dispatch_release(semaphore);
    close(read_fd);
    
    if (read_fd != write_fd) {
        close(write_fd);
    }
}

int neovim::spawn(const char *path, const char *argv[]) {
    unnamed_pipe read_pipe;
    unnamed_pipe write_pipe;
    
    if (int ec = read_pipe.open()) return ec;
    if (int ec = write_pipe.open()) return ec;
    
    standard_streams streams;
    streams.input = write_pipe.read_end.get();
    streams.output = read_pipe.write_end.get();

    subprocess process = process_spawn(path, argv, environ, streams);
    
    if (process.error) {
        return process.error;
    }
    
    read_fd = read_pipe.read_end.release();
    write_fd = write_pipe.write_end.release();
    
    return create_sources();
}
    
int neovim::connect(std::string_view addr) {
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
    
    read_fd = sock;
    write_fd = sock;
    
    return create_sources();
}
    
int neovim::create_sources() {
    queue = dispatch_queue_create(nullptr, DISPATCH_QUEUE_SERIAL);
    handler_table = new response_handler_table;
    
    dispatch_set_context(queue, handler_table);
    
    dispatch_set_finalizer_f(queue, [](void *context) {
        delete static_cast<response_handler_table*>(context);
    });
    
    read_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, read_fd, 0, queue);
    
    write_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_WRITE, write_fd, 0, queue);
    
    dispatch_set_context(read_source, this);
    dispatch_set_context(write_source, this);

    dispatch_source_set_event_handler_f(read_source, [](void *context) {
        static_cast<neovim*>(context)->io_can_read();
    });
       
    dispatch_source_set_event_handler_f(write_source, [](void *context) {
        static_cast<neovim*>(context)->io_can_write();
    });
    
    dispatch_source_set_cancel_handler_f(read_source, [](void *context) {
        neovim *ptr = static_cast<neovim*>(context);
        ptr->ui.window.shutdown();
    });
    
    dispatch_source_set_cancel_handler_f(write_source, [](void *context) {
        neovim *ptr = static_cast<neovim*>(context);
        dispatch_source_cancel(ptr->read_source);
    });
    
    dispatch_resume(read_source);
    return 0;
}

void neovim::io_can_read() {
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

void neovim::io_can_write() {
    std::lock_guard lock(write_lock);
    ssize_t bytes = write(write_fd, packer.data(), packer.size());
    
    if (bytes == -1) {
        return io_error();
    }
    
    packer.consume(bytes);
    
    if (!packer.size()) {
        dispatch_suspend(write_source);
    }
}

void neovim::io_error() {
    std::abort();
}

void neovim::io_cancel() {
    if (!dispatch_source_testcancel(write_source)) {
        dispatch_resume(write_source);
        dispatch_source_cancel(write_source);
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

void neovim::on_rpc_message(const msg::object &obj) {
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

void neovim::on_rpc_response(msg::array array) {
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

    if (context->timed_out) {
        context->table->free_context(context);
        return;
    }
    
    context->handler(array[2], array[3], false);
    context->handler = response_handler();
    
    if (context->has_timeout) {
        context->complete = true;
    } else {
        context->table->free_context(context);
    }
}

void neovim::on_rpc_notification(msg::array array) {
    msg::string name = array[1].get<msg::string>();
    msg::array args = array[2].get<msg::array>();
    
    if (name == "redraw") {
        return ui.redraw(args);
    }
    
    os_log_info(rpc, "Unhanled notification - Name=%.*s, Args=%s",
                (int)std::min(name.size(), 128ul), name.data(),
                msg::to_string(args).c_str());
}

template<typename ...Args>
void neovim::rpc_request(uint32_t msgid,
                         std::string_view method, const Args& ...args) {
    std::lock_guard lock(write_lock);
    size_t oldsize = packer.size();
    
    packer.start_array(4);
    packer.pack_uint64(0);
    packer.pack_uint64(msgid);
    packer.pack_string(method);
    packer.start_array(sizeof...(Args));
    (packer.pack(args), ...);
    
    if (oldsize == 0) {
        dispatch_resume(write_source);
    }
}

void neovim::set_controller(window_controller window) {
    ui.window = window;
}

void neovim::get_api_info(response_handler handler) {
    rpc_request(store_handler(std::move(handler)), "nvim_get_api_info");
}

void neovim::quit(bool confirm) {
    std::string_view command = confirm ? "qa" : "qa!";
    rpc_request(null_msgid, "nvim_command", command);
}

void neovim::ui_attach(size_t width, size_t height) {
    std::vector<std::pair<msg::string, bool>> map{
        {"ext_linegrid", true}
    };
    
    rpc_request(null_msgid, "nvim_ui_attach", width, height, map);
}

void neovim::try_resize(size_t width, size_t height) {
    rpc_request(null_msgid, "nvim_ui_try_resize", width, height);
}

void neovim::input(std::string_view input) {
    rpc_request(null_msgid, "nvim_input", input);
}

void neovim::feedkeys(std::string_view keys) {
    rpc_request(null_msgid, "nvim_feedkeys", keys, "n", true);
}

void neovim::command(std::string_view command) {
    rpc_request(null_msgid, "nvim_command", command);
}

void neovim::command(std::string_view command, response_handler handler) {
    auto msgid = store_handler(std::move(handler));
    rpc_request(msgid, "nvim_command", command);
}

void neovim::get_buffer_info(response_handler handler) {
    auto id = store_handler(std::move(handler));
    rpc_request(id, "nvim_call_function", "getbufinfo", std::array<int, 0>());
}

void neovim::paste(std::string_view data) {
    rpc_request(null_msgid, "nvim_paste", data, false, -1);
}

static neovim_mode to_neovim_mode(const msg::object &error,
                                  const msg::object &result) {
    if (!error.is<msg::null>() || !result.is<msg::map>()) {
        return neovim_mode::unknown;
    }
    
    msg::map map = result.get<msg::map>();
    
    for (const auto& [key, val] : map) {
        if (key.is<msg::string>()) {
            msg::string keystr = key.get<msg::string>();
            
            if (keystr == "mode" && val.is<msg::string>()) {
                return make_neovim_mode(val.get<msg::string>());
            }
        }
    }
    
    return neovim_mode::unknown;
}

neovim_mode neovim::get_mode() {
    neovim_mode mode;
    auto timeout = dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC);
        
    auto id = store_handler(timeout, [this, &mode](const msg::object &error,
                                                   const msg::object &result,
                                                   bool timed_out) {
        if (timed_out) {
            mode = neovim_mode::unknown;
        } else {
            mode = to_neovim_mode(error, result);
        }
        
        dispatch_semaphore_signal(this->semaphore);
    });
    
    rpc_request(id, "nvim_get_mode");
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return mode;
}

void neovim::eval(std::string_view expr,
                  dispatch_time_t timeout, response_handler handler) {
    auto id = store_handler(timeout, std::move(handler));
    rpc_request(id, "nvim_eval", expr);
}

void neovim::error_writeln(std::string_view error) {
    rpc_request(null_msgid, "nvim_err_writeln", error);
}

void neovim::input_mouse(std::string_view button, std::string_view action,
                         std::string_view modifiers, size_t row, size_t col) {
    rpc_request(null_msgid, "nvim_input_mouse",
                button, action, modifiers, 0, row, col);
}

void neovim::drop_text(const std::vector<std::string_view> &text) {
    rpc_request(null_msgid, "nvim_call_function", "neovim_mac#DropText",
                std::tuple<const std::vector<std::string_view>&>(text));
}

void neovim::open_tabs(const std::vector<std::string_view> &paths) {
    rpc_request(null_msgid, "nvim_call_function", "neovim_mac#OpenTabs",
                std::tuple<const std::vector<std::string_view>&>(paths));
}
