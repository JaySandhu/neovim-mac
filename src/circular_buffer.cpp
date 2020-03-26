//
//  Neovim Mac
//  circular_buffer.cpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#include <algorithm>
#include <cstdlib>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include "circular_buffer.hpp"

// Allocates a mirrored buffer, that is a virtual memory region size * 2 bytes
// long. The second half of which is remapped to the first. Size must be a
// multiple of the systems page size. Aborts on failure.
void* circular_buffer::allocate_mirrored(size_t size) {
    assert(size == mach_vm_trunc_page(size));
    
    mach_vm_address_t addr;
    kern_return_t error = mach_vm_allocate(mach_task_self(), &addr,
                                           size * 2, VM_FLAGS_ANYWHERE);
    
    if (error != KERN_SUCCESS) {
        std::abort();
    }
    
    mach_vm_address_t reflection = addr + size;
    vm_prot_t curr_protection;
    vm_prot_t max_protection;
    
    error = mach_vm_remap(mach_task_self(),   // source task
                          &reflection,        // source address
                          size,               // source size
                          0,                  // alignment mask
                          VM_FLAGS_OVERWRITE, // overwrite existing mappings
                          mach_task_self(),   // dest task
                          addr,               // dest address
                          false,              // copy?
                          &curr_protection,   // [out] protection attributes
                          &max_protection,    // [out] protection attributes
                          VM_INHERIT_COPY);   // child task access
    
    if (error != KERN_SUCCESS) {
        std::abort();
    }
    
    return reinterpret_cast<void*>(addr);
}

// Deallocates a pointer allocated with allocate_mirrored(). Size should be the
// same value passed to allocate_mirrored(). Aborts on failure.
void circular_buffer::deallocate_mirrored(void *ptr, size_t size) {
    auto addr = reinterpret_cast<mach_vm_address_t>(ptr);
    
    // In debug builds ptr is not deallocated, instead it's marked as
    // inaccessible, this helps catch use after frees.
#ifdef DEBUG
    auto error = mach_vm_protect(mach_task_self(), addr, size * 2, 0, 0);
#else
    auto error = mach_vm_deallocate(mach_task_self(), addr, size * 2);
#endif
    
    if (error != KERN_SUCCESS) {
        std::abort();
    }
}

void circular_buffer::resize(size_t size) {
    assert(size >= vm_page_size && (size & (size - 1)) == 0);

    char *new_buffer = static_cast<char*>(allocate_mirrored(size));
    memcpy(new_buffer, data(), length);
    deallocate_mirrored(buffer, buffsize);

    buffer   = new_buffer;
    index    = 0;
    buffsize = size;
}

void circular_buffer::insert_expanded(const void *bytes, size_t size) {
    const size_t rounded_size = round_up_capacity(size * 2);
    const size_t new_capacity = std::max(buffsize * 2, rounded_size);

    resize(new_capacity);
    memcpy(end(), bytes, size);
    length += size;
}
