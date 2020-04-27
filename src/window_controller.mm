//
//  Neovim Mac
//  window_controller.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import "NVWindowController.h"
#include "window_controller.hpp"

void window_controller::close() {
    puts("Neovim did Exit!");
    
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context close];
    });
}

void window_controller::shutdown() {
    puts("Neovim did shutdown!");
    
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context shutdown];
    });
}

void window_controller::redraw() {
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context redraw];
    });
}
