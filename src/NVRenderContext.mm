//
//  NVRenderContext.m
//  Neovim
//
//  Created by Jay Sandhu on 6/22/20.
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//

#import "NVRenderContext.h"
#include "font.hpp"

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
    glyph_manager glyphManager;
}

- (instancetype)initWithOptions:(NVRenderContextOptions *)options
                    metalDevice:(id<MTLDevice>)device
                    fontManager:(font_manager *)fontManager
                glyphRasterizer:(glyph_rasterizer *)rasterizer
                          error:(NSError **)error {
    self = [super init];

    _device = device;
    _commandQueue = [_device newCommandQueue];
    _fontManager = fontManager;

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

    glyphManager.rasterizer = rasterizer;
    glyphManager.texture_cache = glyph_texture_cache(_commandQueue,
                                                     options->texturePageWidth,
                                                     options->texturePageHeight);

    return self;
}

- (glyph_manager*)glyphManager {
    return &glyphManager;
}

@end

@implementation NVRenderContextManager {
    __weak id<NVMetalDeviceDelegate> deviceDelegate;
    NSMutableArray<NVRenderContext*> *renderContexts;
    id<NSObject> deviceObserver;
    NVRenderContextOptions contextOptions;
    font_manager fontManager;
    glyph_rasterizer rasterizer;
}

- (instancetype)initWithOptions:(NVRenderContextOptions)options
                       delegate:(id<NVMetalDeviceDelegate>)delegate {
    self = [super init];
    deviceDelegate = delegate;

    id<NSObject> observer = nil;

    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevicesWithObserver(&observer,
    ^(id<MTLDevice> device, MTLDeviceNotificationName name) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self metalNotificationForDevice:device name:name];
        });
    });

    if (!devices || ![devices count]) {
        [delegate metalUnavailable];
        return self;
    }

    NSMutableArray<NSString *> *uninitializedDevices = [NSMutableArray arrayWithCapacity:16];
    renderContexts = [NSMutableArray arrayWithCapacity:16];
    rasterizer = glyph_rasterizer(options.rasterizerWidth, options.rasterizerHeight);
    contextOptions = options;
    deviceObserver = observer;

    for (id<MTLDevice> device in devices) {
        NSError *error = nil;

        NVRenderContext *context = [[NVRenderContext alloc] initWithOptions:&contextOptions
                                                                metalDevice:device
                                                                fontManager:&fontManager
                                                            glyphRasterizer:&rasterizer
                                                                      error:&error];

        if (!error) {
            [renderContexts addObject:context];
        } else {
            [uninitializedDevices addObject:[device name]];
        }
    }

    if ([uninitializedDevices count]) {
        [delegate metalDevicesFailedToInitalize:uninitializedDevices
                                hasAlternatives:[renderContexts count] != 0];
    }

    return self;
}

- (void)dealloc {
    MTLRemoveDeviceObserver(deviceObserver);
}

- (NVRenderContext*)addMetalDevice:(id<MTLDevice>)device {
    NSError *error = nil;
    NVRenderContext *context = [[NVRenderContext alloc] initWithOptions:&contextOptions
                                                            metalDevice:device
                                                            fontManager:&fontManager
                                                        glyphRasterizer:&rasterizer
                                                                  error:&error];

    if (!error) {
        [renderContexts addObject:context];
        return context;
    } else {
        [deviceDelegate metalDeviceFailedToInitialize:[device name]];
        return nil;
    }
}

static inline long contextIndexForDevice(NSArray<NVRenderContext*> *contexts,
                                         id<MTLDevice> device) {
    long index = 0;

    for (NVRenderContext *context in contexts) {
        if (context.device == device) {
            return index;
        }

        index += 1;
    }

    return -1;
}

- (void)removeMetalDevice:(id<MTLDevice>)device {
    long contextIndex = contextIndexForDevice(renderContexts, device);

    if (contextIndex != -1) {
        [renderContexts removeObjectAtIndex:contextIndex];

        if (![renderContexts count]) {
            [deviceDelegate metalUnavailable];
        }
    }
}

static inline NVRenderContext* contextForDevice(NSArray<NVRenderContext*> *contexts,
                                                id<MTLDevice> device) {
    for (NVRenderContext *context in contexts) {
        if (context.device == device) {
            return context;
        }
    }

    return nil;
}

- (void)metalNotificationForDevice:(id<MTLDevice>)device name:(MTLDeviceNotificationName)name {
    if ([name isEqualToString:MTLDeviceWasAddedNotification] &&
        !contextForDevice(renderContexts, device)) {
        [self addMetalDevice:device];
    } else if ([name isEqualToString:MTLDeviceRemovalRequestedNotification] ||
               [name isEqualToString:MTLDeviceWasRemovedNotification]) {
        [self removeMetalDevice:device];
    }
}

- (NVRenderContext *)renderContextForScreen:(NSScreen *)screen {
    NSNumber *screenNumber = [[screen deviceDescription] objectForKey:@"NSScreenNumber"];
    CGDirectDisplayID displayID  = [screenNumber unsignedIntValue];
    id<MTLDevice> device = CGDirectDisplayCopyCurrentMetalDevice(displayID);

    NVRenderContext *renderContext = contextForDevice(renderContexts, device);

    if (renderContext) {
        return renderContext;
    }

    renderContext = [self addMetalDevice:device];

    if (renderContext) {
        return renderContext;
    }

    device = MTLCreateSystemDefaultDevice();
    renderContext = contextForDevice(renderContexts, device);

    if (renderContext) {
        return renderContext;
    }

    if ([renderContexts count]) {
        return renderContexts[0];
    } else {
        [deviceDelegate metalUnavailable];
        std::abort();
    }
}

- (NVRenderContext*)defaultRenderContext {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NVRenderContext *renderContext = contextForDevice(renderContexts, device);

    if (renderContext) {
        return renderContext;
    } else if ([renderContexts count]) {
        return renderContexts[0];
    } else {
        [deviceDelegate metalUnavailable];
        std::abort();
    }
}

- (font_manager*)fontManager {
    return &fontManager;
}

@end
