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

    int add_chdir(const char *directory) {
        return posix_spawn_file_actions_addchdir_np(&actions, directory);
    }
    
    const posix_spawn_file_actions_t* get() const {
        return &actions;
    }
};

} // namespace

subprocess process_spawn(const char *path, const char *argv[],
                         const char *env[], const char *workingdir,
                         standard_streams streams) {
    subprocess process = {};
    file_actions actions;

    if ((process.error = actions.add_chdir(workingdir))) return process;
    if ((process.error = actions.add_dup(streams.input,  0))) return process;
    if ((process.error = actions.add_dup(streams.output, 1))) return process;
    if ((process.error = actions.add_dup(streams.error,  2))) return process;

    process.error = posix_spawn(&process.pid, path,
                                actions.get(), nullptr,
                                const_cast<char**>(argv),
                                const_cast<char**>(env));

    return process;
}

subprocess process_spawn(const std::string &path,
                         const std::vector<std::string> &argv,
                         const std::vector<std::string> &env,
                         const std::string &workingdir,
                         standard_streams streams) {
    std::vector<const char*> argv_ptrs;
    std::vector<const char*> env_ptrs;

    for (int i=0; environ[i]; ++i) {
        env_ptrs.push_back(environ[i]);
    }

    for (auto &var : env) {
        env_ptrs.push_back(var.data());
    }

    for (auto &arg : argv) {
        argv_ptrs.push_back(arg.data());
    }

    argv_ptrs.push_back(nullptr);
    env_ptrs.push_back(nullptr);

    return process_spawn(path.c_str(), argv_ptrs.data(),
                         env_ptrs.data(), workingdir.c_str(), streams);
}
