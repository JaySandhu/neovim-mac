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
#include "font.hpp"

NS_ASSUME_NONNULL_BEGIN

struct NVRenderContext {
    id<MTLDevice> device;
    id<MTLRenderPipelineState> gridRenderPipeline;
    id<MTLRenderPipelineState> glyphRenderPipeline;
    id<MTLRenderPipelineState> cursorRenderPipeline;
    id<MTLRenderPipelineState> lineRenderPipeline;
    glyph_rasterizer rasterizer;
    glyph_texture_cache texture_cache;
    font_manager font_manager;
    
    NSError* init();
};

@interface NVWindowController : NSWindowController<NSWindowDelegate>

- (instancetype)initWithRenderContext:(NVRenderContext *)renderState;

- (void)shutdown;
- (void)connect:(NSString *)addr;
- (void)redraw;

@end

NS_ASSUME_NONNULL_END
