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

struct font_manager;
struct glyph_manager;

NS_ASSUME_NONNULL_BEGIN

@interface NVRenderContext : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;

@property (nonatomic, readonly) id<MTLRenderPipelineState> gridRenderPipeline;
@property (nonatomic, readonly) id<MTLRenderPipelineState> glyphRenderPipeline;
@property (nonatomic, readonly) id<MTLRenderPipelineState> cursorRenderPipeline;
@property (nonatomic, readonly) id<MTLRenderPipelineState> lineRenderPipeline;

@property (nonatomic, readonly) struct font_manager* fontManager;
@property (nonatomic, readonly) struct glyph_manager* glyphManager;

- (instancetype)initWithError:(NSError **)error;

@end

@interface NVWindowController : NSWindowController<NSWindowDelegate>

+ (NSArray<NVWindowController*>*)windows;
+ (BOOL)modifiedBuffers;

- (instancetype)initWithRenderContext:(NVRenderContext *)renderState;

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
