//
//  Neovim Mac
//  NVGridView.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Carbon/Carbon.h>
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

    void insert(const void *source, size_t size) {
        const size_t new_length = length + size;

        if (new_length > capacity) {
            expand(new_length * 2);
        }

        memcpy(ptr + length, source, size);
        length = new_length;
    }

    void insert_unchecked(const void *source, size_t size) {
        memcpy(ptr + length, source, size);
        length += size;
        assert(length <= capacity);
    }

    template<typename T, typename ...Args>
    T& emplace_back(Args &&...args) {
        const size_t new_length = length + sizeof(T);

        if (new_length > capacity) {
            expand(new_length * 2);
        }

        T *ret = new (ptr + length) T(std::forward<Args>()...);
        length = new_length;
        return *ret;
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

    void* offset(size_t offset) {
        return ptr + offset;
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
    CAMetalLayer *metalLayer;

    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLRenderPipelineState> gridRenderPipeline;
    id<MTLRenderPipelineState> glyphRenderPipeline;
    id<MTLRenderPipelineState> cursorRenderPipeline;
    id<MTLRenderPipelineState> lineRenderPipeline;

    neovim *nvim;
    glyph_manager *glyph_manager;
    font_family font_family;
    mtlbuffer buffers[3];
    ui::grid *grid;

    simd_float2 cellSize;
    simd_float2 baselineTranslation;
    int32_t lineThickness;
    int32_t underlineTranslate;
    int32_t strikethroughTranslate;
    uint64_t frameIndex;

    simd_uint2 lastMouseLocationLeft;
    simd_uint2 lastMouseLocationRight;
    simd_uint2 lastMouseLocationOther;
    CGFloat scrollingDeltaX;
    CGFloat scrollingDeltaY;
}

- (instancetype)initWithFrame:(NSRect)frame
                renderContext:(NVRenderContext *)renderContext
                 neovimHandle:(neovim *)neovimHandle {
    self = [super initWithFrame:frame];
    nvim = neovimHandle;

    device               = renderContext.device;
    commandQueue         = renderContext.commandQueue;
    gridRenderPipeline   = renderContext.gridRenderPipeline;
    glyphRenderPipeline  = renderContext.glyphRenderPipeline;
    cursorRenderPipeline = renderContext.cursorRenderPipeline;
    lineRenderPipeline   = renderContext.lineRenderPipeline;
    glyph_manager        = renderContext.glyphManager;

    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    self.layerContentsPlacement = NSViewLayerContentsPlacementTopLeft;

    buffers[0] = mtlbuffer(device, 524288);
    buffers[1] = mtlbuffer(device, 524288);
    buffers[2] = mtlbuffer(device, 524288);

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

    NSSize scaledSize =  [self convertSizeToBacking:newSize];
    metalLayer.drawableSize = scaledSize;

    if ([self inLiveResize]) {
        int width  = scaledSize.width / cellSize.x;
        int height = scaledSize.height / cellSize.y;

        nvim->try_resize(width, height);
    }
}

- (NSSize)getCellSize {
    NSSize backingCellSize;
    backingCellSize.height = cellSize.y;
    backingCellSize.width = cellSize.x;

    return [self convertSizeFromBacking:backingCellSize];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
}

- (void)setGrid:(ui::grid *)newGrid {
    grid = newGrid;
}

- (void)setFont:(font_family)font {
    font_family = font;

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

    strikethroughTranslate = ascent / 3;
    lineThickness = floor(font.underline_thickness() + 0.5);
}

static inline glyph_data make_glyph_data(simd_short2 grid_position,
                                         cached_glyph glyph) {
    glyph_data data;
    data.grid_position = grid_position;
    data.texture_position = glyph.texture_position;
    data.glyph_position = glyph.glyph_position;
    data.glyph_size = glyph.glyph_size;
    data.texture_index = glyph.texture_index;
    return data;
}

static inline line_data make_underline_data(NVGridView *view,
                                            simd_short2 grid_position,
                                            ui::rgb_color color) {
    line_data data;
    data.grid_position = grid_position;
    data.color = color;
    data.period = UINT16_MAX;
    data.thickness = view->lineThickness;
    data.ytranslate = view->underlineTranslate;
    return data;
}

static inline line_data make_undercurl_data(NVGridView *view,
                                            simd_short2 grid_position,
                                            ui::rgb_color color) {
    line_data data;
    data.grid_position = grid_position;
    data.color = color;
    // TODO: Fix hardcoded values.
    data.period = 2;
    data.thickness = 2;
    data.ytranslate = view->underlineTranslate;
    return data;
}

static inline line_data make_strikethrough_data(NVGridView *view,
                                                simd_short2 grid_position,
                                                ui::rgb_color color) {
    line_data data;
    data.grid_position = grid_position;
    data.color = color;
    data.period = UINT16_MAX;
    data.thickness = view->lineThickness;
    data.ytranslate = view->strikethroughTranslate;
    return data;
}

- (void)displayLayer:(CALayer*)layer {
    const size_t grid_width = grid->width;
    const size_t grid_height = grid->height;
    const size_t grid_size = grid->cells.size();

    const CGSize drawable_size = [metalLayer drawableSize];
    const uint64_t index = frameIndex % 3;
    mtlbuffer &buffer = buffers[index];

    if (!buffer.aquire()) {
        [self setNeedsDisplay:YES];
        return;
    }

    const simd_float2 pixel_size = simd_float2{2.0, -2.0} /
                                   simd_float2{(float)drawable_size.width,
                                               (float)drawable_size.height};

    const size_t reserve_size = grid_size * (sizeof(uint32_t) + sizeof(glyph_data)) + 1024;

    buffer.clear();
    buffer.reserve(reserve_size);
    ui::cursor cursor = grid->cursor();

    uniform_data &data   = buffer.emplace_back_unchecked<uniform_data>();
    data.pixel_size      = pixel_size;
    data.cell_pixel_size = cellSize;
    data.cell_size       = cellSize * pixel_size;
    data.baseline        = baselineTranslation;
    data.grid_width      = (uint32_t)grid_width;
    data.cursor_position = simd_make_short2(cursor.col, cursor.row);
    data.cursor_color    = cursor.attrs.background.value;
    data.cursor_width    = 1;

    const size_t uniform_offset = buffer.offset();

    for (ui::cell &cell : grid->cells) {
        buffer.push_back_unchecked(cell.background());
    }

    const size_t grid_offset = buffer.offset();

    std::vector<line_data> lines;
    size_t glyph_count = 0;

    for (size_t row=0; row<grid_height; ++row) {
        ui::cell *cellrow = grid->get(row, 0);

        for (size_t col=0; col<grid_width; ++col) {
            ui::cell *cell = cellrow + col;
            ui::line_attributes line_attrs = cell->line_attributes();

            if (line_attrs != ui::line_attributes::none) {
                simd_short2 gridpos = simd_make_short2(row, col);
                ui::rgb_color color = cell->special();

                if (line_attrs & ui::line_attributes::undercurl) {
                    lines.push_back(make_undercurl_data(self, gridpos, color));
                } else if (line_attrs & ui::line_attributes::underline) {
                    lines.push_back(make_underline_data(self, gridpos, color));
                }

                if (line_attrs & ui::line_attributes::strikethrough) {
                    lines.push_back(make_strikethrough_data(self, gridpos, color));
                }
            }

            if (!cell->empty()) {
                cached_glyph glyph = glyph_manager->get(font_family, *cell);
                simd_short2 gridpos = simd_make_short2(row, col);
                glyph_data data = make_glyph_data(gridpos, glyph);
                buffer.push_back_unchecked(data);
                glyph_count += 1;
            }
        }
    }

    simd_short2 cursor_gridpos = simd_make_short2(cursor.row, cursor.col);
    ui::cell *cursor_cell = cursor.cell();
    glyph_data *cursor_glyph = &buffer.emplace_back_unchecked<glyph_data>();
    const size_t glyph_offset = buffer.offset();

    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    MTLRenderPassDescriptor *desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = drawable.texture;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionDontCare;

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:desc];

    [commandEncoder setRenderPipelineState:gridRenderPipeline];
    [commandEncoder setVertexBuffer:buffer.get() offset:uniform_offset atIndex:0];
    [commandEncoder setVertexBuffer:buffer.get() offset:grid_offset atIndex:1];

    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                       vertexStart:0
                       vertexCount:4
                     instanceCount:grid_size];

    if (glyph_count) {
        [commandEncoder setRenderPipelineState:glyphRenderPipeline];
        [commandEncoder setVertexBufferOffset:glyph_offset atIndex:1];
        [commandEncoder setFragmentTexture:glyph_manager->texture() atIndex:0];

        [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                           vertexStart:0
                           vertexCount:4
                         instanceCount:glyph_count];
    }

    size_t line_offset = 0;
    line_data *cursor_line = nullptr;

    if (lines.size()) {
        buffer.insert(lines.data(), lines.size() * sizeof(line_data));

        cursor_line = &buffer.emplace_back<line_data>();
        buffer.emplace_back<line_data>();

        line_offset = buffer.offset();

        [commandEncoder setRenderPipelineState:lineRenderPipeline];
        [commandEncoder setVertexBufferOffset:line_offset atIndex:1];

        [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                           vertexStart:0
                           vertexCount:4
                         instanceCount:lines.size()];
    }

    [commandEncoder setRenderPipelineState:cursorRenderPipeline];

    switch (cursor.attrs.shape) {
        case ui::cursor_shape::vertical:
            [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                               vertexStart:0
                               vertexCount:4
                             instanceCount:1
                              baseInstance:0];
            break;

        case ui::cursor_shape::horizontal:
            [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                               vertexStart:0
                               vertexCount:4
                             instanceCount:1
                              baseInstance:1];
            break;

        case ui::cursor_shape::block_outline:
            [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                               vertexStart:0
                               vertexCount:4
                             instanceCount:4
                              baseInstance:0];
            break;

        case ui::cursor_shape::block:
            [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                               vertexStart:0
                               vertexCount:4
                             instanceCount:1
                              baseInstance:4];

            if (!cursor_cell->empty()) {
                CTFontRef font = font_family.get(cursor_cell->font_attributes());

                cached_glyph glyph = glyph_manager->get(font,
                                                        cursor_cell->graphemes_view(),
                                                        cursor.attrs.background,
                                                        cursor.attrs.foreground);

                *cursor_glyph = make_glyph_data(cursor_gridpos, glyph);

                [commandEncoder setRenderPipelineState:glyphRenderPipeline];
                [commandEncoder setVertexBufferOffset:glyph_offset atIndex:1];

                [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                                   vertexStart:0
                                   vertexCount:4
                                 instanceCount:1
                                  baseInstance:glyph_count];
            }

            if (auto attrs = cursor_cell->line_attributes(); attrs != ui::line_attributes::none) {
                size_t count = 0;
                ui::rgb_color color = cursor_cell->special();

                if (attrs & ui::line_attributes::undercurl) {
                    *cursor_line++ = make_undercurl_data(self, cursor_gridpos, color);
                    count += 1;
                } else if (attrs & ui::line_attributes::underline) {
                    *cursor_line++ = make_underline_data(self, cursor_gridpos, color);
                    count += 1;
                }

                if (attrs & ui::line_attributes::strikethrough) {
                    *cursor_line++ = make_strikethrough_data(self, cursor_gridpos, color);
                    count += 1;
                }

                [commandEncoder setRenderPipelineState:lineRenderPipeline];
                [commandEncoder setVertexBufferOffset:line_offset atIndex:1];

                [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                                   vertexStart:0
                                   vertexCount:4
                                 instanceCount:count
                                  baseInstance:lines.size()];
            }
    }

    [commandEncoder endEncoding];

    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        self->buffers[index].release();
    }];

    buffer.update();
    [commandBuffer commit];
    [commandBuffer waitUntilScheduled];
    [drawable present];

    frameIndex += 1;
}

class input_modifiers {
private:
    char buffer[8];
    size_t length;

public:
    void push_back(char value) {
        const char data[2] = {value, '-'};
        memcpy(buffer + length, data, 2);
        length += 2;
    }

    explicit input_modifiers(NSEventModifierFlags flags) {
        length = 0;

        if (flags & NSEventModifierFlagShift) {
            push_back('S');
        }

        if (flags & NSEventModifierFlagCommand) {
            push_back('D');
        }

        if (flags & NSEventModifierFlagControl) {
            push_back('C');
        }

        if (flags & NSEventModifierFlagOption) {
            push_back('M');
        }
    }
    
    constexpr size_t max_size() const {
        return sizeof(buffer);
    }

    const char* data() const {
        return buffer;
    }

    size_t size() const {
        return length;
    }

    operator std::string_view() const {
        return std::string_view(buffer, length);
    }
};

static void namedKeyDown(neovim *nvim, NSEventModifierFlags flags, std::string_view keyname) {
    if (!(flags & (NSEventModifierFlagShift   |
                   NSEventModifierFlagCommand |
                   NSEventModifierFlagControl |
                   NSEventModifierFlagOption))) {
        nvim->input(keyname);
        return;
    }

    input_modifiers modifiers = input_modifiers(flags);
    
    char inputbuff[64] = {'<'};
    memcmp(inputbuff + 1,  modifiers.data(), modifiers.max_size());
    memcmp(inputbuff + 1 + modifiers.size(), keyname.data() + 1, keyname.size() - 1);
    
    size_t inputsize = modifiers.size() + keyname.size() - 1;
    nvim->input(std::string_view(inputbuff, inputsize));
}

static void keyDownIgnoreModifiers(neovim *nvim, NSEventModifierFlags flags, NSEvent *event) {
    NSString *nscharacters = [event charactersIgnoringModifiers];
    const char *characters = [nscharacters UTF8String];
    NSUInteger charlength = [nscharacters lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    // Can this ever happen?
    if (!charlength) {
        return;
    }
    
    if (charlength == 1 && *characters == '<') {
        namedKeyDown(nvim, flags & ~NSEventModifierFlagShift, "<lt>");
        return;
    }
    
    input_modifiers modifiers = input_modifiers(flags & ~NSEventModifierFlagShift);

    if (modifiers.size() == 0) {
        nvim->input(std::string_view(characters, charlength));
        return;
    }

    size_t inputsize = modifiers.size() + charlength + 2;

    if (inputsize <= 64) {
        char inputbuff[64];
        inputbuff[0] = '<';
        inputbuff[inputsize - 1] = '>';
        
        memcpy(inputbuff + 1,  modifiers.data(), modifiers.max_size());
        memcpy(inputbuff + 1 + modifiers.size(), characters, charlength);
        
        nvim->input(std::string_view(inputbuff, inputsize));
        return;
    }

    std::string input;
    input.reserve(inputsize);
    input.push_back('<');
    input.append(modifiers.data(), modifiers.size());
    input.append(characters, charlength);
    input.push_back('>');

    nvim->input(input);
}

- (void)keyDown:(NSEvent *)event {
    unsigned short code = [event keyCode];
    NSEventModifierFlags flags = [event modifierFlags];

    switch (code) {
        case kVK_Return:        return namedKeyDown(nvim, flags, "<CR>");
        case kVK_Tab:           return namedKeyDown(nvim, flags, "<Tab>");
        case kVK_Space:         return namedKeyDown(nvim, flags, "<Space>");
        case kVK_Delete:        return namedKeyDown(nvim, flags, "<BS>");
        case kVK_ForwardDelete: return namedKeyDown(nvim, flags, "<Del>");
        case kVK_Escape:        return namedKeyDown(nvim, flags, "<Esc>");
        case kVK_LeftArrow:     return namedKeyDown(nvim, flags, "<Left>");
        case kVK_RightArrow:    return namedKeyDown(nvim, flags, "<Right>");
        case kVK_DownArrow:     return namedKeyDown(nvim, flags, "<Down>");
        case kVK_UpArrow:       return namedKeyDown(nvim, flags, "<Up>");
        case kVK_VolumeUp:      return namedKeyDown(nvim, flags, "<VolumeUp>");
        case kVK_VolumeDown:    return namedKeyDown(nvim, flags, "<VolumeDown>");
        case kVK_Mute:          return namedKeyDown(nvim, flags, "<Mute>");
        case kVK_Help:          return namedKeyDown(nvim, flags, "<Help>");
        case kVK_Home:          return namedKeyDown(nvim, flags, "<Home>");
        case kVK_End:           return namedKeyDown(nvim, flags, "<End>");
        case kVK_PageUp:        return namedKeyDown(nvim, flags, "<PageUp>");
        case kVK_PageDown:      return namedKeyDown(nvim, flags, "<PageDown>");
        case kVK_F1:            return namedKeyDown(nvim, flags, "<F1>");
        case kVK_F2:            return namedKeyDown(nvim, flags, "<F2>");
        case kVK_F3:            return namedKeyDown(nvim, flags, "<F3>");
        case kVK_F4:            return namedKeyDown(nvim, flags, "<F4>");
        case kVK_F5:            return namedKeyDown(nvim, flags, "<F5>");
        case kVK_F6:            return namedKeyDown(nvim, flags, "<F6>");
        case kVK_F7:            return namedKeyDown(nvim, flags, "<F7>");
        case kVK_F8:            return namedKeyDown(nvim, flags, "<F8>");
        case kVK_F9:            return namedKeyDown(nvim, flags, "<F9>");
        case kVK_F10:           return namedKeyDown(nvim, flags, "<F10>");
        case kVK_F11:           return namedKeyDown(nvim, flags, "<F11>");
        case kVK_F12:           return namedKeyDown(nvim, flags, "<F12>");
        case kVK_F13:           return namedKeyDown(nvim, flags, "<F13>");
        case kVK_F14:           return namedKeyDown(nvim, flags, "<F14>");
        case kVK_F15:           return namedKeyDown(nvim, flags, "<F15>");
        case kVK_F16:           return namedKeyDown(nvim, flags, "<F16>");
        case kVK_F17:           return namedKeyDown(nvim, flags, "<F17>");
        case kVK_F18:           return namedKeyDown(nvim, flags, "<F18>");
        case kVK_F19:           return namedKeyDown(nvim, flags, "<F19>");
        case kVK_F20:           return namedKeyDown(nvim, flags, "<F20>");
    }

    NSString *characters = [event characters];
    NSUInteger length = [characters lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    bool cmdOrCtrl = flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl);

    if (!length || cmdOrCtrl) {
        keyDownIgnoreModifiers(nvim, flags, event);
        return;
    }

    std::string input([characters UTF8String], length);

    if (input == "<") {
        namedKeyDown(nvim, flags & ~NSEventModifierFlagShift, "<lt>");
    } else {
        nvim->input(input);
    }
}

- (BOOL)isFlipped {
    return YES;
}

static simd_uint2 cellLocation(NVGridView *self, NSEvent *event) {
    NSPoint windowLocation = [event locationInWindow];
    NSPoint viewLocation = [self convertPoint:windowLocation fromView:nil];
    NSSize cellSize = [self getCellSize];

    unsigned row = viewLocation.x / cellSize.width;
    unsigned col = viewLocation.y / cellSize.height;

    simd_uint2 cellLoc;
    cellLoc.x = std::min(row, (unsigned)self->grid->width);
    cellLoc.y = std::min(col, (unsigned)self->grid->height);
    return cellLoc;
}

static void mouseDownEvent(NVGridView *self, NSEvent *event,
                           simd_uint2 &lastLocation, std::string_view button) {
    simd_uint2 location = cellLocation(self, event);
    input_modifiers modifiers = input_modifiers([event modifierFlags]);

    self->nvim->input_mouse(button, "press", modifiers, location.y, location.x);
    lastLocation = location;
}

static void mouseDragEvent(NVGridView *self, NSEvent *event,
                           simd_uint2 &lastLocation, std::string_view button) {
    simd_uint2 location = cellLocation(self, event);

    if (!simd_equal(location, lastLocation)) {
        input_modifiers modifiers = input_modifiers([event modifierFlags]);
        
        self->nvim->input_mouse(button, "drag", modifiers, location.y, location.x);
        lastLocation = location;
    }
}

static void mouseUpEvent(NVGridView *self, NSEvent *event, std::string_view button) {
    simd_uint2 location = cellLocation(self, event);
    input_modifiers modifiers = input_modifiers([event modifierFlags]);

    self->nvim->input_mouse(button, "release", modifiers, location.y, location.x);
}

- (void)mouseDown:(NSEvent *)event {
    mouseDownEvent(self, event, lastMouseLocationLeft, "left");
}

- (void)mouseDragged:(NSEvent *)event {
    mouseDragEvent(self, event, lastMouseLocationLeft, "left");
}

- (void)mouseUp:(NSEvent *)event {
    mouseUpEvent(self, event, "left");
}

- (void)rightMouseDown:(NSEvent *)event {
    mouseDownEvent(self, event, lastMouseLocationRight, "right");
}

- (void)rightMouseDragged:(NSEvent *)event {
    mouseDragEvent(self, event, lastMouseLocationRight, "right");
}

- (void)rightMouseUp:(NSEvent *)event {
    mouseUpEvent(self, event, "right");
}

- (void)otherMouseDown:(NSEvent *)event {
    mouseDownEvent(self, event, lastMouseLocationOther, "middle");
}

- (void)otherMouseDragged:(NSEvent *)event {
    mouseDragEvent(self, event, lastMouseLocationOther, "middle");
}

- (void)otherMouseUp:(NSEvent *)event {
    mouseUpEvent(self, event, "middle");
}

static void scrollEvent(neovim *nvim, size_t count, std::string_view direction,
                        std::string_view modifiers, simd_uint2 location) {
    for (size_t i=0; i<count; ++i) {
        nvim->input_mouse("wheel", direction, modifiers, location.y, location.x);
    }
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat deltaX = [event scrollingDeltaX];
    CGFloat deltaY = [event scrollingDeltaY];
    
    input_modifiers modifiers = input_modifiers([event modifierFlags]);
    simd_uint2 location = cellLocation(self, event);
    
    if ([event hasPreciseScrollingDeltas]) {
        CGSize cellSize = [self getCellSize];
        NSEventPhase phase = [event phase];
        
        if (phase == NSEventPhaseBegan) {
            scrollingDeltaX = 0;
            scrollingDeltaY = 0;
        }

        scrollingDeltaX += deltaX;
        scrollingDeltaY += deltaY;
        
        deltaY = floor(scrollingDeltaY / cellSize.height);
        scrollingDeltaY -= (deltaY * cellSize.height);
        
        deltaX = floor(scrollingDeltaX / cellSize.width);
        scrollingDeltaX -= (deltaX * cellSize.width);
    }
            
    if (deltaY > 0) {
        scrollEvent(nvim, deltaY, "up", modifiers, location);
    } else if (deltaY < 0) {
        scrollEvent(nvim, -deltaY, "down", modifiers, location);
    }
    
    if (deltaX > 0) {
        scrollEvent(nvim, deltaX, "left", modifiers, location);
    } else if (deltaX < 0) {
        scrollEvent(nvim, -deltaX, "right", modifiers, location);
    }
}

@end
