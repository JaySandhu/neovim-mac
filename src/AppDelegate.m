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

@implementation AppDelegate {
    NVRenderContext *sharedRenderContext;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    rpc = os_log_create("io.github.jaysandhu.neovim-mac", "RPC");
    signal(SIGPIPE, SIG_IGN);
    
    NSError *error = nil;
    sharedRenderContext = [[NVRenderContext alloc] initWithError:&error];
    
    if (error) {
        abort();
        return;
    }
    
    NVWindowController *controller = [[NVWindowController alloc] initWithRenderContext:sharedRenderContext];
    [controller spawn];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
}

@end
