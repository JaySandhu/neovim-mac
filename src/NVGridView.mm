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
    metalLayer.drawableSize = [self convertSizeToBacking:newSize];
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

    uniform_data &data   = buffer.emplace_back_unchecked<uniform_data>();
    data.pixel_size      = pixel_size;
    data.cell_pixel_size = cellSize;
    data.cell_size       = cellSize * pixel_size;
    data.baseline        = baselineTranslation;
    data.grid_width      = (uint32_t)grid_width;
    data.cursor_position = simd_make_short2(grid->cursor.col, grid->cursor.row);
    data.cursor_color    = grid->cursor.attrs.background.value;
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

    simd_short2 cursor_gridpos = simd_make_short2(grid->cursor.row, grid->cursor.col);
    ui::cell *cursor_cell = grid->get(grid->cursor.row, grid->cursor.col);
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

    switch (grid->cursor.attrs.shape) {
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
                                                        grid->cursor.attrs.background,
                                                        grid->cursor.attrs.foreground);

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

static void namedKeyDown(neovim *nvim, NSEvent *event, std::string_view keyname) {
    NSEventModifierFlags flags = [event modifierFlags];
    
    if (!(flags & (NSEventModifierFlagShift   |
                   NSEventModifierFlagCommand |
                   NSEventModifierFlagControl |
                   NSEventModifierFlagOption))) {
        nvim->input(keyname);
        return;
    }

    char modifiers[64] = {'<'};
    size_t modlength = 1;

    if (flags & NSEventModifierFlagShift) {
        modifiers[modlength++] = 'S';
        modifiers[modlength++] = '-';
    }

    if (flags & NSEventModifierFlagCommand) {
        modifiers[modlength++] = 'D';
        modifiers[modlength++] = '-';
    }

    if (flags & NSEventModifierFlagControl) {
        modifiers[modlength++] = 'C';
        modifiers[modlength++] = '-';
    }

    if (flags & NSEventModifierFlagOption) {
        modifiers[modlength++] = 'M';
        modifiers[modlength++] = '-';
    }

    memcpy(modifiers + modlength, keyname.data() + 1, keyname.size() - 1);
    size_t input_size = modlength + keyname.size() - 1;

    nvim->input(std::string_view(modifiers, input_size));
}

static void keyDownIgnoreModifiers(neovim *nvim,
                                   NSEventModifierFlags flags,
                                   NSEvent *event) {
    NSString *nscharacters = [event charactersIgnoringModifiers];
    const char *characters = [nscharacters UTF8String];
    NSUInteger charlength = [nscharacters lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    // Can this ever happen?
    if (!charlength) {
        return;
    }

    char input_buff[64] = {'<'};
    size_t modlength = 1;

    if (flags & NSEventModifierFlagCommand) {
        input_buff[modlength++] = 'D';
        input_buff[modlength++] = '-';
    }

    if (flags & NSEventModifierFlagControl) {
        input_buff[modlength++] = 'C';
        input_buff[modlength++] = '-';
    }

    if (flags & NSEventModifierFlagOption) {
        input_buff[modlength++] = 'M';
        input_buff[modlength++] = '-';
    }

    if (modlength == 1) {
        nvim->input(std::string_view(characters, charlength));
        return;
    }
    
    size_t input_size = modlength + charlength;
    
    if (input_size < sizeof(input_buff)) {
        memcpy(input_buff + modlength, characters, charlength);
        input_buff[input_size] = '>';
        nvim->input(std::string_view(input_buff, input_size + 1));
        return;
    }
    
    std::string input;
    input.reserve(input_size);
    input.append(input_buff, modlength);
    input.append(characters, charlength);
    input.push_back('>');

    nvim->input(input);
}

- (void)keyDown:(NSEvent *)event {
    unsigned short code = [event keyCode];

    switch (code) {
        case kVK_Return:        return namedKeyDown(nvim, event, "<CR>");
        case kVK_Tab:           return namedKeyDown(nvim, event, "<Tab>");
        case kVK_Space:         return namedKeyDown(nvim, event, "<Space>");
        case kVK_Delete:        return namedKeyDown(nvim, event, "<BS>");
        case kVK_ForwardDelete: return namedKeyDown(nvim, event, "<Del>");
        case kVK_Escape:        return namedKeyDown(nvim, event, "<Esc>");
        case kVK_LeftArrow:     return namedKeyDown(nvim, event, "<Left>");
        case kVK_RightArrow:    return namedKeyDown(nvim, event, "<Right>");
        case kVK_DownArrow:     return namedKeyDown(nvim, event, "<Down>");
        case kVK_UpArrow:       return namedKeyDown(nvim, event, "<Up>");
        case kVK_VolumeUp:      return namedKeyDown(nvim, event, "<VolumeUp>");
        case kVK_VolumeDown:    return namedKeyDown(nvim, event, "<VolumeDown>");
        case kVK_Mute:          return namedKeyDown(nvim, event, "<Mute>");
        case kVK_Help:          return namedKeyDown(nvim, event, "<Help>");
        case kVK_Home:          return namedKeyDown(nvim, event, "<Home>");
        case kVK_End:           return namedKeyDown(nvim, event, "<End>");
        case kVK_PageUp:        return namedKeyDown(nvim, event, "<PageUp>");
        case kVK_PageDown:      return namedKeyDown(nvim, event, "<PageDown>");
        case kVK_F1:            return namedKeyDown(nvim, event, "<F1>");
        case kVK_F2:            return namedKeyDown(nvim, event, "<F2>");
        case kVK_F3:            return namedKeyDown(nvim, event, "<F3>");
        case kVK_F4:            return namedKeyDown(nvim, event, "<F4>");
        case kVK_F5:            return namedKeyDown(nvim, event, "<F5>");
        case kVK_F6:            return namedKeyDown(nvim, event, "<F6>");
        case kVK_F7:            return namedKeyDown(nvim, event, "<F7>");
        case kVK_F8:            return namedKeyDown(nvim, event, "<F8>");
        case kVK_F9:            return namedKeyDown(nvim, event, "<F9>");
        case kVK_F10:           return namedKeyDown(nvim, event, "<F10>");
        case kVK_F11:           return namedKeyDown(nvim, event, "<F11>");
        case kVK_F12:           return namedKeyDown(nvim, event, "<F12>");
        case kVK_F13:           return namedKeyDown(nvim, event, "<F13>");
        case kVK_F14:           return namedKeyDown(nvim, event, "<F14>");
        case kVK_F15:           return namedKeyDown(nvim, event, "<F15>");
        case kVK_F16:           return namedKeyDown(nvim, event, "<F16>");
        case kVK_F17:           return namedKeyDown(nvim, event, "<F17>");
        case kVK_F18:           return namedKeyDown(nvim, event, "<F18>");
        case kVK_F19:           return namedKeyDown(nvim, event, "<F19>");
        case kVK_F20:           return namedKeyDown(nvim, event, "<F20>");
    }

    NSEventModifierFlags flags = [event modifierFlags];
    NSString *characters = [event characters];
    NSUInteger length = [characters lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    bool cmdOrCtrl = flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl);
    
    if (!length || cmdOrCtrl) {
        keyDownIgnoreModifiers(nvim, flags, event);
        return;
    }

    nvim->input(std::string_view([characters UTF8String], length));
}

@end
