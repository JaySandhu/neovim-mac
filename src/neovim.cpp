//
//  Neovim Mac
//  neovim.cpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <limits>

#include "spawn.hpp"
#include "neovim.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <iostream>

static constexpr uint32_t null_msgid = std::numeric_limits<uint32_t>::max();

neovim::neovim(): response_handlers(32) {
    queue = nullptr;
    read_source = nullptr;
    write_source = nullptr;
    read_fd = -1;
    write_fd = -1;
    handler_last_index = 0;
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
    close(read_fd);
    
    if (read_fd != write_fd) {
        close(write_fd);
    }
}

int neovim::spawn(std::string_view path,
                  std::vector<std::string> args,
                  std::vector<std::string> env) {
    unnamed_pipe read_pipe;
    unnamed_pipe write_pipe;
    
    if (int ec = read_pipe.open()) return ec;
    if (int ec = write_pipe.open()) return ec;
    
    standard_streams streams;
    streams.input = write_pipe.read_end.get();
    streams.output = read_pipe.write_end.get();

    subprocess process = process_spawn(std::string(path),
                                       std::move(args),
                                       std::move(env),
                                       streams);
    
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
        ptr->controller.shutdown();
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
        
        controller.close();
        return io_cancel();
    }
    
    unpacker.feed(read_buffer, bytes);
    
    while (msg::object *obj = unpacker.unpack()) {
        on_rpc_message(*obj);
    }
}

void neovim::io_can_write() {
    std::lock_guard<std::mutex> lock(write_lock);
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

void neovim::on_rpc_message(const msg::object &obj) {
    if (!obj.is<msg::array>()) {
        return on_rpc_error(obj);
    }
    
    msg::array array = obj.get<msg::array>();
    msg::object *front = array.data();
    
    if (!array.size() || !front->is<msg::uint64>()) {
        return on_rpc_error(obj);
    }
    
    msg::uint64 type = front->get<msg::uint64>();
    
    if (type == 1) {
        on_rpc_response(array);
    } else if (type == 2) {
        on_rpc_notification(array);
    } else {
        on_rpc_error(obj);
    }
}

void neovim::on_rpc_response(msg::array array) {
    if (array.size() != 4) {
        return on_rpc_error(array);
    }
    
    if (!array[1].is<msg::uint64>()) {
        return on_rpc_error(array);
    }
    
    msg::uint64 msgid = array[1].get<msg::uint64>();
    
    if (msgid == null_msgid) {
        std::cout << "Ignoring response\n";
        return;
    }
    
    if (msgid >= response_handlers.size()) {
        return on_rpc_error(array);
    }
    
    response_handler &handler = response_handlers[msgid];
    handler(array[2], array[3]);
    handler = response_handler();
    
    std::cout << "RPC Response: " << msg::to_string(array) << '\n';
}

void neovim::on_rpc_notification(msg::array array) {
    if (array.size() != 3) {
        return on_rpc_error(array);
    }
    
    if (!array[1].is<msg::string>() || !array[2].is<msg::array>()) {
        return on_rpc_error(array);
    }
    
    std::cout << "RPC Notification: " << msg::to_string(array) << '\n';
}

void neovim::on_rpc_error(const msg::object &object) {
    std::cout << "RPC Error: " << msg::to_string(object) << '\n';
}

static inline size_t
find_empty(const std::vector<response_handler> &handlers, size_t start_at) {
    size_t size = handlers.size();
    
    for (size_t i=start_at + 1; i<size; ++i) {
        if (!handlers[i]) return i;
    }
    
    for (size_t i=0; i<=start_at; ++i) {
        if (!handlers[i]) return i;
    }
    
    return size;
}

uint32_t neovim::push_handler(response_handler &handler) {
    size_t index = find_empty(response_handlers, handler_last_index);
    
    if (index == response_handlers.size()) {
        response_handlers.resize(response_handlers.size() * 2);
    }
    
    response_handlers[index] = std::move(handler);
    handler_last_index = index;
    return static_cast<uint32_t>(index);
}

template<typename ...Args>
void neovim::rpc_request(uint32_t msgid,
                         std::string_view method, const Args& ...args) {
    std::lock_guard<std::mutex> lock(write_lock);
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

void neovim::set_controller(neovim_controller new_controller) {
    controller = new_controller;
}

void neovim::get_api_info(response_handler handler) {
    rpc_request(push_handler(handler), "nvim_get_api_info");
}

void neovim::quit(bool confirm) {
    std::string_view command = confirm ? "qa" : "qa!";
    rpc_request(null_msgid, "nvim_command", command);
}

void neovim::ui_attach(int width, int height) {
    std::vector<std::pair<msg::string, bool>> map{
        {"ext_linegrid", true}
    };
    
    rpc_request(null_msgid, "nvim_ui_attach", width, height, map);
}
