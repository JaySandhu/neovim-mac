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

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    signal(SIGPIPE, SIG_IGN);
    
    NVWindowController *controller = [[NVWindowController alloc] init];
    [controller connect:@"/users/jay/pipe"];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
}

@end
