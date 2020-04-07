//
//  Neovim Mac
//  neovim_controller.h
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef NEOVIM_CONTROLLER_HPP
#define NEOVIM_CONTROLLER_HPP

class neovim_controller {
private:
    void *controller;
    
public:
    neovim_controller() = default;
    neovim_controller(void *controller): controller(controller) {}

#ifdef __OBJC__
    neovim_controller(NSObject *object) {
        controller = (__bridge void*)object;
    }
#endif
    
    void close();
    void shutdown();
};

#endif // NEOVIM_CONTROLLER_HPP
