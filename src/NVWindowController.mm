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

#include "neovim.hpp"

static inline MTLRenderPipelineDescriptor* defaultPipelineDescriptor() {
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    desc.vertexBuffers[0].mutability = MTLMutabilityImmutable;
    desc.fragmentBuffers[0].mutability = MTLMutabilityImmutable;
    return desc;
}

static inline MTLRenderPipelineDescriptor* blendedPipelineDescriptor() {
    MTLRenderPipelineDescriptor *desc = defaultPipelineDescriptor();
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    return desc;
}

NSError* NVRenderContext::init() {
    device = MTLCreateSystemDefaultDevice();
    id<MTLLibrary> lib = [device newDefaultLibrary];
    NSError *error = nil;
    
    MTLRenderPipelineDescriptor *gridDesc = defaultPipelineDescriptor();
    gridDesc.label = @"Grid background render pipeline";
    gridDesc.vertexFunction = [lib newFunctionWithName:@"grid_background"];
    gridDesc.fragmentFunction = [lib newFunctionWithName:@"fill_background"];
    gridRenderPipeline = [device newRenderPipelineStateWithDescriptor:gridDesc error:&error];
    
    if (error) {
        return error;
    }
    
    MTLRenderPipelineDescriptor *glyphDesc = blendedPipelineDescriptor();
    glyphDesc.label = @"Glyph render pipeline";
    glyphDesc.vertexFunction = [lib newFunctionWithName:@"glyph_render"];
    glyphDesc.fragmentFunction = [lib newFunctionWithName:@"glyph_fill"];
    glyphRenderPipeline = [device newRenderPipelineStateWithDescriptor:glyphDesc error:&error];
    
    if (error) {
        return error;
    }
    
    MTLRenderPipelineDescriptor *cursorDesc = defaultPipelineDescriptor();
    cursorDesc.label = @"Cursor background render pipeline";
    cursorDesc.vertexFunction = [lib newFunctionWithName:@"cursor_background"];
    cursorDesc.fragmentFunction = [lib newFunctionWithName:@"fill_background"];
    cursorRenderPipeline = [device newRenderPipelineStateWithDescriptor:cursorDesc error:&error];
    
    if (error) {
        return error;
    }
    
    MTLRenderPipelineDescriptor *lineDesc = blendedPipelineDescriptor();
    lineDesc.label = @"Line render pipeline";
    lineDesc.vertexFunction = [lib newFunctionWithName:@"line_render"];
    lineDesc.fragmentFunction = [lib newFunctionWithName:@"fill_line"];
    lineRenderPipeline = [device newRenderPipelineStateWithDescriptor:lineDesc error:&error];
    
    if (error) {
        return error;
    }
    
    rasterizer.set_canvas(256, 256, kCGImageAlphaOnly);
    texture_cache.create(device, MTLPixelFormatA8Unorm, 512, 512);
    return nil;
}

@implementation NVWindowController {
    NVRenderContext *renderContext;
    NVWindowController *windowIsOpen;
    NVWindowController *processIsAlive;
    NVGridView *gridView;
    ui::ui_state *ui_controller;
    neovim nvim;
}

- (instancetype)initWithRenderContext:(NVRenderContext *)renderContext {
    NSWindow *window = [[NSWindow alloc] init];
    
    [window setStyleMask:NSWindowStyleMaskTitled                |
                         NSWindowStyleMaskClosable              |
                         NSWindowStyleMaskMiniaturizable        |
                         NSWindowStyleMaskResizable];

    [window setDelegate:self];
    [window setTitle:@"window"];
    [window setTabbingMode:NSWindowTabbingModeDisallowed];
    
    self = [super initWithWindow:window];
    self->renderContext = renderContext;
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
            gridView = [[NVGridView alloc] initWithFrame:window.frame renderContext:renderContext];
            [window setContentView:gridView];
            
            font_family font = renderContext->font_manager.get("SF Mono", 15);
            [gridView setFont:font];
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
