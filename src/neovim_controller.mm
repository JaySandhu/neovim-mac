//
//  Neovim Mac
//  neovim_controller.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import "NVWindowController.h"
#include "neovim_controller.hpp"

void neovim_controller::close() {
    puts("Neovim did Exit!");
    
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context close];
    });
}

void neovim_controller::shutdown() {
    puts("Neovim did shutdown!");
    
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context shutdown];
    });
}
