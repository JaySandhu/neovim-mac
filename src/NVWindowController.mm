//
//  Neovim Mac
//  NVWindowController.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import "NVWindowController.h"
#import "NVGridView.h"

#include <unordered_map>
#include <simd/simd.h>
#include "neovim.hpp"
#include "font.hpp"
#include "ui.hpp"

@implementation NVWindowController {
    NVWindowController *windowIsOpen;
    NVWindowController *processIsAlive;
    NVGridView *gridView;
    ui::ui_state *ui_controller;
    neovim nvim;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] init];
    
    [window setStyleMask:NSWindowStyleMaskTitled                |
                         NSWindowStyleMaskClosable              |
                         NSWindowStyleMaskMiniaturizable        |
                         NSWindowStyleMaskResizable];

    [window setDelegate:self];
    [window setTitle:@"window"];
    [window setTabbingMode:NSWindowTabbingModeDisallowed];
    
    self = [super initWithWindow:window];
    nvim.set_controller(self);
    ui_controller = nvim.ui_state();
    
    return self;
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    windowIsOpen = self;
}

- (void)windowWillClose:(NSNotification *)notification {
    puts("Window closed!");
    windowIsOpen = nil;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    nvim.quit(true);
    return NO;
}

- (void)close {
    if (windowIsOpen) {
        [super close];
    }
}

- (void)shutdown {
    processIsAlive = nil;
}

- (void)redraw {
    ui::grid *grid = ui_controller->get_global_grid();
    
    if (!windowIsOpen) {
        [self showWindow:nil];
        
        if (!gridView) {
            NSWindow *window = [self window];
            gridView = [[NVGridView alloc] initWithFrame:window.frame];
            [window setContentView:gridView];
        }
    }
    
    [gridView setGrid:grid];
    [gridView setNeedsDisplay:YES];
}

- (void)connect:(NSString *)addr {
    int error = nvim.connect([addr UTF8String]);

    if (error) {
        printf("Connect error: %i: %s\n", error, strerror(error));
        return;
    }
    
    processIsAlive = self;
    nvim.ui_attach(80, 24);
}

- (void)dealloc {
    puts("NVWindowController dealloced!");
}

@end
