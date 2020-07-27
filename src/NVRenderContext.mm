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

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   fontManager:(font_manager *)fontManager
                contextOptions:(NVRenderContextOptions *)options
               glyphRasterizer:(glyph_rasterizer *)rasterizer
                         error:(NSError **)error {
    self = [super init];
    _device = device;
    _commandQueue = [device newCommandQueue];
    _fontManager = fontManager;

    id<MTLLibrary> lib = [device newDefaultLibrary];

    MTLRenderPipelineDescriptor *backgroundDesc = defaultPipelineDescriptor();
    backgroundDesc.label = @"Grid background render pipeline";
    backgroundDesc.vertexFunction = [lib newFunctionWithName:@"background_render"];
    backgroundDesc.fragmentFunction = [lib newFunctionWithName:@"background_fill"];
    _backgroundRenderPipeline = [device newRenderPipelineStateWithDescriptor:backgroundDesc error:error];

    if (*error) return self;

    MTLRenderPipelineDescriptor *glyphDesc = defaultPipelineDescriptor();
    glyphDesc.label = @"Glyph render pipeline";
    glyphDesc.vertexFunction = [lib newFunctionWithName:@"glyph_render"];
    glyphDesc.fragmentFunction = [lib newFunctionWithName:@"glyph_fill"];
    _glyphRenderPipeline = [device newRenderPipelineStateWithDescriptor:glyphDesc error:error];

    if (*error) return self;

    MTLRenderPipelineDescriptor *cursorDesc = defaultPipelineDescriptor();
    cursorDesc.label = @"Cursor render pipeline";
    cursorDesc.vertexFunction = [lib newFunctionWithName:@"cursor_render"];
    cursorDesc.fragmentFunction = [lib newFunctionWithName:@"background_fill"];
    _cursorRenderPipeline = [device newRenderPipelineStateWithDescriptor:cursorDesc error:error];

    if (*error) return self;

    MTLRenderPipelineDescriptor *lineDesc = blendedPipelineDescriptor();
    lineDesc.label = @"Line render pipeline";
    lineDesc.vertexFunction = [lib newFunctionWithName:@"line_render"];
    lineDesc.fragmentFunction = [lib newFunctionWithName:@"line_fill"];
    _lineRenderPipeline = [device newRenderPipelineStateWithDescriptor:lineDesc error:error];

    if (*error) return self;

    glyphManager = glyph_manager(rasterizer,
                                 _commandQueue,
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
        NVRenderContext *context = [[NVRenderContext alloc] initWithDevice:device
                                                               fontManager:&fontManager
                                                            contextOptions:&contextOptions
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
    NVRenderContext *context = [[NVRenderContext alloc] initWithDevice:device
                                                           fontManager:&fontManager
                                                        contextOptions:&contextOptions
                                                       glyphRasterizer:&rasterizer
                                                                 error:&error];

    if (error) {
        [deviceDelegate metalDeviceFailedToInitialize:[device name]];
        return nil;
    }

    [renderContexts addObject:context];
    return context;
}

- (void)removeMetalDevice:(id<MTLDevice>)device {
    NSInteger contextIndex = [renderContexts indexOfObjectIdenticalTo:device];

    if (contextIndex != NSNotFound) {
        [renderContexts removeObjectAtIndex:contextIndex];

        if (![renderContexts count]) {
            [deviceDelegate metalUnavailable];
        }
    }
}

- (nullable NVRenderContext*)renderContextForDevice:(id<MTLDevice>)device {
    for (NVRenderContext *context in renderContexts) {
        if (context.device == device) {
            return context;
        }
    }

    // We don't have a render context for this device. Make one now.
    // This can happen if:
    //   1. We get called before we have a chance to handle a MTLDeviceWasAddedNotification.
    //   2. We failed to create a render context for this device the last time we tried.
    return [self addMetalDevice:device];
}

- (void)metalNotificationForDevice:(id<MTLDevice>)device name:(MTLDeviceNotificationName)name {
    if ([name isEqualToString:MTLDeviceWasAddedNotification]) {
        return (void)[self renderContextForDevice:device];
    }

    if ([name isEqualToString:MTLDeviceRemovalRequestedNotification] ||
        [name isEqualToString:MTLDeviceWasRemovedNotification]) {
        return [self removeMetalDevice:device];
    }
}

- (NVRenderContext *)renderContextForScreen:(NSScreen *)screen {
    NSNumber *screenNumber = [[screen deviceDescription] objectForKey:@"NSScreenNumber"];
    CGDirectDisplayID displayID  = [screenNumber unsignedIntValue];
    id<MTLDevice> device = CGDirectDisplayCopyCurrentMetalDevice(displayID);

    NVRenderContext *renderContext = [self renderContextForDevice:device];

    if (renderContext) {
        return renderContext;
    }

    // We're running out of options. One last hail mary.
    return [self defaultRenderContext];
}

- (NVRenderContext*)defaultRenderContext {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NVRenderContext *renderContext = [self renderContextForDevice:device];

    if (renderContext) {
        return renderContext;
    }

    // We're desperate, return anything we have.
    if ([renderContexts count]) {
        return renderContexts[0];
    }

    [deviceDelegate metalUnavailable];
    std::abort();
}

- (font_manager *)fontManager {
    return &fontManager;
}

@end
