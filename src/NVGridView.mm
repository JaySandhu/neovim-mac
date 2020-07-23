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

/// Describes a lines appearance and position.
struct LineMetrics {
    int16_t ytranslate; ///< The lines vertical offset from the baseline.
    uint16_t period;    ///< The dotted lines period. 0 for a solid line.
    uint16_t thickness; ///< The lines thickness.
};

/// Make a glyph_data object.
/// @param position The cell's grid position.
/// @param glyph    The cached glyph.
/// @param width    The cell's width (single or full width).
static inline glyph_data glyphData(simd_short2 position, glyph_cached glyph, uint32_t width) {
    glyph_data data;
    data.grid_position = position;
    data.texture_position = glyph.texture_position;
    data.glyph_position = glyph.glyph_position;
    data.glyph_size = glyph.glyph_size;
    data.texture_index = glyph.texture_index;
    data.cell_width = width;
    return data;
}

/// Make a line_data object.
/// @param gridPosition The cell's grid position.
/// @param metrics      The metrics describing the line.
/// @param color        The line's color.
/// @param linePosition The cell's position in the overall line. This is
///                     required to correctly render dotted lines. It can be
///                     ignored for solid lines.
static inline line_data lineData(simd_short2 gridPosition, LineMetrics metrics,
                                 nvim::rgb_color color, uint16_t linePosition = 0) {
    line_data data;
    data.grid_position = gridPosition;
    data.color = color;
    data.period = metrics.period;
    data.thickness = metrics.thickness;
    data.ytranslate = metrics.ytranslate;
    data.count = linePosition;
    return data;
}

/// Returns the position of a cell in an undercurl line.
/// The return value is a zero based index. For example, given the 5th cell in
/// a row with an undercurl stretching from columns 4 to 10, this function
/// returns 1.
static inline int16_t getUndecurlPosition(const nvim::cell *cell, int16_t col) {
    int16_t count = 0;
    const nvim::cell *rowbegin = cell - col;

    while (cell != rowbegin) {
        if ((--cell)->has_undercurl()) {
            count += 1;
        }
    }

    return count;
}

@implementation NVGridView {
    CAMetalLayer *metalLayer;

    NVRenderContext *renderContext;
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLRenderPipelineState> gridRenderPipeline;
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
    LineMetrics underlineMetrics;
    LineMetrics undercurlMetrics;
    LineMetrics strikethroughMetrics;
    uint32_t cursorLineThickness;

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
    renderContext        = context;
    device               = context.device;
    commandQueue         = context.commandQueue;
    gridRenderPipeline   = context.gridRenderPipeline;
    glyphRenderPipeline  = context.glyphRenderPipeline;
    cursorRenderPipeline = context.cursorRenderPipeline;
    lineRenderPipeline   = context.lineRenderPipeline;
    glyphManager         = context.glyphManager;

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

    strikethroughMetrics.period = 0;
    strikethroughMetrics.thickness = lineThickness;
    strikethroughMetrics.ytranslate = ascent / 3;

    underlineMetrics.period = 0;
    underlineMetrics.thickness = lineThickness;
    underlineMetrics.ytranslate = underlineTranslate;

    undercurlMetrics.period = 2 * font.scale_factor();
    undercurlMetrics.thickness = 2 * font.scale_factor();
    undercurlMetrics.ytranslate = underlineTranslate;

    cursorLineThickness = 1 * font.scale_factor();
    [metalLayer setContentsScale:font.scale_factor()];
}

- (const font_family&)font {
    return fontFamily;
}

- (CGFloat)scaleFactor {
    return fontFamily.scale_factor();
}

- (void)displayLayer:(CALayer*)layer {
    // This is where we render grids. Prepare for a mega long function.
    const size_t gridWidth  = grid->width();
    const size_t gridHeight = grid->height();
    const size_t gridSize   = grid->cells_size();

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
    // a glyph, an underline, and a strikethrough. We reserve an extra slot for
    // the cursor glyph_data and line_data objects. It takes two line_data
    // objects to handle a cell with both a strikethrough and an underline.
    //
    // We're using a lot of memory to handle our line data, but most grids have
    // very few lines. Maybe this could be reworked.
    const size_t uniformBufferSize    = sizeof(uniform_data);
    const size_t backgroundBufferSize = gridSize * sizeof(uint32_t);
    const size_t glyphBufferSize      = (gridSize + 1) * sizeof(glyph_data);
    const size_t lineBufferSize       = (gridSize + 1) * sizeof(line_data) * 2;

    // Pad by 1024 to account for over allocations caused by alignment.
    const size_t bufferSize = 1024 + uniformBufferSize +
                                     backgroundBufferSize +
                                     glyphBufferSize +
                                     lineBufferSize;

    buffer.create(device, bufferSize);
    auto uniformBuffer    = buffer.allocate(uniformBufferSize);
    auto backgroundBuffer = buffer.allocate(backgroundBufferSize);
    auto glyphBuffer      = buffer.allocate(glyphBufferSize);
    auto lineBuffer       = buffer.allocate(lineBufferSize);

    auto uniforms    = static_cast<uniform_data*>(uniformBuffer.ptr);
    auto backgrounds = static_cast<uint32_t*>(backgroundBuffer.ptr);
    auto glyphs      = static_cast<glyph_data*>(glyphBuffer.ptr);
    auto lines       = static_cast<line_data*>(lineBuffer.ptr);

    const nvim::cell &cursorCell = cursor.cell();
    simd_short2 cursorPosition = simd_make_short2(cursor.row(), cursor.col());

    const simd_float2 pixelSize = simd_make_float2(2.0, -2.0) /
                                  simd_make_float2(drawableSize.width, drawableSize.height);

    // Set our uniform data.
    uniforms->pixel_size        = pixelSize;
    uniforms->cell_pixel_size   = cellSize;
    uniforms->cell_size         = cellSize * pixelSize;
    uniforms->baseline          = baselineTranslate;
    uniforms->grid_width        = static_cast<uint32_t>(gridWidth);
    uniforms->cursor_position   = simd_make_short2(cursor.col(), cursor.row());
    uniforms->cursor_color      = cursor.background();
    uniforms->cursor_line_width = cursorLineThickness;
    uniforms->cursor_cell_width = cursorCell.width();

    const nvim::cell *cell = grid->begin();
    glyph_data *glyphsBegin = glyphs;
    line_data *linesBegin = lines;

    // Loop through the grid and set our frame data.
    for (size_t row=0; row<gridHeight; ++row) {
        size_t undercurlLast = gridWidth;
        uint16_t undercurlPosition = 0;

        for (size_t col=0; col<gridWidth; ++col, ++cell) {
            *backgrounds++ = cell->background();

            if (cell->has_line_emphasis()) {
                simd_short2 gridpos = simd_make_short2(row, col);
                nvim::rgb_color color = cell->special();

                // Undercurls and underlines are mutually exclusive. We'll make
                // undercurls take priority, they usually represent errors,
                // so users won't appreciate them being hidden.
                if (cell->has_undercurl()) {
                    // If this cell is adjacent to the last undercurl we saw,
                    // it represents a continuation, bump the position index.
                    // Else, this is a new line, start the position index at 0.
                    if (undercurlLast + 1 == col) {
                        undercurlPosition += 1;
                    } else {
                        undercurlPosition = 0;
                    }

                    undercurlLast = col;
                    *lines++ = lineData(gridpos, undercurlMetrics, color, undercurlPosition);
                } else if (cell->has_underline()) {
                    *lines++ = lineData(gridpos, underlineMetrics, color);
                }

                if (cell->has_strikethrough()) {
                    *lines++ = lineData(gridpos, strikethroughMetrics, color);
                }
            }

            if (!cell->empty()) {
                glyph_cached glyph = glyphManager->get(fontFamily, *cell);
                simd_short2 gridpos = simd_make_short2(row, col);
                *glyphs++ = glyphData(gridpos, glyph, cell->width());
            }
        }
    }

    size_t glyphsCount = glyphs - glyphsBegin;
    size_t linesCount = lines - linesBegin;

    // We're ready to start our render pass.
    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    MTLRenderPassDescriptor *desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = drawable.texture;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionDontCare;

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:desc];

    // Draw the grid background.
    [commandEncoder setRenderPipelineState:gridRenderPipeline];
    [commandEncoder setVertexBuffer:buffer.get() offset:uniformBuffer.offset atIndex:0];
    [commandEncoder setVertexBuffer:buffer.get() offset:backgroundBuffer.offset atIndex:1];
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:0
                       vertexCount:4
                     instanceCount:gridSize];

    // Draw glyphs if we have any.
    if (glyphsCount) {
        [commandEncoder setRenderPipelineState:glyphRenderPipeline];
        [commandEncoder setVertexBufferOffset:glyphBuffer.offset atIndex:1];
        [commandEncoder setFragmentTexture:glyphManager->texture() atIndex:0];
        [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                           vertexStart:0
                           vertexCount:4
                         instanceCount:glyphsCount];
    }

    // Draw lines if we have any.
    if (linesCount) {
        [commandEncoder setRenderPipelineState:lineRenderPipeline];
        [commandEncoder setVertexBufferOffset:lineBuffer.offset atIndex:1];
        [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                           vertexStart:0
                           vertexCount:4
                         instanceCount:linesCount];
    }

    // Finally draw the cursor.
    [commandEncoder setRenderPipelineState:cursorRenderPipeline];

    switch (cursor.shape()) {
        case nvim::cursor_shape::vertical:
            [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                               vertexStart:0
                               vertexCount:4
                             instanceCount:1
                              baseInstance:0];
            break;

        case nvim::cursor_shape::horizontal:
            [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                               vertexStart:0
                               vertexCount:4
                             instanceCount:1
                              baseInstance:1];
            break;

        case nvim::cursor_shape::block_outline:
            [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                               vertexStart:0
                               vertexCount:4
                             instanceCount:4
                              baseInstance:0];
            break;

        case nvim::cursor_shape::block:
            [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                               vertexStart:0
                               vertexCount:4
                             instanceCount:1
                              baseInstance:4];

            // We've just drawn over the cursor cell with a block. We've gotta
            // redraw any glyphs and lines we may have covered.
            if (!cursorCell.empty()) {
                CTFontRef font = fontFamily.get(cursorCell.font_attributes());

                glyph_cached glyph = glyphManager->get(font,
                                                       cursor.cell(),
                                                       cursor.background(),
                                                       cursor.foreground());

                *glyphs = glyphData(cursorPosition, glyph, cursorCell.width());

                [commandEncoder setRenderPipelineState:glyphRenderPipeline];
                [commandEncoder setVertexBufferOffset:glyphBuffer.offset atIndex:1];

                [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                                   vertexStart:0
                                   vertexCount:4
                                 instanceCount:1
                                  baseInstance:glyphsCount];

                glyphsCount += 1;
            }

            if (cursorCell.has_line_emphasis()) {
                size_t count = 0;
                nvim::rgb_color color = cursorCell.special();

                if (cursorCell.has_undercurl()) {
                    *lines++ = lineData(cursorPosition, undercurlMetrics, color,
                                        getUndecurlPosition(&cursorCell, cursor.col()));
                    count += 1;
                } else if (cursorCell.has_underline()) {
                    *lines++ = lineData(cursorPosition, underlineMetrics, color);
                    count += 1;
                }

                if (cursorCell.has_strikethrough()) {
                    *lines++ = lineData(cursorPosition, strikethroughMetrics, color);
                    count += 1;
                }

                [commandEncoder setRenderPipelineState:lineRenderPipeline];
                [commandEncoder setVertexBufferOffset:lineBuffer.offset atIndex:1];

                [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                                   vertexStart:0
                                   vertexCount:4
                                 instanceCount:count
                                  baseInstance:linesCount];

                linesCount += count;
            }
    }

    // Update our Metal buffers.
    buffer.update(0, glyphBuffer.offset + (sizeof(glyph_data) * glyphsCount));

    if (linesCount) {
        buffer.update(lineBuffer.offset, sizeof(line_data) * linesCount);
    }

    [commandEncoder endEncoding];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        // Release the buffer once the frame is rendered.
        self->buffers[index].unlock();
    }];

    [commandBuffer commit];
    [commandBuffer waitUntilScheduled];
    [drawable present];

    // We're done! Bump the frame index.
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
