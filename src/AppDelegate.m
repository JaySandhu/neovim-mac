//
//  Neovim Mac
//  AppDelegate.m
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import "AppDelegate.h"
#import "NVRenderContext.h"
#import "NVWindowController.h"
#import "log.h"

os_log_t rpc;

@interface AppDelegate() <NVMetalDeviceDelegate>
@end

@implementation AppDelegate {
    NVRenderContextManager *contextManager;
}

- (void)metalUnavailable {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = @"This Mac does not support Metal";
    alert.informativeText = @"No Metal capable devices were found. "
                             "Neovim-Mac requires a Metal capable device.";

    [alert addButtonWithTitle:@"Quit"];
    [alert runModal];
    exit(1);
}

- (void)metalDeviceFailedToInitialize:(NSString *)deviceName {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Failed to initialize Metal device";

    alert.informativeText = [NSString stringWithFormat:
        @"Failed to initialize device: %@. "
        @"This may cause degraded performance in some circumstances.", deviceName];

    [alert runModal];
}

- (void)metalDevicesFailedToInitalize:(NSArray<NSString *> *)deviceNames
                      hasAlternatives:(BOOL)hasAlternatives {
    NSString *nameList = [deviceNames componentsJoinedByString:@", "];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Failed to initialize Metal device(s)";

    if (hasAlternatives) {
        alert.informativeText = [NSString stringWithFormat:
            @"Failed to initialize device(s): %@. "
            @"This may cause degraded performance in some circumstances.", nameList];

        [alert runModal];
    } else {
        alert.informativeText = [NSString stringWithFormat:
            @"Failed to initialize device(s): %@.\n"
            @"No Metal capable device is available.", nameList];

        [alert addButtonWithTitle:@"Quit"];
        [alert runModal];
        exit(1);
    }
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"NSDisabledDictationMenuItem"];
    [defaults setBool:YES forKey:@"NSDisabledCharacterPaletteMenuItem"];

    signal(SIGPIPE, SIG_IGN);
    rpc = os_log_create("io.github.jaysandhu.neovim-mac", "RPC");
    
    struct NVRenderContextOptions options;
    options.rasterizerWidth = 512;
    options.rasterizerHeight = 512;
    options.texturePageWidth = 1024;
    options.texturePageHeight = 1024;

    contextManager = [[NVRenderContextManager alloc] initWithOptions:options delegate:self];
}

- (BOOL)applicationOpenUntitledFile:(NSApplication *)sender {
    NVWindowController *controller = [[NVWindowController alloc] initWithContextManager:contextManager];

    if ([controller spawn]) {
        return NO;
    }

    return YES;
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    NVWindowController *controller = [[NVWindowController alloc] initWithContextManager:contextManager];

    if ([controller spawnOpenFile:filename]) {
        return NO;
    }

    return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    NVWindowController *controller = [[NVWindowController alloc] initWithContextManager:contextManager];
    [controller spawnOpenFiles:filenames];
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
    [[[NVWindowController alloc] initWithContextManager:contextManager] spawn];
}

- (IBAction)newTab:(id)sender {
    [[[NVWindowController alloc] initWithContextManager:contextManager] spawn];
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
    
    NVWindowController *controller = [[NVWindowController alloc] initWithContextManager:contextManager];
    [controller spawnOpenURLs:[panel URLs]];
}

@end
