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

NS_ASSUME_NONNULL_BEGIN

@interface NVWindowController : NSWindowController<NSWindowDelegate>

+ (NSArray<NVWindowController*>*)windows;
+ (BOOL)modifiedBuffers;

- (instancetype)initWithContextManager:(NVRenderContextManager *)contextManager;

- (void)shutdown;
- (void)connect:(NSString *)addr;

- (void)spawn;
- (void)spawnOpenFiles:(NSArray<NSURL*>*)urls;

- (void)redraw;

- (void)titleDidChange;
- (void)fontDidChange;
- (void)optionsDidChange;

@end

NS_ASSUME_NONNULL_END
