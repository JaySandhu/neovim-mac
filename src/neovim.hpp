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
#include "ui.hpp"

using response_handler = std::function<void(msg::object, msg::object)>;

class neovim {
private:
    class response_handler_table {
    private:
        std::vector<response_handler> handlers;
        size_t last_index;
        size_t find_empty() const;
        
    public:
        response_handler_table(): handlers(16), last_index(0) {}

        uint32_t store(response_handler &handler);
        bool has_handler(size_t index) const;
        response_handler& get(size_t index);
    };

    ui::ui_state ui;
    dispatch_queue_t queue;
    dispatch_source_t read_source;
    dispatch_source_t write_source;
    int read_fd;
    int write_fd;
    char read_buffer[16384];
    msg::packer packer;
    msg::unpacker unpacker;
    std::mutex write_lock;
    response_handler_table handler_table;
    
    int create_sources();
    
    void io_can_read();
    void io_can_write();
    void io_error();
    void io_cancel();
    
    void on_rpc_message(const msg::object &obj);
    void on_rpc_response(msg::array obj);
    void on_rpc_notification(msg::array obj);
    
    template<typename ...Args>
    void rpc_request(uint32_t id, std::string_view method, const Args& ...args);
    
public:
    neovim();
    neovim(const neovim&) = delete;
    neovim& operator=(const neovim&) = delete;
    ~neovim();
    
    ui::ui_state* ui_state() {
        return &ui;
    }
    
    void set_controller(window_controller controller);
    
    int spawn(std::string_view path,
              std::vector<std::string> args,
              std::vector<std::string> env);
    
    int connect(std::string_view addr);
    
    void quit(bool confirm=true);
    
    void get_api_info(response_handler handler);
    
    void ui_attach(int width, int height);
    
    void input(std::string_view input);
};

#endif // NEOVIM_HPP
