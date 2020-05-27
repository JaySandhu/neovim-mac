//
//  Neovim Mac
//  NVWindowController.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Carbon/Carbon.h>
#import "NVWindowController.h"
#import "NVGridView.h"

#include "neovim.hpp"

static inline MTLRenderPipelineDescriptor* defaultPipelineDescriptor() {
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    desc.vertexBuffers[0].mutability = MTLMutabilityImmutable;
    desc.fragmentBuffers[0].mutability = MTLMutabilityImmutable;
    return desc;
}

static inline MTLRenderPipelineDescriptor* blendedPipelineDescriptor() {
    MTLRenderPipelineDescriptor *desc = defaultPipelineDescriptor();
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    return desc;
}

@implementation NVRenderContext {
    font_manager font_manager;
    glyph_manager glyph_manager;
}

- (instancetype)initWithError:(NSError **)error {
    *error = nil;

    self = [super init];
    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];

    id<MTLLibrary> lib = [_device newDefaultLibrary];

    MTLRenderPipelineDescriptor *gridDesc = defaultPipelineDescriptor();
    gridDesc.label = @"Grid background render pipeline";
    gridDesc.vertexFunction = [lib newFunctionWithName:@"grid_background"];
    gridDesc.fragmentFunction = [lib newFunctionWithName:@"fill_background"];
    _gridRenderPipeline = [_device newRenderPipelineStateWithDescriptor:gridDesc error:error];

    if (*error) return self;

    MTLRenderPipelineDescriptor *glyphDesc = defaultPipelineDescriptor();
    glyphDesc.label = @"Glyph render pipeline";
    glyphDesc.vertexFunction = [lib newFunctionWithName:@"glyph_render"];
    glyphDesc.fragmentFunction = [lib newFunctionWithName:@"glyph_fill"];
    _glyphRenderPipeline = [_device newRenderPipelineStateWithDescriptor:glyphDesc error:error];

    if (*error) return self;

    MTLRenderPipelineDescriptor *cursorDesc = defaultPipelineDescriptor();
    cursorDesc.label = @"Cursor render pipeline";
    cursorDesc.vertexFunction = [lib newFunctionWithName:@"cursor_render"];
    cursorDesc.fragmentFunction = [lib newFunctionWithName:@"fill_background"];
    _cursorRenderPipeline = [_device newRenderPipelineStateWithDescriptor:cursorDesc error:error];

    if (*error) return self;

    MTLRenderPipelineDescriptor *lineDesc = blendedPipelineDescriptor();
    lineDesc.label = @"Line render pipeline";
    lineDesc.vertexFunction = [lib newFunctionWithName:@"line_render"];
    lineDesc.fragmentFunction = [lib newFunctionWithName:@"fill_line"];
    _lineRenderPipeline = [_device newRenderPipelineStateWithDescriptor:lineDesc error:error];

    if (*error) return self;

    glyph_manager.rasterizer = glyph_rasterizer(256, 256);
    glyph_manager.texture_cache = glyph_texture_cache(_commandQueue, 512, 512);

    return self;
}

- (glyph_manager*)glyphManager {
    return &glyph_manager;
}

- (font_manager*)fontManager {
    return &font_manager;
}

@end

enum MouseButton {
    MouseButtonLeft,
    MouseButtonRight,
    MouseButtonOther
};

static inline std::string_view buttonName(MouseButton button) {
    static constexpr std::string_view names[] = {
        "left",
        "right",
        "middle"
    };
    
    return names[button];
}

@implementation NVWindowController {
    NVRenderContext *renderContext;
    NVWindowController *windowIsOpen;
    NVWindowController *processIsAlive;
    NVGridView *gridView;
    
    neovim nvim;
    font_manager *font_manager;
    ui::ui_state *ui_controller;
    
    ui::grid_size lastGridSize;
    ui::grid_point lastMouseLocation[3];
    CGFloat scrollingDeltaX;
    CGFloat scrollingDeltaY;
    
    uint64_t isLiveResizing;
}

- (instancetype)initWithRenderContext:(NVRenderContext *)renderContext {
    NSWindow *window = [[NSWindow alloc] init];
    
    [window setStyleMask:NSWindowStyleMaskTitled                |
                         NSWindowStyleMaskClosable              |
                         NSWindowStyleMaskMiniaturizable        |
                         NSWindowStyleMaskResizable];

    [window setDelegate:self];
    [window setTitle:@"window"];
    [window setTabbingMode:NSWindowTabbingModeDisallowed];
    [window setWindowController:self];

    self = [super initWithWindow:window];
    self->renderContext = renderContext;
    self->font_manager = renderContext.fontManager;

    nvim.set_controller(self);
    ui_controller = nvim.ui_state();
    return self;
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    windowIsOpen = self;
}

- (void)windowWillClose:(NSNotification *)notification {
    puts("Window closed!");
    windowIsOpen = nil;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    nvim.quit(true);
    return NO;
}

- (void)close {
    if (windowIsOpen) {
        [super close];
    }
}

- (void)shutdown {
    processIsAlive = nil;
}

- (void)saveFrame {
    NSRect rect = [self.window frame];
    rect.size.width = lastGridSize.width;
    rect.size.height = lastGridSize.height;
    
    NSString *stringRect = NSStringFromRect(rect);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setValue:stringRect forKey:@"NVWindowControllerFrameSave"];
}

- (NSRect)loadFrame {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *frameSave = [defaults valueForKey:@"NVWindowControllerFrameSave"];
    
    if (frameSave) {
        return NSRectFromString(frameSave);
    } else {
        return CGRectNull;
    }
}

static inline bool isNullRect(const CGRect &rect) {
    return memcmp(&rect, &CGRectNull, sizeof(CGRect)) == 0;
}

- (void)redraw {
    ui::grid *grid = ui_controller->get_global_grid();

    if (!gridView) {
        [self showWindow:nil];
        NSWindow *window = [self window];
        lastGridSize = grid->size();
        
        gridView = [[NVGridView alloc] initWithGrid:grid
                                         fontFamily:font_manager->get("SF Mono", 15)
                                      renderContext:renderContext];
        
        [window setContentSize:gridView.frame.size];
        [window setContentView:gridView];
        [window setResizeIncrements:[gridView getCellSize]];
        [window makeFirstResponder:self];
    
        NSRect savedRect = [self loadFrame];
        
        if (isNullRect(savedRect)) {
            [window center];
        } else {
            [window setFrameOrigin:savedRect.origin];
        }
        
        [gridView setNeedsDisplay:YES];
        return;
    }
    
    [gridView setGrid:grid];
    [gridView setNeedsDisplay:YES];
    
    ui::grid_size gridSize = grid->size();

    if (gridSize != lastGridSize) {
        lastGridSize = gridSize;
        
        if (!isLiveResizing) {
            NSSize frameSize = [gridView desiredFrameSize];
            [self.window setContentSize:frameSize];
            [self saveFrame];
        }
    }
}

- (void)connect:(NSString *)addr {
    int error = nvim.connect([addr UTF8String]);

    if (error) {
        printf("Connect error: %i: %s\n", error, strerror(error));
        return;
    }
    
    processIsAlive = self;
    NSRect savedFrame = [self loadFrame];
    
    if (isNullRect(savedFrame)) {
        nvim.ui_attach(80, 24);
    } else {
        nvim.ui_attach(savedFrame.size.width, savedFrame.size.height);
    }
}

- (void)spawn {
    int error = nvim.spawn("/usr/local/bin/nvim",
                           {"nvim", "--embed"}, {});
    
    if (error) {
        printf("Spawn error: %i: %s\n", error, strerror(error));
        return;
    }
    
    processIsAlive = self;
    nvim.ui_attach(80, 24);
}

- (void)dealloc {
    puts("NVWindowController dealloced!");
}

- (void)windowWillStartLiveResize:(NSNotification *)notification {
    isLiveResizing += 1;
}

- (void)windowDidEndLiveResize:(NSNotification *)notification {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        self->isLiveResizing -= 1;

        if (!self->isLiveResizing) {
            NSSize currentSize = [self->gridView frame].size;
            NSSize desiredSize = [self->gridView desiredFrameSize];
            
            if (memcmp(&currentSize, &desiredSize, sizeof(NSSize)) != 0) {
                [self.window setContentSize:desiredSize];
            }
            
            [self saveFrame];
        }
    });
}

- (void)windowDidMove:(NSNotification *)notification {
    [self saveFrame];
}

- (void)windowDidResize:(NSNotification *)notification {
    if (isLiveResizing) {
        ui::grid_size size = [gridView desiredGridSize];
        nvim.try_resize((int)size.width, (int)size.height);
    }
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

static void namedKeyDown(neovim &nvim, NSEventModifierFlags flags, std::string_view keyname) {
    if (!(flags & (NSEventModifierFlagShift   |
                   NSEventModifierFlagCommand |
                   NSEventModifierFlagControl |
                   NSEventModifierFlagOption))) {
        nvim.input(keyname);
        return;
    }

    input_modifiers modifiers = input_modifiers(flags);
    
    char inputbuff[64] = {'<'};
    memcmp(inputbuff + 1,  modifiers.data(), modifiers.max_size());
    memcmp(inputbuff + 1 + modifiers.size(), keyname.data() + 1, keyname.size() - 1);
    
    size_t inputsize = modifiers.size() + keyname.size() - 1;
    nvim.input(std::string_view(inputbuff, inputsize));
}

static void keyDownIgnoreModifiers(neovim &nvim, NSEventModifierFlags flags, NSEvent *event) {
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
        nvim.input(std::string_view(characters, charlength));
        return;
    }

    size_t inputsize = modifiers.size() + charlength + 2;

    if (inputsize <= 64) {
        char inputbuff[64];
        inputbuff[0] = '<';
        inputbuff[inputsize - 1] = '>';
        
        memcpy(inputbuff + 1,  modifiers.data(), modifiers.max_size());
        memcpy(inputbuff + 1 + modifiers.size(), characters, charlength);
        
        nvim.input(std::string_view(inputbuff, inputsize));
        return;
    }

    std::string input;
    input.reserve(inputsize);
    input.push_back('<');
    input.append(modifiers.data(), modifiers.size());
    input.append(characters, charlength);
    input.push_back('>');

    nvim.input(input);
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
        nvim.input(input);
    }
}

- (void)mouseDown:(NSEvent *)event button:(MouseButton)button {
    ui::grid_point location = [gridView cellLocation:event.locationInWindow];
    input_modifiers modifiers = input_modifiers(event.modifierFlags);
    
    nvim.input_mouse(buttonName(button), "press", modifiers, location.row, location.column);
    lastMouseLocation[button] = location;
}

- (void)mouseDragged:(NSEvent *)event button:(MouseButton)button {
    ui::grid_point location = [gridView cellLocation:event.locationInWindow];
    ui::grid_point &lastLocation = lastMouseLocation[button];
    
    if (location != lastLocation) {
        input_modifiers modifiers = input_modifiers(event.modifierFlags);
        nvim.input_mouse(buttonName(button), "drag", modifiers, location.row, location.column);
        lastLocation = location;
    }
}

- (void)mouseUp:(NSEvent *)event button:(MouseButton)button {
    ui::grid_point location = [gridView cellLocation:event.locationInWindow];
    input_modifiers modifiers = input_modifiers(event.modifierFlags);
    
    nvim.input_mouse(buttonName(button), "release", modifiers, location.row, location.column);
}

- (void)mouseDown:(NSEvent *)event {
    [self mouseDown:event button:MouseButtonLeft];
}

- (void)mouseDragged:(NSEvent *)event {
    [self mouseDragged:event button:MouseButtonLeft];
}

- (void)mouseUp:(NSEvent *)event {
    [self mouseUp:event button:MouseButtonLeft];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self mouseDown:event button:MouseButtonRight];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self mouseDragged:event button:MouseButtonRight];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self mouseUp:event button:MouseButtonRight];
}

- (void)otherMouseDown:(NSEvent *)event {
    [self mouseDown:event button:MouseButtonOther];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self mouseDragged:event button:MouseButtonOther];
}

- (void)otherMouseUp:(NSEvent *)event {
    [self mouseUp:event button:MouseButtonOther];
}

static void scrollEvent(neovim &nvim, size_t count, std::string_view direction,
                        std::string_view modifiers, ui::grid_point location) {
    for (size_t i=0; i<count; ++i) {
        nvim.input_mouse("wheel", direction, modifiers, location.row, location.column);
    }
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat deltaX = [event scrollingDeltaX];
    CGFloat deltaY = [event scrollingDeltaY];
    
    input_modifiers modifiers = input_modifiers([event modifierFlags]);
    ui::grid_point location = [gridView cellLocation:event.locationInWindow];
    
    if ([event hasPreciseScrollingDeltas]) {
        CGSize cellSize = [gridView getCellSize];
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
