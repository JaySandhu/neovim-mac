//
//  Neovim Mac
//  AppDelegate.m
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import "AppDelegate.h"
#import "NVWindowController.h"
#import "log.h"

os_log_t rpc;

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    rpc = os_log_create("io.github.jaysandhu.neovim-mac", "RPC");
    signal(SIGPIPE, SIG_IGN);
    
    NVWindowController *controller = [[NVWindowController alloc] init];
    [controller connect:@"/users/jay/pipe"];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
}

@end
