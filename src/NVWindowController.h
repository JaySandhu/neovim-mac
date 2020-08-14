//
//  Neovim Mac
//  NVWindowController.h
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import "NVRenderContext.h"
#include "neovim.hpp"

NS_ASSUME_NONNULL_BEGIN

/// @class NVWindowController
/// @abstract A Neovim GUI window.
///
/// Acts as a controller object that coordinates between a Neovim process and a
/// NVGridView. User input is forwarded to the Neovim process. Grids obtained
/// from the process are rendered by a NVGridView.
///
/// Each NVWindowController object manages a connection to a remote Neovim
/// instance. Once a remote connection has been established, the window is
/// displayed. The controller is retained until the remote process exits and
/// its corresponding window is closed.
@interface NVWindowController : NSWindowController<NSWindowDelegate>

/// An array of NVWindowControllers corresponding to all the currently
/// connected Neovim instances.
+ (NSArray<NVWindowController*>*)windows;

/// Returns a NVWindowController initialized with the given context manager.
- (instancetype)initWithContextManager:(NVRenderContextManager *)contextManager;

/// A handle to the Neovim process.
- (nvim::process *)process;

/// Connect to a remote Neovim instance via a Unix domain socket.
/// If a connection is successfully established, the window is displayed.
/// @param addr Path to the Unix domain socket.
/// @returns Zero on success, otherwise an errno error code.
- (int)connect:(NSString *)addr;

/// Spawn a new Neovim child process.
/// If a child process is successfully created, the window is displayed.
- (int)spawn;

/// Spawn a new Neovim child process and open filename.
/// If a child process is successfully created, the window is displayed.
/// @param filename Path to the file to open.
/// @returns Zero on success, otherwise an errno error code.
- (int)spawnOpenFile:(NSString*)filename;

/// Spawn a new Neovim child process and open filenames.
/// If a child process is successfully created, the window is displayed.
/// Each file is opened in a separate tab.
/// @param filenames An array of file paths to be opened.
/// @returns Zero on success, otherwise an errno error code.
- (int)spawnOpenFiles:(NSArray<NSString*>*)filenames;

/// Spawn a new Neovim child process and open URLs.
/// If a child process is successfully created, the window is displayed.
/// Each URL is opened in a separate tab.
/// @param URLs An array of URLs to be opened.
/// @returns Zero on success, otherwise an errno error code.
- (int)spawnOpenURLs:(NSArray<NSURL*>*)URLs;

/// Quit the current Neovim process without asking for confirmation.
/// The window closes once the Neovim process has exited.
/// To quit with a confirmation prompt use -[NVWindowController close:].
- (void)forceQuit;

@end

NS_ASSUME_NONNULL_END
