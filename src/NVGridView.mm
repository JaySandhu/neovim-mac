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

@implementation NVGridView {
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLRenderPipelineState> pipeline;
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
    id<MTLFunction> vertexFunc = [lib newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunc = [lib newFunctionWithName:@"fragmentShader"];
    
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label = @"Pipeline";
    desc.vertexFunction = vertexFunc;
    desc.fragmentFunction = fragmentFunc;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    
    pipeline = [device newRenderPipelineStateWithDescriptor:desc error:nil];
    rasterizer.set_font((CFStringRef)@"SF Mono Regular", 16);
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
    cellSize.y = cellHeight + 6;
    
    baselineTranslation.x = 0;
    baselineTranslation.y = ascent + 3;
    return self;
}

- (CALayer*)makeBackingLayer {
    metalLayer = [CAMetalLayer layer];
    metalLayer.device = device;
    metalLayer.delegate = self;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
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
        
    std::vector<glyph_data> glyph_draw_data;
   
    CGSize size = [metalLayer drawableSize];
    
    simd_float2 pixel_size = simd_float2{2.0, -2.0} / simd_float2{(float)size.width, (float)size.height};
    
    uniform_data data;
    data.pixel = pixel_size;
    data.cell = cellSize * pixel_size;
    data.baseline = baselineTranslation * pixel_size;
    data.grid_width = (uint32_t)grid_width;
    
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
            gdata.size = cached.size;
            glyph_draw_data.push_back(gdata);
        }
    }
    
    size_t glyph_data_size = glyph_draw_data.size() * sizeof(glyph_data);
    
    id<MTLBuffer> buffer = [device newBufferWithBytes:glyph_draw_data.data()
                                               length:glyph_data_size
                                              options:0];

    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    MTLRenderPassDescriptor *desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = drawable.texture;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionDontCare;
    
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:desc];
    
    [commandEncoder setRenderPipelineState:pipeline];
    [commandEncoder setVertexBytes:&data length:sizeof(data) atIndex:0];
    [commandEncoder setVertexBuffer:buffer offset:0 atIndex:1];
    [commandEncoder setFragmentTexture:texture_cache.texture atIndex:0];

    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:0
                       vertexCount:4
                     instanceCount:glyph_draw_data.size()];
    
    [commandEncoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilScheduled];
    [drawable present];
}

@end
