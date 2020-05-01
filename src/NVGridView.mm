//
//  Neovim Mac
//  NVGridView.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import "NVGridView.h"
#import "ShaderTypes.h"

#include <vector>
#include <unordered_map>
#include "glyph.hpp"
#include "ui.hpp"

struct cell_hasher {
    size_t operator()(const ui::cell &cell) const {
        return cell.hash;
    }
};

struct cell_equal {
    bool operator()(const ui::cell &left, const ui::cell &right) const {
        return memcmp(&left, &right, sizeof(ui::cell)) == 0;
    }
};

struct cached_glyph {
    simd_short2 texture_position;
    simd_short2 glyph_position;
    simd_short2 size;
};

class mtlbuffer {
private:
    id<MTLBuffer> buffer;
    char *ptr;
    size_t length;
    size_t capacity;
    size_t last_offset;
    std::atomic_flag in_use;
    
    static constexpr size_t align_up(size_t val, size_t alignment) {
        return (val + alignment - 1) & -alignment;
    }
    
    void expand(size_t new_capacity) {
        const size_t aligned = align_up(new_capacity, 8);
        
        id<MTLDevice> device = [buffer device];
        MTLResourceOptions options = [buffer resourceOptions];
        
        buffer = [device newBufferWithLength:aligned options:options];
        ptr = static_cast<char*>([buffer contents]);
        capacity = aligned;
    }

public:
    mtlbuffer() {
        buffer = nil;
        ptr = nullptr;
        length = 0;
        capacity = 0;
        last_offset = 0;
    }
    
    void clear() {
        length = 0;
        last_offset = 0;
    }
    
    void set_buffer(id<MTLBuffer> new_buffer) {
        buffer = new_buffer;
        ptr = static_cast<char*>([buffer contents]);
        length = 0;
        capacity = [buffer length];
    }
    
    void reserve(size_t size) {
        if (size > capacity) {
            expand(size);
        }
    }
    
    template<typename T>
    void push_back(const T &val) {
        const size_t new_length = length + sizeof(T);
            
        if (new_length > capacity) {
            expand(new_length * 2);
        }
    
        memcpy(ptr + length, &val, sizeof(T));
        length = new_length;
    }
    
    template<typename T>
    void push_back_unchecked(const T &val) {
        memcpy(ptr + length, &val, sizeof(T));
        length += sizeof(T);
        assert(length <= capacity);
    }
    
    id<MTLBuffer> get() const {
        return buffer;
    }
    
    size_t offset() {
        size_t ret = last_offset;
        length = align_up(length, 256);
        last_offset = length;
        return ret;
    }
    
    void update() {
        [buffer didModifyRange:NSMakeRange(0, length)];
    }
    
    bool aquire() {
        return in_use.test_and_set() == false;
    }
    
    void release() {
        in_use.clear();
    }
};

static id<MTLRenderPipelineState> createGridPipeline(id<MTLDevice> device, id<MTLLibrary> library) {
    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"grid_vertex"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"grid_fragment"];
    
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label = @"Grid Pipeline";
    desc.vertexFunction = vertexFunc;
    desc.fragmentFunction = fragmentFunc;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    desc.vertexBuffers[0].mutability = MTLMutabilityImmutable;
    desc.fragmentBuffers[0].mutability = MTLMutabilityImmutable;
    
    return [device newRenderPipelineStateWithDescriptor:desc error:nil];
}

static id<MTLRenderPipelineState> createGlyphPipeline(id<MTLDevice> device, id<MTLLibrary> library) {
    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"glyph_vertex"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"glyph_fragment"];
    
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label = @"Glyph Pipeline";
    desc.vertexFunction = vertexFunc;
    desc.fragmentFunction = fragmentFunc;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.vertexBuffers[0].mutability = MTLMutabilityImmutable;
    desc.fragmentBuffers[0].mutability = MTLMutabilityImmutable;
    
    return [device newRenderPipelineStateWithDescriptor:desc error:nil];
}

@implementation NVGridView {
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLRenderPipelineState> gridPipeline;
    id<MTLRenderPipelineState> glyphPipeline;
    mtlbuffer buffer;
    ui::grid *grid;
    glyph_rasterizer rasterizer;
    glyph_texture_cache texture_cache;
    std::unordered_map<ui::cell, cached_glyph, cell_hasher, cell_equal> glyph_cache;
    CAMetalLayer *metalLayer;
    simd_float2 cellSize;
    simd_float2 baselineTranslation;
}

- (id)initWithFrame:(NSRect)frame {
    device = MTLCreateSystemDefaultDevice();
    commandQueue = [device newCommandQueue];
    
    self = [super initWithFrame:frame];
    
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    self.layerContentsPlacement = NSViewLayerContentsPlacementTopLeft;
    
    id<MTLLibrary> lib = [device newDefaultLibrary];
    gridPipeline = createGridPipeline(device, lib);
    glyphPipeline = createGlyphPipeline(device, lib);
    
    rasterizer.set_font((CFStringRef)@"SF Mono Regular", 15);
    rasterizer.set_canvas(128, 128, kCGImageAlphaOnly);
    texture_cache.create(device, MTLPixelFormatA8Unorm, 512, 512);
    
    CTFontRef font = rasterizer.get_font();
    CGFloat leading = floor(CTFontGetLeading(font) + 0.5);
    CGFloat descent = floor(CTFontGetDescent(font) + 0.5);
    CGFloat ascent = floor(CTFontGetAscent(font) + 0.5);
    
    UniChar character = 'a';
    CGGlyph glyph;
    CGSize advance;
    bool val = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1);
    assert(val);

    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyph, &advance, 1);
    
    CGFloat cellHeight = leading + descent + ascent;
    CGFloat cellWidth = floor(advance.width + 0.5);
    
    cellSize.x = cellWidth;
    cellSize.y = cellHeight;
    
    baselineTranslation.x = 0;
    baselineTranslation.y = ascent;
    
    buffer.set_buffer([device newBufferWithLength:4194304
                                          options:MTLResourceStorageModeManaged |
                                                  MTLResourceCPUCacheModeWriteCombined]);
    
    return self;
}

- (CALayer*)makeBackingLayer {
    metalLayer = [CAMetalLayer layer];
    metalLayer.device = device;
    metalLayer.delegate = self;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    metalLayer.allowsNextDrawableTimeout = NO;
    metalLayer.autoresizingMask = kCALayerHeightSizable | kCALayerWidthSizable;
    metalLayer.needsDisplayOnBoundsChange = YES;
    metalLayer.presentsWithTransaction = YES;
    return metalLayer;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    metalLayer.drawableSize = [self convertSizeToBacking:newSize];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
}

- (void)setGrid:(ui::grid *)newGrid {
    grid = newGrid;
}

- (void)displayLayer:(CALayer*)layer {
    size_t grid_width = grid->width;
    size_t grid_height = grid->height;
    
    CGSize size = [metalLayer drawableSize];
    
    simd_float2 pixel_size = simd_float2{2.0, -2.0} / simd_float2{(float)size.width, (float)size.height};
    
    size_t max_buffer_size = grid->cells.size() * sizeof(uint32_t) * sizeof(glyph_data) + 1024;

    uniform_data data;
    data.pixel_size = pixel_size;
    data.cell_pixel_size = cellSize;
    data.cell_size = cellSize * pixel_size;
    data.baseline = baselineTranslation;
    data.grid_width = (uint32_t)grid_width;
    
    if (!buffer.aquire()) {
        puts("dropped frame!");
        [self setNeedsDisplay:YES];
        return;
    }
    
    buffer.clear();
    buffer.reserve(max_buffer_size);
    buffer.push_back_unchecked(data);
    buffer.offset();
    
    for (ui::cell &cell : grid->cells) {
        buffer.push_back_unchecked(cell.hl_attrs.background.value);
    }
    
    size_t grid_offset = buffer.offset();
    size_t glyph_count = 0;
    
    for (size_t row=0; row<grid_height; ++row) {
        ui::cell *cellrow = grid->get(row, 0);
        
        for (size_t col=0; col<grid_width; ++col) {
            ui::cell *cell = cellrow + col;
            
            if (cell->empty()) {
                continue;
            }
                                
            auto iter = glyph_cache.find(*cell);
            
            if (iter == glyph_cache.end()) {
                std::string_view text = cell->text_view();
                glyph_bitmap glyph = rasterizer.rasterize(text);
                auto texpoint = texture_cache.add(glyph);
                
                if (!texpoint) {
                    std::abort();
                }
                
                cached_glyph cached;
                cached.glyph_position.x = glyph.metrics.left_bearing;
                cached.glyph_position.y = -glyph.metrics.ascent;
                cached.texture_position.x = texpoint.x;
                cached.texture_position.y = texpoint.y;
                cached.size.x = glyph.metrics.width;
                cached.size.y = glyph.metrics.height;
                
                auto emplaced = glyph_cache.emplace(*cell, cached);
                iter = emplaced.first;
            }

            cached_glyph cached = iter->second;
            
            glyph_data gdata;
            gdata.grid_position = simd_short2{(int16_t)row, (int16_t)col};
            gdata.texture_position = cached.texture_position;
            gdata.glyph_position = cached.glyph_position;
            gdata.glyph_size = cached.size;
            gdata.color = cell->hl_attrs.foreground.value;
            buffer.push_back_unchecked(gdata);
            glyph_count += 1;
        }
    }
    
    size_t glyph_offset = buffer.offset();
    buffer.update();
    
    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    MTLRenderPassDescriptor *desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = drawable.texture;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionDontCare;
    
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:desc];
    
    [commandEncoder setRenderPipelineState:gridPipeline];
    [commandEncoder setVertexBuffer:buffer.get() offset:0 atIndex:0];
    [commandEncoder setVertexBuffer:buffer.get() offset:grid_offset atIndex:1];
    
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:0
                       vertexCount:4
                     instanceCount:grid->cells.size()];
    
    if (glyph_count) {
        [commandEncoder setRenderPipelineState:glyphPipeline];
        [commandEncoder setVertexBufferOffset:glyph_offset atIndex:1];
        [commandEncoder setFragmentTexture:texture_cache.texture atIndex:0];

        [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                           vertexStart:0
                           vertexCount:4
                         instanceCount:glyph_count];
    }
    
    [commandEncoder endEncoding];
    
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        self->buffer.release();
    }];
    
    [commandBuffer commit];
    [commandBuffer waitUntilScheduled];
    [drawable present];
}

@end
