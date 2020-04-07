//
//  Neovim Mac
//  NVWindowController.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import "NVWindowController.h"
#include "neovim.hpp"

@implementation NVWindowController {
    NVWindowController *windowIsOpen;
    NVWindowController *processIsAlive;
    neovim nvim;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] init];
    [window setStyleMask:NSWindowStyleMaskTitled                |
                         NSWindowStyleMaskClosable              |
                         NSWindowStyleMaskMiniaturizable        |
                         NSWindowStyleMaskResizable             |
                         NSWindowStyleMaskFullSizeContentView];

    [window setDelegate:self];
    [window setTitle:@"window"];
    [window setTabbingMode:NSWindowTabbingModeDisallowed];

    self = [super initWithWindow:window];
    nvim.set_controller(self);
    
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

- (void)connect:(NSString *)addr {
    int error = nvim.connect([addr UTF8String]);

    if (error) {
        printf("Connect error: %i: %s\n", error, strerror(error));
        return;
    }
    
    processIsAlive = self;
    nvim.ui_attach(80, 24);
    [self showWindow:nil];
}

- (void)dealloc {
    puts("NVWindowController dealloced!");
}

@end
