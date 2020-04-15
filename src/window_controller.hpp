//
//  Neovim Mac
//  window_controller.h
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef WINDOW_CONTROLLER_HPP
#define WINDOW_CONTROLLER_HPP

class window_controller {
private:
    void *controller;
    
public:
    window_controller() = default;
    window_controller(void *controller): controller(controller) {}

#ifdef __OBJC__
    window_controller(NSObject *object) {
        controller = (__bridge void*)object;
    }
#endif
    
    void close();
    void shutdown();
};

#endif // NEOVIM_CONTROLLER_HPP
