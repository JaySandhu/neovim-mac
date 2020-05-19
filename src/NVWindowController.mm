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

@implementation NVRenderContext {
    font_manager font_manager;
    glyph_manager glyph_manager;
}

- (instancetype)initWithError:(NSError **)error {
    *error = nil;

    self = [super init];
    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];

    id<MTLLibrary> lib = [_device newDefaultLibrary];

    MTLRenderPipelineDescriptor *gridDesc = defaultPipelineDescriptor();
    gridDesc.label = @"Grid background render pipeline";
    gridDesc.vertexFunction = [lib newFunctionWithName:@"grid_background"];
    gridDesc.fragmentFunction = [lib newFunctionWithName:@"fill_background"];
    _gridRenderPipeline = [_device newRenderPipelineStateWithDescriptor:gridDesc error:error];

    if (*error) return self;

    MTLRenderPipelineDescriptor *glyphDesc = defaultPipelineDescriptor();
    glyphDesc.label = @"Glyph render pipeline";
    glyphDesc.vertexFunction = [lib newFunctionWithName:@"glyph_render"];
    glyphDesc.fragmentFunction = [lib newFunctionWithName:@"glyph_fill"];
    _glyphRenderPipeline = [_device newRenderPipelineStateWithDescriptor:glyphDesc error:error];

    if (*error) return self;

    MTLRenderPipelineDescriptor *cursorDesc = defaultPipelineDescriptor();
    cursorDesc.label = @"Cursor render pipeline";
    cursorDesc.vertexFunction = [lib newFunctionWithName:@"cursor_render"];
    cursorDesc.fragmentFunction = [lib newFunctionWithName:@"fill_background"];
    _cursorRenderPipeline = [_device newRenderPipelineStateWithDescriptor:cursorDesc error:error];

    if (*error) return self;

    MTLRenderPipelineDescriptor *lineDesc = blendedPipelineDescriptor();
    lineDesc.label = @"Line render pipeline";
    lineDesc.vertexFunction = [lib newFunctionWithName:@"line_render"];
    lineDesc.fragmentFunction = [lib newFunctionWithName:@"fill_line"];
    _lineRenderPipeline = [_device newRenderPipelineStateWithDescriptor:lineDesc error:error];

    if (*error) return self;

    glyph_manager.rasterizer = glyph_rasterizer(256, 256);
    glyph_manager.texture_cache = glyph_texture_cache(_commandQueue, 512, 512);

    return self;
}

- (glyph_manager*)glyphManager {
    return &glyph_manager;
}

- (font_manager*)fontManager {
    return &font_manager;
}

@end

@implementation NVWindowController {
    NVRenderContext *renderContext;
    NVWindowController *windowIsOpen;
    NVWindowController *processIsAlive;
    NVGridView *gridView;
    font_manager *font_manager;
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
    [window setWindowController:self];

    self = [super initWithWindow:window];
    self->renderContext = renderContext;
    self->font_manager = renderContext.fontManager;

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
            
            gridView = [[NVGridView alloc] initWithFrame:window.frame
                                           renderContext:renderContext
                                            neovimHandle:&nvim];
            
            [window setContentView:gridView];
            [window makeFirstResponder:gridView];
            
            [gridView setFont:font_manager->get("SF Mono", 15)];
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
