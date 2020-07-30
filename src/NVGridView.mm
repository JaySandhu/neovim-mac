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
#include "shader_types.hpp"

/// Utility class to help manage Metal buffers.
/// The class provides two additional abstractions over a MTLBuffer:
///   1. A low overhead locking mechanism.
///   2. A means to coalesce multiple allocations into a single MTLBuffer.
class mtlbuffer {
private:
    id<MTLDevice> buffer_device;
    id<MTLBuffer> buffer;
    char *ptr;
    size_t length;
    size_t capacity;
    std::atomic_flag in_use;

    static constexpr size_t align_up(size_t val, size_t alignment) {
        return (val + alignment - 1) & -alignment;
    }

public:
    /// A region of the underlying MTLBuffer's memory.
    struct region {
        void *ptr;      ///< Pointer to the start of the region.
        size_t offset;  ///< The regions offset in the underlying MTLBuffer.
    };

    /// Constructs an empty mtlbuffer.
    mtlbuffer() {
        buffer_device = nil;
        buffer = nil;
        ptr = nullptr;
        length = 0;
        capacity = 0;
    }

    /// Creates the underlying MTLBuffer.
    ///
    /// @param device   The new buffers device.
    /// @param size     The size of the buffer in bytes.
    ///
    /// If the existing buffer is on the same device, and is of sufficient
    /// length, it is reused. Otherwise a new buffer is allocated and the
    /// existing buffer is freed. Calling this function invalidates any
    /// previously allocated memory regions.
    void create(id<MTLDevice> device, size_t size) {
        length = 0;

        if (buffer_device != device) {
            buffer_device = device;
            size = std::max(1048576ul, align_up(size, 8));
        } else if (size <= capacity) {
            return;
        }

        buffer = [device newBufferWithLength:size
                                     options:MTLResourceStorageModeManaged |
                                             MTLResourceCPUCacheModeWriteCombined];

        ptr = static_cast<char*>([buffer contents]);
        capacity = size;
    }

    /// Allocates a region of memory from the underlying MTLBuffer.
    /// Assumes there is sufficient capacity to carry out the allocation.
    /// Note: Regions are aligned to 256 byte boundaries, as such this function
    /// can use up to size + 255 bytes.
    region allocate(size_t size) {
        size_t offset = length;
        length = align_up(length + size, 256);
        assert(length <= capacity);
        return region{ptr + offset, offset};
    }

    /// Returns the underlying MTLBuffer.
    id<MTLBuffer> get() const {
        return buffer;
    }

    /// Informs the Metal device that the given range has been modified.
    /// @see -[MTLBuffer didModifyRange] for more information.
    void update(size_t start, size_t length) {
        [buffer didModifyRange:NSMakeRange(start, length)];
    }

    /// Try to acquire the buffers lock. Returns immediately.
    ///
    /// Note: Calling this function in a loop amounts to an inefficient, and
    /// more importantly, incorrect, spinlock implementation. Don't do it.
    ///
    /// @returns True if the lock was acquired successfully, otherwise false.
    bool try_lock() {
        return in_use.test_and_set() == false;
    }

    /// Release the buffers lock. May be called from any thread.
    void unlock() {
        in_use.clear();
    }
};

/// Adjusts the color attributes of cells under a block cursor.
class AdjustedGrid {
private:
    struct Range {
        const nvim::cell *begin;
        int16_t rowBegin;
        int16_t rowEnd;
        int16_t colBegin;
        int16_t colEnd;
    };

    nvim::cell adjustedCells[2];
    Range ranges[4];
    size_t rangesCount;

public:
    AdjustedGrid(const nvim::grid *grid, const nvim::cursor &cursor) {
        ranges[0].begin = grid->begin();
        ranges[0].rowBegin = 0;
        ranges[0].colBegin = 0;

        // If we're not dealing with a block cursor, no adjusments need to be
        // made. We can iterate the grid in one swoop.
        if (cursor.shape() != nvim::cursor_shape::block) {
            rangesCount = 1;
            ranges[0].rowEnd = grid->height();
            ranges[0].colEnd = grid->width();
            return;
        }

        // We need to adjust the cursor cells.
        // Grid's are immutable, so we make a copy of the adjusted cells.
        const nvim::cell *cursorCell = &cursor.cell();
        size_t cursorWidth = cursor.width();

        adjustedCells[0] = cursorCell[0].recolored(cursor.foreground(),
                                                   cursor.background(),
                                                   cursor.special());

        if (cursorWidth == 2) {
            adjustedCells[1] = cursorCell[1].recolored(cursor.foreground(),
                                                       cursor.background(),
                                                       cursor.special());
        }

        // When iterating over the grid, we need to swap out cursor cells with
        // our adjusted cells. The iteration order required to do that is
        // stored in an array of four Range objects.
        rangesCount = 4;

        // Start with full rows up until the cursor row.
        ranges[0].rowEnd = cursor.row();
        ranges[0].colEnd = grid->width();

        // Iterate from the start over the cursor row till the cursor column.
        ranges[1].begin    = cursorCell - cursor.col();
        ranges[1].rowBegin = cursor.row();
        ranges[1].rowEnd   = cursor.row() + 1;
        ranges[1].colBegin = 0;
        ranges[1].colEnd   = cursor.col();

        // We're at the cursor cells. Iterate over the adjusted cells instead.
        ranges[2].begin    = adjustedCells;
        ranges[2].rowBegin = cursor.row();
        ranges[2].rowEnd   = cursor.row() + 1;
        ranges[2].colBegin = cursor.col();
        ranges[2].colEnd   = cursor.col() + cursorWidth;

        // Start from after the cursor cells and finish off the grid.
        ranges[3].begin    = cursorCell + cursorWidth;
        ranges[3].rowBegin = cursor.row();
        ranges[3].rowEnd   = grid->height();
        ranges[3].colBegin = cursor.col() + cursorWidth;
        ranges[3].colEnd   = grid->width();
    }

    /// Iterate over the cursor adjusted grid.
    /// Calls the function object callback once for every cell in ascending
    /// order. The callback is invoked with three arguments:
    ///   1. The cell's row (int16_t).
    ///   2. The cell's column (int16_t).
    ///   3. A const pointer to the cell (const nvim::cell*).
    /// The return value of the callback is ignored.
    template<typename Callable>
    void forEach(Callable callback) {
        for (size_t i=0; i<rangesCount; ++i) {
            const Range &range = ranges[i];
            const nvim::cell *cell = range.begin;
            int16_t col = range.colBegin;

            for (int16_t row = range.rowBegin; row < range.rowEnd; ++row) {
                for (; col < range.colEnd; ++col, ++cell) {
                    callback(row, col, cell);
                }

                col = 0;
            }
        }
    }
};

@implementation NVGridView {
    CAMetalLayer *metalLayer;

    NVRenderContext *renderContext;
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLRenderPipelineState> backgroundRenderPipeline;
    id<MTLRenderPipelineState> glyphRenderPipeline;
    id<MTLRenderPipelineState> cursorRenderPipeline;
    id<MTLRenderPipelineState> lineRenderPipeline;

    glyph_manager *glyphManager;
    font_family fontFamily;
    mtlbuffer buffers[3];
    nvim::cursor cursor;
    const nvim::grid *grid;

    NSSize backingCellSize;
    simd_float2 cellSize;
    simd_float2 baselineTranslate;
    uint32_t cursorLineThickness;
    line_metrics underline;
    line_metrics undercurl;
    line_metrics strikethrough;

    dispatch_source_t blinkTimer;
    bool blinkTimerActive;
    bool inactive;

    uint64_t frameIndex;
}

- (instancetype)init {
    self = [super init];
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    self.layerContentsPlacement = NSViewLayerContentsPlacementTopLeft;

    blinkTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                        dispatch_get_main_queue());

    dispatch_set_context(blinkTimer, (__bridge void*)self);
    return self;
}

- (void)setRenderContext:(NVRenderContext *)context {
    renderContext            = context;
    device                   = context.device;
    commandQueue             = context.commandQueue;
    backgroundRenderPipeline = context.backgroundRenderPipeline;
    glyphRenderPipeline      = context.glyphRenderPipeline;
    cursorRenderPipeline     = context.cursorRenderPipeline;
    lineRenderPipeline       = context.lineRenderPipeline;
    glyphManager             = context.glyphManager;

    metalLayer.device = device;
}

- (NVRenderContext *)renderContext {
    return renderContext;
}

- (CALayer*)makeBackingLayer {
    metalLayer = [CAMetalLayer layer];
    metalLayer.delegate = self;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    metalLayer.allowsNextDrawableTimeout = NO;
    metalLayer.autoresizingMask = kCALayerHeightSizable | kCALayerWidthSizable;
    metalLayer.needsDisplayOnBoundsChange = YES;
    metalLayer.presentsWithTransaction = YES;
    return metalLayer;
}

- (NSSize)desiredFrameSize {
    NSSize frameSize;
    frameSize.width = backingCellSize.width * grid->width();
    frameSize.height = backingCellSize.height * grid->height();

    return frameSize;
}

- (nvim::grid_size)desiredGridSize {
    CGSize drawableSize = [metalLayer drawableSize];

    nvim::grid_size size;
    size.width  = drawableSize.width / cellSize.x;
    size.height = drawableSize.height / cellSize.y;
    return size;
}

- (NSSize)cellSize {
    return backingCellSize;
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
}

static void blinkCursorToggleOff(void *context);
static void blinkCursorToggleOn(void *context);

- (void)setGrid:(const nvim::grid *)newGrid {
    [self setNeedsDisplay:YES];

    grid = newGrid;
    cursor = newGrid->cursor();

    // If we're not the main window:
    //   - The cursor blink loop should have already been stopped.
    //   - We override the cursor shape to block_outline.
    if (inactive) {
        assert(!blinkTimerActive);
        cursor.shape(nvim::cursor_shape::block_outline);
        return;
    }

    if (cursor.blinks()) {
        auto time = dispatch_time(DISPATCH_TIME_NOW, cursor.blinkwait() * NSEC_PER_MSEC);

        dispatch_source_set_timer(blinkTimer, time, DISPATCH_TIME_FOREVER, 1 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler_f(blinkTimer, blinkCursorToggleOff);

        if (!blinkTimerActive) {
            dispatch_resume(blinkTimer);
            blinkTimerActive = true;
        }
    } else if (blinkTimerActive) {
        dispatch_suspend(blinkTimer);
        blinkTimerActive = false;
    }
}

- (const nvim::grid *)grid {
    return grid;
}

- (void)setInactive {
    if (inactive) {
        return;
    }

    inactive = true;
    cursor.shape(nvim::cursor_shape::block_outline);

    // The cursor shouldn't blink in inactive windows.
    if (blinkTimerActive) {
        dispatch_suspend(blinkTimer);
        blinkTimerActive = false;
    }

    [self setNeedsDisplay:YES];
}

- (void)setActive {
    if (inactive) {
        inactive = false;
        [self setGrid:grid];
    }
}

static void blinkCursorToggleOff(void *context) {
    NVGridView *self = (__bridge NVGridView*)context;

    self->cursor.toggle_off();
    [self setNeedsDisplay:YES];

    auto time = dispatch_time(DISPATCH_TIME_NOW, self->cursor.blinkoff() * NSEC_PER_MSEC);

    dispatch_source_set_timer(self->blinkTimer, time, DISPATCH_TIME_FOREVER, 1 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler_f(self->blinkTimer, blinkCursorToggleOn);
}

static void blinkCursorToggleOn(void *context) {
    NVGridView *self = (__bridge NVGridView*)context;

    self->cursor.toggle_on();
    [self setNeedsDisplay:YES];

    auto time = dispatch_time(DISPATCH_TIME_NOW, self->cursor.blinkon() * NSEC_PER_MSEC);

    dispatch_source_set_timer(self->blinkTimer, time, DISPATCH_TIME_FOREVER, 1 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler_f(self->blinkTimer, blinkCursorToggleOff);
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [metalLayer setDrawableSize:[self convertSizeToBacking:newSize]];
}

- (void)setFont:(const font_family&)font {
    fontFamily = font;

    CGFloat leading = floor(font.leading() + 0.5);
    CGFloat descent = floor(font.descent() + 0.5);
    CGFloat ascent = floor(font.ascent() + 0.5);

    CGFloat cellHeight = leading + descent + ascent;
    CGFloat cellWidth = floor(font.width() + 0.5);

    cellSize.x = cellWidth;
    cellSize.y = cellHeight;
    backingCellSize = [self convertSizeFromBacking:NSMakeSize(cellWidth, cellHeight)];

    baselineTranslate.x = 0;
    baselineTranslate.y = ascent;

    CGFloat underlinePos = font.underline_position();
    uint16_t lineThickness = floor(font.underline_thickness() + 0.5);
    int16_t underlineTranslate;

    if (underlinePos >= 0) {
        underlineTranslate = floor(underlinePos + 0.5);
    } else {
        underlineTranslate = floor(underlinePos - 0.5);
    }

    strikethrough.period = 0;
    strikethrough.thickness = lineThickness;
    strikethrough.ytranslate = ascent / 3;

    underline.period = 0;
    underline.thickness = lineThickness;
    underline.ytranslate = underlineTranslate;

    undercurl.period = 2 * font.scale_factor();
    undercurl.thickness = 2 * font.scale_factor();
    undercurl.ytranslate = underlineTranslate;

    cursorLineThickness = 1 * font.scale_factor();
    [metalLayer setContentsScale:font.scale_factor()];
}

- (const font_family&)font {
    return fontFamily;
}

- (void)displayLayer:(CALayer*)layer {
    const CGSize drawableSize = [metalLayer drawableSize];
    const uint64_t index = frameIndex % 3;
    mtlbuffer &buffer = buffers[index];

    // If we fail to acquire the buffer, drop this frame and try again on the
    // next draw loop iteration. This should be rare.
    if (!buffer.try_lock()) {
        [self setNeedsDisplay:YES];
        return;
    }

    // Allocate enough memory for the worst case scenario, where every cell has
    // a glyph, a strikethrough, and an underline / undercurl. It takes two
    // line_data objects to handle a cell with both a strikethrough and an
    // underline / undercurl.
    //
    // We're using a lot of memory to handle our line data, but most grids have
    // very few lines. Maybe this could be reworked.
    const size_t gridSize = grid->cells_size();
    const size_t uniformBufferSize    = sizeof(uniform_data);
    const size_t backgroundBufferSize = gridSize * sizeof(uint32_t);
    const size_t glyphBufferSize      = gridSize * sizeof(glyph_data);
    const size_t lineBufferSize       = gridSize * sizeof(line_data) * 2;

    // Pad to account for over allocations caused by alignment.
    const size_t bufferSize = (256 * 4) + uniformBufferSize
                                        + backgroundBufferSize
                                        + glyphBufferSize
                                        + lineBufferSize;

    buffer.create(device, bufferSize);
    auto uniformBuffer    = buffer.allocate(uniformBufferSize);
    auto backgroundBuffer = buffer.allocate(backgroundBufferSize);
    auto glyphBuffer      = buffer.allocate(glyphBufferSize);
    auto lineBuffer       = buffer.allocate(lineBufferSize);

    auto uniforms    = static_cast<uniform_data*>(uniformBuffer.ptr);
    auto backgrounds = static_cast<uint32_t*>(backgroundBuffer.ptr);
    auto glyphs      = static_cast<glyph_data*>(glyphBuffer.ptr);
    auto lines       = static_cast<line_data*>(lineBuffer.ptr);

    const simd_float2 pixelSize = simd_make_float2(2.0, -2.0) /
                                  simd_make_float2(drawableSize.width, drawableSize.height);

    uniforms->pixel_size        = pixelSize;
    uniforms->cell_pixel_size   = cellSize;
    uniforms->cell_size         = cellSize * pixelSize;
    uniforms->baseline          = baselineTranslate;
    uniforms->grid_width        = static_cast<uint32_t>(grid->width());
    uniforms->cursor_position   = simd_make_short2(cursor.col(), cursor.row());
    uniforms->cursor_color      = cursor.background();
    uniforms->cursor_line_width = cursorLineThickness;
    uniforms->cursor_cell_width = cursor.width();

    glyph_data *glyphsBegin = glyphs;
    line_data *linesBegin = lines;
    simd_short2 undercurlNext = simd_make_short2(-1, -1);
    uint16_t undercurlPosition = 0;

    AdjustedGrid(grid, cursor).forEach([&](int16_t row, int16_t col, const nvim::cell *cell) {
        simd_short2 gridpos = simd_make_short2(col, row);
        *backgrounds++ = cell->background();

        if (cell->has_line_emphasis()) {
            nvim::rgb_color color = cell->special();

            // Undercurls and underlines are mutually exclusive. We'll make
            // undercurls take priority, they usually represent errors,
            // so users won't appreciate them being hidden.
            if (cell->has_undercurl()) {
                if (simd_equal(undercurlNext, gridpos)) {
                    undercurlPosition += 1;
                } else {
                    undercurlPosition = 0;
                }

                undercurlNext = simd_make_short2(col + 1, row);
                *lines++ = line_data(gridpos, color, undercurl, undercurlPosition);
            } else if (cell->has_underline()) {
                *lines++ = line_data(gridpos, color, underline);
            }

            if (cell->has_strikethrough()) {
                *lines++ = line_data(gridpos, color, strikethrough);
            }
        }

        if (!cell->empty()) {
            glyph_rect glyph = glyphManager->get(fontFamily, *cell);
            *glyphs++ = glyph_data(gridpos, cell->width(), glyph);
        }
    });

    size_t glyphsCount = glyphs - glyphsBegin;
    size_t linesCount = lines - linesBegin;
    buffer.update(0, glyphBuffer.offset + (sizeof(glyph_data) * glyphsCount));

    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    MTLRenderPassDescriptor *desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = [drawable texture];
    desc.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionDontCare;

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:desc];

    [commandEncoder setRenderPipelineState:backgroundRenderPipeline];
    [commandEncoder setVertexBuffer:buffer.get() offset:uniformBuffer.offset atIndex:0];
    [commandEncoder setVertexBuffer:buffer.get() offset:backgroundBuffer.offset atIndex:1];
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:0
                       vertexCount:4
                     instanceCount:gridSize];

    if (glyphsCount) {
        [commandEncoder setRenderPipelineState:glyphRenderPipeline];
        [commandEncoder setVertexBufferOffset:glyphBuffer.offset atIndex:1];
        [commandEncoder setFragmentTexture:glyphManager->texture() atIndex:0];
        [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                           vertexStart:0
                           vertexCount:4
                         instanceCount:glyphsCount];
    }

    if (linesCount) {
        buffer.update(lineBuffer.offset, sizeof(line_data) * linesCount);

        [commandEncoder setRenderPipelineState:lineRenderPipeline];
        [commandEncoder setVertexBufferOffset:lineBuffer.offset atIndex:1];
        [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                           vertexStart:0
                           vertexCount:4
                         instanceCount:linesCount];
    }

    switch (cursor.shape()) {
        case nvim::cursor_shape::vertical:
            [commandEncoder setRenderPipelineState:cursorRenderPipeline];
            [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                               vertexStart:0
                               vertexCount:4
                             instanceCount:1
                              baseInstance:0];
            break;

        case nvim::cursor_shape::horizontal:
            [commandEncoder setRenderPipelineState:cursorRenderPipeline];
            [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                               vertexStart:0
                               vertexCount:4
                             instanceCount:1
                              baseInstance:1];
            break;

        case nvim::cursor_shape::block_outline:
            [commandEncoder setRenderPipelineState:cursorRenderPipeline];
            [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                               vertexStart:0
                               vertexCount:4
                             instanceCount:4
                              baseInstance:0];
            break;

        case nvim::cursor_shape::block:
            break; // Block cursors are handled with AdjustedGrids.
    }

    [commandEncoder endEncoding];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        self->buffers[index].unlock();
    }];

    [commandBuffer commit];
    [commandBuffer waitUntilScheduled];
    [drawable present];
    frameIndex += 1;
}

- (BOOL)isFlipped {
    return YES;
}

- (nvim::grid_point)cellLocation:(NSPoint)windowLocation {
    NSPoint viewLocation = [self convertPoint:windowLocation fromView:nil];

    if (viewLocation.x < 0 || viewLocation.y < 0) {
        return NVCellNotFound;
    }

    size_t row = viewLocation.x / backingCellSize.width;
    size_t col = viewLocation.y / backingCellSize.height;

    nvim::grid_point location;
    location.row = std::min(col, grid->height());
    location.column = std::min(row, grid->width());

    return location;
}

- (void)dealloc {
    if (!blinkTimerActive) {
        dispatch_resume(blinkTimer);
    }

    dispatch_source_cancel(blinkTimer);
}

@end
