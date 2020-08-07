//
//  Neovim Mac
//  NVRenderContext.h
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>

struct font_manager;
struct glyph_manager;

NS_ASSUME_NONNULL_BEGIN

/// @class NVRenderContext
/// @abstract Manages Metal device related state.
///
/// Render contexts manage Metal device (GPU) specific render state such as
/// pipelines, command queues, and textures. Do not create NVRenderContexts
/// directly, instead use a NVRenderContextManager.
@interface NVRenderContext : NSObject

/// The Metal device associated with this render context.
@property (nonatomic, readonly) id<MTLDevice> device;

/// The command queue associated with this render context.
/// Note: Do not create additional command queues. All command buffers should
/// be submitted through this queue to ensure synchronization.
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;

/// The background rendering pipeline.
/// See shaders.metal for more information.
@property (nonatomic, readonly) id<MTLRenderPipelineState> backgroundRenderPipeline;

/// The glyph rendering pipeline.
/// See shaders.metal for more information.
@property (nonatomic, readonly) id<MTLRenderPipelineState> glyphRenderPipeline;

/// The cursor rendering pipeline.
/// See shaders.metal for more information.
@property (nonatomic, readonly) id<MTLRenderPipelineState> cursorRenderPipeline;

/// The line (underlines, undercurls, strikethroughs) rendering pipeline.
/// See shaders.metal for more information.
@property (nonatomic, readonly) id<MTLRenderPipelineState> lineRenderPipeline;

/// The glyph manager for this render context.
/// Glyphs are cached in GPU memory (in Metal textures), this makes them
/// specific to Metal devices. As such, they are managed by a render context.
@property (nonatomic, readonly) struct glyph_manager* glyphManager;

/// The shared font manager.
@property (nonatomic, readonly) struct font_manager* fontManager;

@end

/// Controls the parameters of a NVRenderContexts and the objects it creates.
struct NVRenderContextOptions {
    /// The glyph_rasterizer height.
    size_t rasterizerHeight;

    /// The glyph_rasterizer width.
    size_t rasterizerWidth;

    /// The glyph_texture_cache page height.
    size_t cachePageHeight;

    /// The glyph_texture_cache page width.
    size_t cachePageWidth;

    /// The glyph_texture_cache initial capacity.
    size_t cacheInitialCapacity;

    /// The glyph_texture_cache growth factor.
    double cacheGrowthFactor;

    /// For a given glyph_texture_cache, when the number of allocated cache
    /// pages exceeds this threshold, the texture cache is evicted.
    size_t cacheEvictionThreshold;

    /// The number of cache pages to preserve when a texture cache is evicted.
    /// This number should be less than cacheEvictionThreshold.
    size_t cacheEvictionPreserve;
};

/// @protocol NVMetalDeviceDelegate
/// @abstract Receives updates on device initialization failures.
@protocol NVMetalDeviceDelegate<NSObject>

/// Called if no Metal devices are unavailible.
- (void)metalUnavailable;

/// Called when a newly inserted Metal device fails to initialize.
/// @param deviceName The name of the Metal device that failed to initialize.
- (void)metalDeviceFailedToInitialize:(NSString *)deviceName;

/// Called when Metal devices fail to initialize.
/// @param deviceNames      The names of the devices that failed to initialize.
/// @param hasAlternatives  Indicates if other Metal devices are available.
- (void)metalDevicesFailedToInitalize:(NSArray<NSString*> *)deviceNames
                      hasAlternatives:(BOOL)hasAlternatives;

@end

/// @class NVRenderContextManager
/// @abstract Creates and maintains render contexts for connected Metal devices.
@interface NVRenderContextManager : NSObject

/// Returns a NVRenderContextManager.
/// @param options  Render context options.
/// @param delegate Receives updates on device initialization failures.
- (instancetype)initWithOptions:(struct NVRenderContextOptions)options
                       delegate:(id<NVMetalDeviceDelegate>)delegate;

/// The font manager used by managed render contexts.
///
/// Font managers are not bound to specific GPUs. However, for maximum
/// efficiency when rasterizing glyphs, you should only use fonts obtained from
/// this font manager. This helps with the caching of fonts and glyphs.
/// Note: All render contexts created by this manager share a font manager.
@property (nonatomic, readonly) struct font_manager* fontManager;

/// Returns a default render context.
///
/// Uses the Metal device associated with the main display. Note: On systems
/// that support automatic graphics switching, calling this method will cause
/// the system to switch to the high power GPU. This is undesirable, so only use
/// this method as a last resort. Prefer renderContextForScreen.
- (NVRenderContext*)defaultRenderContext;

/// Returns a render context for the given Metal device.
/// @param device The metal device.
/// @returns A render context, or null if an error occurred.
- (nullable NVRenderContext*)renderContextForDevice:(id<MTLDevice>)device;

/// Returns the optimal render context for rendering to screen.
/// Uses the Metal device currently driving screen.
/// @param screen The screen that will be rendered to.
- (NVRenderContext*)renderContextForScreen:(NSScreen *)screen;

@end

NS_ASSUME_NONNULL_END
