//
//  Neovim Mac
//  spawn.cpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <spawn.h>
#include "spawn.hpp"

extern char **environ;

namespace {

class file_actions {
private:
    posix_spawn_file_actions_t actions;
    
public:
    file_actions() {
        posix_spawn_file_actions_init(&actions);
    }
    
    file_actions(const file_actions&) = delete;
    file_actions& operator=(const file_actions&) = delete;
    
    ~file_actions() {
        posix_spawn_file_actions_destroy(&actions);
    }
    
    int add_dup(int fd, int newfd) {
        if (fd == -1) {
            return 0;
        } else {
            return posix_spawn_file_actions_adddup2(&actions, fd, newfd);
        }
    }
    
    const posix_spawn_file_actions_t* get() const {
        return &actions;
    }
};

subprocess spawn_impl(const std::string &path,
                      std::vector<std::string> &argv,
                      std::vector<std::string> &env,
                      standard_streams streams,
                      decltype(posix_spawn) spawn_func) {
    subprocess process = {};
    file_actions actions;
    
    if ((process.error = actions.add_dup(streams.input,  0))) return process;
    if ((process.error = actions.add_dup(streams.output, 1))) return process;
    if ((process.error = actions.add_dup(streams.error,  2))) return process;

    std::vector<char*> env_ptrs;
    std::vector<char*> argv_ptrs;
    
    for (int i=0; environ[i]; ++i) {
        env_ptrs.push_back(environ[i]);
    }
    
    for (auto &var : env) {
        env_ptrs.push_back(var.data());
    }
    
    for (auto &arg : argv) {
        argv_ptrs.push_back(arg.data());
    }
    
    // POSIX spawn functions expect these arrays to be terminated by a nullptr.
    argv_ptrs.push_back(nullptr);
    env_ptrs.push_back(nullptr);
    
    process.error = spawn_func(&process.pid, path.data(), actions.get(),
                               nullptr, argv_ptrs.data(), env_ptrs.data());

    return process;
}

} // internal

subprocess process_spawn(const std::string &path,
                         std::vector<std::string> argv,
                         std::vector<std::string> env,
                         standard_streams streams) {
    return spawn_impl(path, argv, env, streams, posix_spawn);
}

subprocess process_spawnp(const std::string &filename,
                          std::vector<std::string> argv,
                          std::vector<std::string> env,
                          standard_streams streams) {
    return spawn_impl(filename, argv, env, streams, posix_spawnp);
}
