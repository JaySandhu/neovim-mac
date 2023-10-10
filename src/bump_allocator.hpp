//
//  Neovim Mac
//  bump_allocator.hpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef BUMP_ALLOCATOR_HPP
#define BUMP_ALLOCATOR_HPP

#include <algorithm>
#include <cstdlib>
#include <cstdint>
#include <sanitizer/asan_interface.h>
#include <cassert>

#define NOINLINE    [[gnu::noinline]]
#define LIKELY(x)   __builtin_expect((x), 1)
#define UNLIKELY(x) __builtin_expect((x), 0)

// A fast region based memory allocator.
//
// We maintain three pointers into a backing buffer. One to the start, one to
// the end, and one that tracks available space. To begin with the tracking
// pointer points to the end of the backing buffer.
//
// On allocation, we allocate downwards, from higher addresses to lower
// addresses. We do a quick bounds check, then bump the tracking pointer down.
// If the current backing buffer is exhausted, we add it to a list of used
// buffers and replace it with a new larger buffer.
//
// On deallocation, all used buffers are freed and the tracking pointer is
// reset to the end of the current backing buffer.
//
// If AddressSanitizer is enabled we poison and unpoison memory as needed. We
// also guard each allocation with a small poisoned memory region.

class bump_allocator {
private:
    char *start;
    char *end;
    char *ptr;
    void **used_buffers;

    static constexpr size_t alignment = 8;
    static constexpr size_t header_size = sizeof(void*);
#if __has_feature(address_sanitizer)
    static constexpr size_t guard_size = 8;
#else
    static constexpr size_t guard_size = 0;
#endif

    static constexpr uintptr_t align_down(uintptr_t val) {
        return val & ~(alignment - 1);
    }

    static constexpr size_t align_up(size_t val) {
        return (val + alignment - 1) & -alignment;
    }

    // Used buffers are stored as an intrusive singly linked list.
    // The pointer to the next buffer is stored at the start of each buffer.
    void push_used_buffer(void *buffer) {
        if (buffer) {
            void **tmp = used_buffers;
            used_buffers = static_cast<void**>(buffer);
            // store the old value at the start of used_buffers
            *used_buffers = tmp;
        }
    }

    void* pop_used_buffer() {
        void *buffer = used_buffers;
        // Read the next value from the start of used_buffers.
        used_buffers = static_cast<void**>(*used_buffers);
        return buffer;
    }

    void new_backing_buffer(size_t size) {
        assert(size >= header_size && size % alignment == 0);

        char *buffer = static_cast<char*>(::malloc(size));
        // We reserve some space so we can chain buffers into a list
        start = buffer + header_size;
        end = buffer + size;
        ptr = end;

        ASAN_POISON_MEMORY_REGION(start, size - header_size);
    }

    char* backing_buffer() const {
        if (start) {
            // The actual malloced pointer is behind our bookkeeping region
            return start - header_size;
        } else {
            return nullptr;
        }
    }

    NOINLINE void* alloc_with_new_backing(size_t size) {
        char *oldbuff = backing_buffer();

        size_t oldsize = static_cast<size_t>(end - oldbuff);
        size_t newsize = std::max(oldsize * 2, align_up(size) * 2);

        if (UNLIKELY(newsize < oldsize)) {
            std::abort(); // abort on overflow
        }

        push_used_buffer(oldbuff);
        new_backing_buffer(newsize);

        ptr = (char*)align_down((uintptr_t)end - size);
        return ptr;
    }

    void* alloc_impl(size_t size) {
        uintptr_t addr = (uintptr_t)ptr;
        uintptr_t new_ptr = align_down(addr - size);

        if (UNLIKELY(addr < size || (uintptr_t)start > new_ptr)) {
            return alloc_with_new_backing(size);
        }

        ptr = (char*)new_ptr;
        return ptr;
    }

public:
    bump_allocator() {
        start = nullptr;
        end = nullptr;
        ptr = nullptr;
        used_buffers = nullptr;
    }

    /// Construct a new allocator with the given capacity
    /// Note: some space is used for internal bookkeeping
    explicit bump_allocator(size_t init_capacity) {
        new_backing_buffer(align_up(init_capacity));
        used_buffers = nullptr;
    }

    bump_allocator(const bump_allocator&) = delete;
    bump_allocator& operator=(const bump_allocator&) = delete;

    bump_allocator(bump_allocator &&other) {
        start = other.start;
        end = other.end;
        ptr = other.ptr;
        used_buffers = other.used_buffers;

        other.start = nullptr;
        other.end = nullptr;
        other.ptr = nullptr;
        other.used_buffers = nullptr;
    }

    bump_allocator& operator=(bump_allocator &&other) {
        ::free(backing_buffer());
        dealloc_all();

        start = other.start;
        end = other.end;
        ptr = other.ptr;
        used_buffers = other.used_buffers;

        other.start = nullptr;
        other.end = nullptr;
        other.ptr = nullptr;
        other.used_buffers = nullptr;

        return *this;
    }

    ~bump_allocator() {
        ::free(backing_buffer());
        dealloc_all();
    }

    /// The capacity of the current backing buffer
    size_t capacity() const {
        return end - backing_buffer();
    }

    /// The amount of space remaining in the current backing buffer
    size_t remaining() const {
        return ptr - start;
    }

    /// Ensures that at least size bytes can be allocated without reallocation
    void reserve(size_t size) {
        if (size > remaining()) {
            push_used_buffer(backing_buffer());
            new_backing_buffer(align_up(size) + header_size);
        }
    }

    /// Allocates a word aligned memory region at least size bytes long
    void* alloc(size_t size) {
        assert(size < (UINT64_MAX - guard_size));
        void *ret = alloc_impl(size + guard_size);
        ASAN_UNPOISON_MEMORY_REGION(ptr, size);
        return ret;
    }

    /// Deallocates all current allocations
    void dealloc_all() {
        while (used_buffers) {
            ::free(pop_used_buffer());
        }

        ptr = end;
        ASAN_POISON_MEMORY_REGION(start, end - start);
    }
};

inline void* operator new(size_t size, bump_allocator &allocator) {
    return allocator.alloc(size);
}

inline void* operator new[](size_t size, bump_allocator &allocator) {
    return allocator.alloc(size);
}

#endif // BUMP_ALLOCATOR_HPP
