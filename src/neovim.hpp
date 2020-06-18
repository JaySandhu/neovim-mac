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
#include <os/lock.h>
#include <functional>
#include <deque>
#include <string>
#include <vector>

#include "msgpack.hpp"
#include "ui.hpp"

using response_handler = std::function<void(const msg::object&,
                                            const msg::object&, bool)>;

constexpr uint64_t make_mode_constant(std::string_view shortname) {
    size_t size = std::min(shortname.size(), 8ul);
    uint64_t val = 0;
    uint64_t shift = 0;

    for (size_t i=0; i<size; ++i) {
        val |= ((uint64_t)shortname[i] << shift);
        shift += 8;
    }

    return val;
}

enum class neovim_mode : uint64_t {
    unknown                       = 0,
    normal                        = make_mode_constant("n"),
    normal_ctrli_insert           = make_mode_constant("niI"),
    normal_ctrli_replace          = make_mode_constant("niR"),
    normal_ctrli_virtual_replace  = make_mode_constant("niV"),
    operator_pending              = make_mode_constant("no"),
    operator_pending_forced_char  = make_mode_constant("nov"),
    operator_pending_forced_line  = make_mode_constant("noV"),
    operator_pending_forced_block = make_mode_constant("noCTRL-V"),
    visual_char                   = make_mode_constant("v"),
    visual_line                   = make_mode_constant("V"),
    visual_block                  = make_mode_constant("CTRL-V"),
    select_char                   = make_mode_constant("s"),
    select_line                   = make_mode_constant("S"),
    select_block                  = make_mode_constant("CTRL-S"),
    insert                        = make_mode_constant("i"),
    insert_completion             = make_mode_constant("ic"),
    insert_completion_ctrlx       = make_mode_constant("ix"),
    replace                       = make_mode_constant("R"),
    replace_completion            = make_mode_constant("Rc"),
    replace_completion_ctrlx      = make_mode_constant("Rx"),
    replace_virtual               = make_mode_constant("Rv"),
    command_line                  = make_mode_constant("c"),
    ex_mode_vim                   = make_mode_constant("cv"),
    ex_mode                       = make_mode_constant("ce"),
    prompt_enter                  = make_mode_constant("r"),
    prompt_more                   = make_mode_constant("rm"),
    prompt_confirm                = make_mode_constant("r?"),
    shell                         = make_mode_constant("!"),
    terminal                      = make_mode_constant("t")
};

inline neovim_mode make_neovim_mode(std::string_view shortname) {
    uint64_t val = 0;
    memcpy(&val, shortname.data(), std::min(shortname.size(), 8ul));
    return static_cast<neovim_mode>(val);
}

class unfair_lock {
private:
    os_unfair_lock os_lock;
    
public:
    unfair_lock() {
        os_lock = OS_UNFAIR_LOCK_INIT;
    }
    
    unfair_lock(const unfair_lock&) = delete;
    unfair_lock& operator=(const unfair_lock&) = delete;
    
    void lock() {
        os_unfair_lock_lock(&os_lock);
    }
    
    void unlock() {
        os_unfair_lock_unlock(&os_lock);
    }
};

class neovim {
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
    
    ui::ui_state ui;
    dispatch_queue_t queue;
    dispatch_source_t read_source;
    dispatch_source_t write_source;
    dispatch_semaphore_t semaphore;
    int read_fd;
    int write_fd;
    char read_buffer[16384];
    msg::packer packer;
    msg::unpacker unpacker;
    unfair_lock write_lock;
    response_handler_table *handler_table;
    
    int create_sources();

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

    void ui_attach(size_t width, size_t height);
    void try_resize(size_t width, size_t height);

    void input(std::string_view input);
    void feedkeys(std::string_view keys);

    void command(std::string_view command);
    
    void command(std::string_view command, response_handler handler);
    
    void eval(std::string_view expr,
              dispatch_time_t timeout,
              response_handler handler);
    
    void get_buffer_info(response_handler handler);
    
    void paste(std::string_view data);

    void error_writeln(std::string_view error);
    
    neovim_mode get_mode();

    void input_mouse(std::string_view button,
                     std::string_view action,
                     std::string_view modifiers,
                     size_t row, size_t col);
};

#endif // NEOVIM_HPP
