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
#include <string>
#include <thread>
#include <vector>

#include "msgpack.hpp"
#include "neovim_controller.hpp"

using response_handler = std::function<void(msg::object, msg::object)>;

class neovim {
private:
    neovim_controller controller;
    dispatch_queue_t queue;
    dispatch_source_t read_source;
    dispatch_source_t write_source;
    int read_fd;
    int write_fd;
    msg::packer packer;
    msg::unpacker unpacker;
    char read_buffer[16384];
    std::mutex write_lock;
    std::vector<response_handler> response_handlers;
    size_t handler_last_index;
    
    int create_sources();
    
    void io_can_read();
    void io_can_write();
    void io_error();
    void io_cancel();
    
    void on_rpc_error(const msg::object &obj);
    void on_rpc_message(const msg::object &obj);
    void on_rpc_response(msg::array obj);
    void on_rpc_notification(msg::array obj);
    
    uint32_t push_handler(response_handler &handler);
    
    template<typename ...Args>
    void rpc_request(uint32_t id, std::string_view method, const Args& ...args);
    
public:
    neovim();
    neovim(const neovim&) = delete;
    neovim& operator=(const neovim&) = delete;
    ~neovim();
    
    void set_controller(neovim_controller controller);
    
    int spawn(std::string_view path,
              std::vector<std::string> args,
              std::vector<std::string> env);
    
    int connect(std::string_view addr);
    
    void quit(bool confirm=true);
    
    void get_api_info(response_handler handler);
    
    void ui_attach(int width, int height);
};

#endif // NEOVIM_HPP
