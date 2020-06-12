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

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"NSDisabledDictationMenuItem"];
    [defaults setBool:YES forKey:@"NSDisabledCharacterPaletteMenuItem"];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    signal(SIGPIPE, SIG_IGN);
    
    rpc = os_log_create("io.github.jaysandhu.neovim-mac", "RPC");
    
    NSError *error = nil;
    sharedRenderContext = [[NVRenderContext alloc] initWithError:&error];
    
    if (error) {
        abort();
        return;
    }
    
    NVWindowController *controller = [[NVWindowController alloc] initWithRenderContext:sharedRenderContext];
    [controller connect:@"/users/jay/pipe"];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (![NVWindowController modifiedBuffers]) {
        return NSTerminateNow;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Quit without saving?";
    alert.informativeText = @"There are modified buffers, if you quit now "
                             "all changes will be lost. Quit anyway?";
     
    [alert addButtonWithTitle:@"Quit"];
    [alert addButtonWithTitle:@"Cancel"];
    
    NSModalResponse response = [alert runModal];
    
    if (response == NSAlertFirstButtonReturn) {
        return NSTerminateNow;
    } else {
        return NSTerminateCancel;
    }
}

- (IBAction)closeAllWindows:(id)sender {
    for (NSWindow *window in [[NSApplication sharedApplication] windows]) {
        [[window windowController] close];
    }
}

- (IBAction)newDocument:(id)sender {
    [[[NVWindowController alloc] initWithRenderContext:sharedRenderContext] spawn];
}

- (IBAction)newTab:(id)sender {
    [[[NVWindowController alloc] initWithRenderContext:sharedRenderContext] spawn];
}

- (void)openDocument:(id)sender {
    NSOpenPanel *panel = [[NSOpenPanel alloc] init];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    
    NSModalResponse response = [panel runModal];
    
    if (response != NSModalResponseOK) {
        return;
    }
    
    NVWindowController *controller = [[NVWindowController alloc] initWithRenderContext:sharedRenderContext];
    [controller spawnOpenFiles:[panel URLs]];
}

@end
