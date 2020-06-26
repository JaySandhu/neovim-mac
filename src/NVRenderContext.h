//
//  NVRenderContext.h
//  Neovim
//
//  Created by Jay Sandhu on 6/22/20.
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

struct font_manager;
struct glyph_manager;

@class NVRenderContext;

struct NVRenderContextOptions {
    size_t rasterizerHeight;
    size_t rasterizerWidth;
    size_t texturePageHeight;
    size_t texturePageWidth;
};

@protocol NVMetalDeviceDelegate<NSObject>

- (void)metalUnavailable;

- (void)metalDeviceFailedToInitialize:(NSString *)deviceName;

- (void)metalDevicesFailedToInitalize:(NSArray<NSString*> *)deviceNames
                      hasAlternatives:(BOOL)hasAlternatives;

@end

@interface NVRenderContextManager : NSObject

- (instancetype)initWithOptions:(struct NVRenderContextOptions)options
                       delegate:(id<NVMetalDeviceDelegate>)delegate;

@property (nonatomic, readonly) struct font_manager* fontManager;

- (NVRenderContext*)defaultRenderContext;
- (NVRenderContext*)renderContextForScreen:(NSScreen *)screen;

@end

@interface NVRenderContext : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;

@property (nonatomic, readonly) id<MTLRenderPipelineState> gridRenderPipeline;
@property (nonatomic, readonly) id<MTLRenderPipelineState> glyphRenderPipeline;
@property (nonatomic, readonly) id<MTLRenderPipelineState> cursorRenderPipeline;
@property (nonatomic, readonly) id<MTLRenderPipelineState> lineRenderPipeline;

@property (nonatomic, readonly) struct font_manager* fontManager;
@property (nonatomic, readonly) struct glyph_manager* glyphManager;

@end

NS_ASSUME_NONNULL_END
