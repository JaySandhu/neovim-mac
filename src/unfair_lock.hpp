//
//  Neovim Mac
//  unfair_lock.hpp
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef UNFAIR_LOCK_HPP
#define UNFAIR_LOCK_HPP

#include <os/lock.h>

/// RAII wrapper for os_unfair_lock. Meets the requirements of BasicLockable.
/// @see os_unfair_lock.
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
    
    bool try_lock() {
        return os_unfair_lock_trylock(&os_lock);
    }
    
    void assert_owner() {
        os_unfair_lock_assert_owner(&os_lock);
    }
    
    void assert_not_owner() {
        os_unfair_lock_assert_not_owner(&os_lock);
    }
};

#endif // UNFAIR_LOCK_HPP
