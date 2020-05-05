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
    
    mtlbuffer(id<MTLDevice> device, size_t init_capacity) {
        buffer = [device newBufferWithLength:init_capacity
                                     options:MTLResourceStorageModeManaged |
                                             MTLResourceCPUCacheModeWriteCombined];
        
        ptr = static_cast<char*>([buffer contents]);
        length = 0;
        capacity = init_capacity;
        last_offset = 0;
    }
    
    mtlbuffer(const mtlbuffer &&other) {
        buffer = other.buffer;
        ptr = other.ptr;
        length = other.length;
        capacity = other.capacity;
        last_offset = other.last_offset;
    }
    
    mtlbuffer& operator=(const mtlbuffer &&other) {
        buffer = other.buffer;
        ptr = other.ptr;
        length = other.length;
        capacity = other.capacity;
        last_offset = other.last_offset;
        return *this;
    }
    
    void clear() {
        length = 0;
        last_offset = 0;
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
    
    template<typename T, typename ...Args>
    T& emplace_back_unchecked(Args &&...args) {
        T *ret = new (ptr + length) T(std::forward<Args>(args)...);
        length += sizeof(T);
        assert(length <= capacity);
        return *ret;
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

@implementation NVGridView {
    NVRenderContext *renderContext;
    id<MTLCommandQueue> commandQueue;
    CAMetalLayer *metalLayer;
    mtlbuffer buffer;
    ui::grid *grid;
    font_family font;
    simd_float2 cellSize;
    simd_float2 baselineTranslation;
    int32_t lineThickness;
    int32_t underlineTranslate;
    int32_t strikethroughTranslate;
}

- (id)initWithFrame:(NSRect)frame renderContext:(NVRenderContext *)renderContext {
    self = [super initWithFrame:frame];
    
    self->renderContext = renderContext;
    self->commandQueue = [renderContext->device newCommandQueue];
    
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    self.layerContentsPlacement = NSViewLayerContentsPlacementTopLeft;
    
    buffer = mtlbuffer(renderContext->device, 4194304);
    return self;
}

- (CALayer*)makeBackingLayer {
    metalLayer = [CAMetalLayer layer];
    metalLayer.device = renderContext->device;
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

- (void)setFont:(font_family)font {
    self->font = font;
    
    CGFloat leading = floor(font.leading() + 0.5);
    CGFloat descent = floor(font.descent() + 0.5);
    CGFloat ascent = floor(font.ascent() + 0.5);

    CGFloat cellHeight = leading + descent + ascent;
    CGFloat cellWidth = floor(font.width() + 0.5);

    cellSize.x = cellWidth;
    cellSize.y = cellHeight;

    baselineTranslation.x = 0;
    baselineTranslation.y = ascent;
    
    CGFloat underlinePos = font.underline_position();
    
    if (underlinePos >= 0) {
        underlineTranslate = floor(underlinePos + 0.5);
    } else {
        underlineTranslate = floor(underlinePos - 0.5);
    }
    
    lineThickness = floor(font.underline_thickness() + 0.5);
}

- (void)displayLayer:(CALayer*)layer {
    size_t grid_width = grid->width;
    size_t grid_height = grid->height;
    
    CGSize size = [metalLayer drawableSize];
    
    if (!buffer.aquire()) {
        [self setNeedsDisplay:YES];
        return;
    }
    
    simd_float2 pixel_size = simd_float2{2.0, -2.0} / simd_float2{(float)size.width, (float)size.height};
    
    size_t max_buffer_size = grid->cells.size() * sizeof(uint32_t) * sizeof(glyph_data) + 1024;
    buffer.clear();
    buffer.reserve(max_buffer_size);
    
    uniform_data data;
    data.pixel_size = pixel_size;
    data.cell_pixel_size = cellSize;
    data.cell_size = cellSize * pixel_size;
    data.baseline = baselineTranslation;
    data.grid_width = (uint32_t)grid_width;
    data.cursor_position.x = grid->cursor.col;
    data.cursor_position.y = grid->cursor.row;
    data.cursor_color = grid->cursor.attrs.background.value;
    
    buffer.push_back(data);
    buffer.offset();
    
    for (ui::cell &cell : grid->cells) {
        buffer.push_back_unchecked(cell.hl_attrs.background.value);
    }
    
    size_t grid_offset = buffer.offset();
    size_t glyph_count = 0;
    glyph_cache_map &glyph_cache = renderContext->glyph_cache;
    
    for (size_t row=0; row<grid_height; ++row) {
        ui::cell *cellrow = grid->get(row, 0);
        
        for (size_t col=0; col<grid_width; ++col) {
            ui::cell *cell = cellrow + col;
            
            if (cell->empty()) {
                continue;
            }
                               
            glyph_key key(font.regular(), *cell);
            auto iter = glyph_cache.find(key);
            
            if (iter == glyph_cache.end()) {
                std::string_view text = cell->text_view();
                glyph_bitmap glyph = renderContext->rasterizer.rasterize(font.regular(), text);
                auto texpoint = renderContext->texture_cache.add(glyph);
                
                if (!texpoint) {
                    std::abort();
                }
                
                glyph_cached cached;
                cached.glyph_position.x = glyph.metrics.left_bearing;
                cached.glyph_position.y = -glyph.metrics.ascent;
                cached.texture_position.x = texpoint.x;
                cached.texture_position.y = texpoint.y;
                cached.size.x = glyph.metrics.width;
                cached.size.y = glyph.metrics.height;
                
                auto emplaced = glyph_cache.emplace(key, cached);
                iter = emplaced.first;
            }

            glyph_cached cached = iter->second;
            
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
    
    ui::cell *cursor_cell = grid->get(grid->cursor.row, grid->cursor.col);
    
    if (!cursor_cell->empty()) {
        glyph_key key(font.regular(), *cursor_cell);
        auto iter = glyph_cache.find(key);
        glyph_cached cached = iter->second;

        glyph_data gdata;
        gdata.grid_position = simd_short2{(int16_t)grid->cursor.row, (int16_t)grid->cursor.col};
        gdata.texture_position = cached.texture_position;
        gdata.glyph_position = cached.glyph_position;
        gdata.glyph_size = cached.size;
        gdata.color = grid->cursor.attrs.foreground.value;
        buffer.push_back_unchecked(gdata);
    }
    
    size_t glyph_offset = buffer.offset();
    
    for (int i=0; i<10; ++i) {
        line_data line;
        line.grid_position = simd_short2{0, (short)(5 + i)};
        line.ytranslate = baselineTranslation.y;
        line.thickness = 2;
        line.period = 2;
        buffer.push_back(line);
    }
    
    size_t line_offset = buffer.offset();
    
    buffer.update();
    
    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    MTLRenderPassDescriptor *desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = drawable.texture;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionDontCare;
    
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:desc];
    
    [commandEncoder setRenderPipelineState:renderContext->gridRenderPipeline];
    [commandEncoder setVertexBuffer:buffer.get() offset:0 atIndex:0];
    [commandEncoder setVertexBuffer:buffer.get() offset:grid_offset atIndex:1];

    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:0
                       vertexCount:4
                     instanceCount:grid->cells.size()];

    if (glyph_count) {
        [commandEncoder setRenderPipelineState:renderContext->glyphRenderPipeline];
        [commandEncoder setVertexBufferOffset:glyph_offset atIndex:1];
        [commandEncoder setFragmentTexture:renderContext->texture_cache.texture atIndex:0];

        [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                           vertexStart:0
                           vertexCount:4
                         instanceCount:glyph_count];
    }
    
    [commandEncoder setRenderPipelineState:renderContext->lineRenderPipeline];
    [commandEncoder setVertexBufferOffset:line_offset atIndex:1];

    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:0
                       vertexCount:4
                     instanceCount:10];

    simd_float2 position{(float)grid->cursor.col, (float)grid->cursor.row};
    simd_float2 origin = cellSize * position;

    MTLScissorRect scissor;
    scissor.x = origin.x;
    scissor.y = origin.y;
    scissor.width = cellSize.x;
    scissor.height = cellSize.y;

    if (scissor.x + scissor.width > size.width) {
        scissor.x = 0;
        scissor.width = size.width;
    }

    if (scissor.y + scissor.height > size.height) {
        scissor.y = 0;
        scissor.height = size.height;
    }

    [commandEncoder setScissorRect:scissor];
    
    [commandEncoder setRenderPipelineState:renderContext->cursorRenderPipeline];
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:0
                       vertexCount:4];
    
    if (!cursor_cell->empty()) {
        [commandEncoder setRenderPipelineState:renderContext->glyphRenderPipeline];
        [commandEncoder setVertexBufferOffset:glyph_offset atIndex:1];
        [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                           vertexStart:0
                           vertexCount:4
                         instanceCount:1
                          baseInstance:glyph_count];
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
