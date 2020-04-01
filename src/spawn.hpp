//
//  Neovim Mac
//  spawn.hpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef SPAWN_HPP
#define SPAWN_HPP

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <string>
#include <vector>

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

    int get() const {
        return fd;
    }
};

/// A Unix pipe, as created by pipe().
class unnamed_pipe {
private:
    file_descriptor read;
    file_descriptor write;

public:
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

        read = file_descriptor(fds[0]);
        write = file_descriptor(fds[1]);

        return 0;
    }

    /// Returns the pipes read end file descriptor
    int read_end() const {
        return read.get();
    }

    /// Returns the pipes write end file descriptor
    int write_end() const {
        return write.get();
    }

    /// Take ownership of the pipes read end file descriptor
    file_descriptor take_read_end() {
        return std::move(read);
    }

    /// Take ownership of the pipes write end file descriptor
    file_descriptor take_write_end() {
        return std::move(write);
    }
};

/// Defines a child process's standard streams. If a stream is set to -1 the
/// child process shares the parents corresponding stream.
struct standard_streams {
    int input  = -1;
    int output = -1;
    int error  = -1;
};

/// The result of spawning a new process with process_spawn or process_spawnp
///
/// @field pid      The process id of the new child process.
/// @field error    An error code associated with the spawn operation.
struct subprocess {
    int pid;
    int error;
};

/// Spawns a new child process that executes a specified file.
///
/// @param path     Path to the executable.
/// @param argv     Argument list passed to the new process.
/// @param env      Environment variables passed to the new process.
/// @param streams  Set the new process's standard streams.
///
/// Note: The new process inherits the current environment in addition to env.
///
/// @returns A new subprocess. If error is a non zero value, no process was
///          created and the value of pid is undefined.
subprocess process_spawn(const std::string &path,
                         std::vector<std::string> argv,
                         std::vector<std::string> env,
                         standard_streams streams);

/// Identical to process_spawn other than how the executable is specified,
/// process_spawnp searches for an executable named filename in PATH.
subprocess process_spawnp(const std::string &filename,
                          std::vector<std::string> argv,
                          std::vector<std::string> env,
                          standard_streams streams);

#endif // SPAWN_HPP
