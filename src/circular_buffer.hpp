//
//  Neovim Mac
//  circular_buffer.hpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef CIRCULAR_BUFFER_HPP
#define CIRCULAR_BUFFER_HPP

#include <cassert>
#include <cstring>
#include <mach/vm_page_size.h>

#define UNLIKELY(x) __builtin_expect((x), 0)

/// A circular buffer implemented using the virtual memory optimization from:
/// https://en.wikipedia.org/wiki/Circular_buffer#Optimization
///
/// Data (bytes) can be inserted and consumed in a FIFO fashion. The buffer
/// resizes dynamically as needed and will not overwrite old data until it is
/// consumed.
class circular_buffer {
private:
    char *buffer;
    size_t index;
    size_t length;
    size_t buffsize;

    static void* allocate_mirrored(size_t size);
    static void deallocate_mirrored(void *ptr, size_t size);

    // Round up to the nearest power of 2 greater than or equal to page size
    static size_t round_up_capacity(size_t val) {
        --val;

        for (size_t i=1; i<64; i *= 2) {
            val |= val >> i;
        }

        return mach_vm_round_page(val + 1);
    }

    void resize(size_t size);
    void insert_expanded(const void *ptr, size_t size);

public:
    circular_buffer() {
        buffer   = nullptr;
        index    = 0;
        length   = 0;
        buffsize = 0;
    }

    explicit circular_buffer(size_t initial_capacity) {
        index    = 0;
        length   = 0;
        buffsize = round_up_capacity(initial_capacity);
        buffer   = static_cast<char*>(allocate_mirrored(buffsize));
    }

    circular_buffer(const circular_buffer &other) {
        buffer   = static_cast<char*>(allocate_mirrored(other.buffsize));
        index    = 0;
        length   = other.length;
        buffsize = other.buffsize;

        memcpy(buffer, other.data(), length);
    }

    circular_buffer& operator=(const circular_buffer &other) {
        if (buffsize < other.length) {
            if (buffer) deallocate_mirrored(buffer, buffsize);

            buffsize = mach_vm_round_page(other.length);
            buffer   = static_cast<char*>(allocate_mirrored(buffsize));
        }

        index  = 0;
        length = other.length;

        memcpy(buffer, other.data(), length);
        return *this;
    }

    circular_buffer(circular_buffer &&other) {
        buffer   = other.buffer;
        index    = other.index;
        length   = other.length;
        buffsize = other.buffsize;

        other.buffer   = nullptr;
        other.index    = 0;
        other.length   = 0;
        other.buffsize = 0;
    }

    circular_buffer& operator=(circular_buffer &&other) {
        if (buffer) deallocate_mirrored(buffer, buffsize);

        buffer   = other.buffer;
        index    = other.index;
        length   = other.length;
        buffsize = other.buffsize;

        other.buffer   = nullptr;
        other.index    = 0;
        other.length   = 0;
        other.buffsize = 0;

        return *this;
    }

    ~circular_buffer() {
        if (buffer) deallocate_mirrored(buffer, buffsize);
    }

    size_t capacity() const {
        return buffsize;
    }

    size_t size() const {
        return length;
    }

    const char* data() const {
        return buffer + index;
    }

    char* data() {
        return buffer + index;
    }

    const char* begin() const {
        return buffer + index;
    }

    char* begin() {
        return buffer + index;
    }

    const char *end() const {
        return buffer + index + length;
    }

    char *end() {
        return buffer + index + length;
    }

    char operator[](size_t i) const {
        assert(i < length);
        return *(buffer + index + i);
    }

    /// Consumes all bytes currently in the buffer. After this call, size()
    /// returns zero. Complexity: Constant.
    void clear() {
        index = 0;
        length = 0;
    }

    /// Increase the capacity of the buffer to a value greater than or equal to
    /// new_capacity. Complexity: Linear in size().
    void reserve(size_t new_capacity) {
        if (new_capacity > buffsize) {
            resize(round_up_capacity(new_capacity));
        }
    }

    /// Append byte to the end of the buffer. Complexity: Constant amortized.
    void push_back(unsigned char byte) {
        if (UNLIKELY(length == buffsize)) {
            return insert_expanded(&byte, 1);
        }

        buffer[index + length++] = byte;
    }

    /// Insert bytes to the end of the buffer. Complexity: Linear in size.
    void insert(const void *bytes, size_t size) {
        const size_t remaining = buffsize - length;

        if (UNLIKELY(size > remaining)) {
            return insert_expanded(bytes, size);
        }

        memcpy(end(), bytes, size);
        length += size;
    }

    /// Consume size bytes from the start of the buffer. This marks the region
    /// as safe to overwrite with new data. Complexity: Constant.
    void consume(size_t size) {
        assert(size <= length);
        index = (index + size) & (buffsize - 1);
        length -= size;
    }
};

#endif // CIRCULAR_BUFFER_HPP
