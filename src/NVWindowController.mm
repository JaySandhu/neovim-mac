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

#include <thread>
#include "neovim.hpp"

enum MouseButton {
    MouseButtonLeft,
    MouseButtonRight,
    MouseButtonOther
};

enum WindowPosition {
    WindowPositionOrigin,
    WindowPositionCenter,
    WindowPositionCascade
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
    NVRenderContextManager *contextManager;
    NVRenderContext *renderContext;
    NVWindowController *windowIsOpen;
    NVWindowController *processIsAlive;
    NVGridView *gridView;

    neovim nvim;
    font_manager *fontManager;
    ui::ui_state *ui_controller;

    ui::grid_size lastGridSize;
    ui::grid_point lastMouseLocation[3];
    CGFloat scrollingDeltaX;
    CGFloat scrollingDeltaY;

    NSPoint origin;
    WindowPosition windowPosition;
    uint64_t isLiveResizing;
}

- (instancetype)initWithContextManager:(NVRenderContextManager *)contextManager
                             gridWidth:(size_t)width
                            gridHeight:(size_t)height {
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
    self->contextManager = contextManager;
    self->fontManager = contextManager.fontManager;

    nvim.set_controller(self);
    ui_controller = nvim.ui_state();

    lastGridSize.width = width;
    lastGridSize.height = height;
    return self;
}

- (instancetype)initWithContextManager:(NVRenderContextManager *)contextManager {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedFrameString = [defaults valueForKey:@"NVWindowControllerFrameSave"];

    if (savedFrameString) {
        NSRect savedFrame = NSRectFromString(savedFrameString);

        self = [self initWithContextManager:contextManager
                                  gridWidth:savedFrame.size.width
                                 gridHeight:savedFrame.size.height];

        origin = savedFrame.origin;
        windowPosition = WindowPositionOrigin;
    } else {
        self = [self initWithContextManager:contextManager
                                  gridWidth:80
                                 gridHeight:24];

        windowPosition = WindowPositionCenter;
    }

    return self;
}

- (instancetype)initWithNVWindowController:(NVWindowController *)controller {
    self = [self initWithContextManager:controller->contextManager
                              gridWidth:controller->lastGridSize.width
                             gridHeight:controller->lastGridSize.height];

    NSWindow *window = [controller window];
    NSRect frame = [window frame];

    NSPoint topLeft = CGPointMake(frame.origin.x,
                                  frame.origin.y + frame.size.height);
    
    origin = [window cascadeTopLeftFromPoint:topLeft];
    windowPosition = WindowPositionCascade;
    return self;
}

- (void)windowWillClose:(NSNotification *)notification {
    puts("Window closed!");
    windowIsOpen = nil;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    nvim.quit(true);
    return NO;
}

+ (NSArray<NVWindowController*>*)windows {
    NSArray *windows = [[NSApplication sharedApplication] windows];
    NSMutableArray *neovimWindows = [NSMutableArray arrayWithCapacity:windows.count];
    
    Class nvController = [NVWindowController class];
    
    for (NSWindow *window in windows) {
        NSWindowController *controller = [window windowController];
        
        if (controller && [controller isKindOfClass:nvController]) {
            [neovimWindows addObject:controller];
        }
    }
    
    return neovimWindows;
}

+ (BOOL)modifiedBuffers {
    NSArray<NVWindowController*> *windows = [NVWindowController windows];
    NSUInteger windowsCount = [windows count];
    
    if (!windowsCount) {
        return NO;
    }
    
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC);
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    std::atomic<unsigned long> waiting = windowsCount;
    BOOL unsaved = NO;
    
    for (NVWindowController *win in windows) {
        win->nvim.eval("len(filter(map(getbufinfo(), 'v:val.changed'), 'v:val'))", timeout,
                       [&](const msg::object &error, const msg::object &result, bool timed_out) {
            if (timed_out || !result.is<msg::integer>() || result.get<msg::integer>() != 0) {
                unsaved = YES;
            }
            
            if (--waiting == 0) {
                dispatch_semaphore_signal(semaphore);
            }
        });
    }
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return unsaved;
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

static inline NSRect visibleScreenRect(NSWindow *window) {
    NSScreen *screen = [window screen];

    if (screen && ([NSScreen screensHaveSeparateSpaces] || [[NSScreen screens] count] == 1)) {
        return [screen visibleFrame];
    }

    return NSRect{NSPoint{-16000, -16000}, NSSize{32000, 32000}};
}

- (void)neovimDidResize {
    NSWindow *window = [self window];

    NSRect windowRect = [window frame];
    NSRect screenRect = visibleScreenRect(window);
    NSSize cellSize = [gridView cellSize];

    CGFloat borderHeight = windowRect.size.height - window.contentView.frame.size.height;
    size_t maxGridHeight = (screenRect.size.height - borderHeight) / cellSize.height;
    size_t maxGridWidth = screenRect.size.width / cellSize.width;
    
    size_t gridWidth = std::min(lastGridSize.width, maxGridWidth);
    size_t gridHeight = std::min(lastGridSize.height, maxGridHeight);
    
    NSSize contentSize = CGSizeMake(gridWidth * cellSize.width,
                                    gridHeight * cellSize.height);
    
    [window setContentSize:contentSize];
    windowRect = [window frame];
    
    CGFloat maxX = screenRect.origin.x + (screenRect.size.width - windowRect.size.width);
    
    NSPoint origin = NSMakePoint(std::min(windowRect.origin.x, maxX),
                                 std::max(windowRect.origin.y, screenRect.origin.y));
    
    [window setFrameOrigin:origin];
    [self saveFrame];
    
    if (lastGridSize.width != gridWidth && lastGridSize.height != gridHeight) {
        nvim.try_resize(gridWidth, gridHeight);
    } else if (lastGridSize.width != gridWidth) {
        nvim.try_resize(gridWidth, lastGridSize.height);
    } else if (lastGridSize.height != gridHeight) {
        nvim.try_resize(lastGridSize.width, gridHeight);
    }
}

- (void)positionWindow:(NSWindow *)window {
    [window setContentSize:[gridView desiredFrameSize]];

    switch (windowPosition) {
        case WindowPositionOrigin:
            [window setFrameOrigin:origin];
            break;

        case WindowPositionCenter:
            [window center];
            break;

        case WindowPositionCascade:
            [window setFrameTopLeftPoint:origin];
            break;
    }

    NSRect windowRect = [window frame];
    NSRect screenRect = visibleScreenRect(window);

    if (windowRect.origin.x >= screenRect.origin.x && windowRect.origin.y >= screenRect.origin.y &&
        (windowRect.origin.x + windowRect.size.width) < (screenRect.origin.x + screenRect.size.width) &&
        (windowRect.origin.y + windowRect.size.height) < (screenRect.origin.y + screenRect.size.height)) {
        [self saveFrame];
    } else {
        [self neovimDidResize];
    }
}

- (void)cellSizeDidChange {
    NSWindow *window = [self window];
    NSSize cellSize = [gridView cellSize];
    
    [window setResizeIncrements:cellSize];
    [window setContentMinSize:CGSizeMake(cellSize.width * 12, cellSize.height * 3)];
}

static std::pair<arc_ptr<CTFontDescriptorRef>, CGFloat> getFontDescriptor(neovim &nvim,
                                                                          ui::ui_state *ui_controller) {
    std::lock_guard lock(ui_controller->option_lock);
    
    CGFloat defaultSize = [NSFont systemFontSize];
    std::vector<ui::guifont> fonts = ui_controller->get_fonts(defaultSize);
    
    for (auto [name, size] : fonts) {
        arc_ptr descriptor = font_manager::make_descriptor(name);
        
        if (descriptor) {
            return {descriptor, size};
        }
    }
    
    if (fonts.size()) {
        std::string error;
        error.reserve(512);
        error.append("Error: Invalid font(s): guifont=");
        error.append(ui_controller->opt_guifont);
        
        nvim.error_writeln(error);
    }
    
    return {{}, defaultSize};
}

- (void)handleScreenChanges:(NSNotification *)notification {
    assert([NSThread isMainThread]);

    NSScreen *screen = [self.window screen];

    NVRenderContext *oldContext = [gridView renderContext];
    NVRenderContext *newContext = [contextManager renderContextForScreen:screen];

    if (oldContext != newContext) {
        [gridView setRenderContext:newContext];
    }

    font_family *oldFont = gridView.font;
    CGFloat oldScaleFactor = oldFont->scale_factor();
    CGFloat newScaleFactor = screen.backingScaleFactor;

    if (oldScaleFactor != newScaleFactor) {
        CGFloat fontSize = oldFont->unscaled_size();
        gridView.font = fontManager->get_resized(*oldFont, fontSize, newScaleFactor);

        [self neovimDidResize];
        [self cellSizeDidChange];
    }
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    if (!windowIsOpen) {
        return;
    }

    [self handleScreenChanges:notification];
}

static inline NSScreen* screenContainingPoint(NSArray<NSScreen*> *screens, NSPoint point) {
    for (NSScreen *screen in screens) {
        NSRect screenRect = [screen frame];
        CGFloat endX = screenRect.origin.x + screenRect.size.width;
        CGFloat endY = screenRect.origin.y + screenRect.size.height;

        if ((point.x >= screenRect.origin.x && point.x < endX) ||
            (point.y >= screenRect.origin.y && point.y < endY)) {
            return screen;
        }
    }

    return nil;
}

- (void)initialRedraw {
    NSArray<NSScreen*> *screens = [NSScreen screens];
    NSScreen *proposedScreen = screenContainingPoint(screens, origin);
    CGFloat scaleFactor;

    if (proposedScreen) {
        scaleFactor = [proposedScreen backingScaleFactor];
        renderContext = [contextManager renderContextForScreen:proposedScreen];
    } else if ([screens count]) {
        proposedScreen = screens[0];
        scaleFactor = [proposedScreen backingScaleFactor];
        renderContext = [contextManager renderContextForScreen:proposedScreen];
        windowPosition = WindowPositionCenter;
        origin = CGPointMake(0, 0);
    } else {
        scaleFactor = 1.0f;
        renderContext = [contextManager defaultRenderContext];
    }

    auto [fontDescriptor, fontSize] = getFontDescriptor(nvim, ui_controller);

    if (!fontDescriptor) {
        fontDescriptor = font_manager::default_descriptor();
    }

    ui::grid *grid = ui_controller->get_global_grid();

    gridView = [[NVGridView alloc] init];
    gridView.grid = grid;
    gridView.font = fontManager->get(fontDescriptor.get(), fontSize, scaleFactor);

    NSWindow *window = [self window];
    [window setContentView:gridView];
    [window makeFirstResponder:self];
    [window setAnimationBehavior:NSWindowAnimationBehaviorDocumentWindow];

    [self positionWindow:window];
    [self cellSizeDidChange];
    [self showWindow:nil];

    windowIsOpen = self;
    lastGridSize = grid->size();

    if ([window screen] == proposedScreen) {
        gridView.renderContext = renderContext;
    } else {
        [self handleScreenChanges:nil];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleScreenChanges:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
}

- (void)redraw {
    if (!gridView) {
        return [self initialRedraw];
    }

    ui::grid *grid = ui_controller->get_global_grid();
    ui::grid_size gridSize = grid->size();

    [gridView setGrid:grid];

    if (gridSize != lastGridSize) {
        lastGridSize = gridSize;

        if (!isLiveResizing) {
            [self neovimDidResize];
        }
    }
}

- (void)attach {
    processIsAlive = self;
    nvim.ui_attach(lastGridSize.width, lastGridSize.height);
}

- (void)connect:(NSString *)addr {
    int error = nvim.connect([addr UTF8String]);

    if (error) {
        printf("Connect error: %i: %s\n", error, strerror(error));
        return;
    }

    [self attach];
}

- (void)spawn {
    NSString *nvimExecutable = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"nvim"];

    static const char *argv[] = {
        "nvim", "--embed", nullptr
    };

    int error = nvim.spawn([nvimExecutable UTF8String], argv);

    if (error) {
        printf("Spawn error: %i: %s\n", error, strerror(error));
        return;
    }

    [self attach];
}

- (void)spawnOpenFiles:(NSArray<NSURL*>*)urls {
    std::vector<const char*> argv{"nvim", "--embed", "-p"};
    
    if ([urls count]) {
        for (NSURL *url in urls) {
            argv.push_back([[url path] UTF8String]);
        }
    }

    argv.push_back(nullptr);

    NSString *nvimExecutable = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"nvim"];
    int error = nvim.spawn([nvimExecutable UTF8String], argv.data());
    
    if (error) {
        printf("Spawn error: %i: %s\n", error, strerror(error));
        return;
    }

    [self attach];
}

- (void)dealloc {
    puts("NVWindowController dealloced!");
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    [gridView setActive];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    [gridView setInactive];
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
        nvim.try_resize(size.width, size.height);
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
        char inputbuff[64] = {'<'};

        memcpy(inputbuff + 1,  modifiers.data(), modifiers.max_size());
        memcpy(inputbuff + 1 + modifiers.size(), characters, charlength);
        inputbuff[inputsize - 1] = '>';

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
        CGSize cellSize = [gridView cellSize];
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

static bool is_error(const msg::object &error, std::string_view error_string) {
    if (error.is<msg::array>()) {
        msg::array array = error.get<msg::array>();

        if (array.size() == 2 &&
            array[1].is<msg::string>() &&
            array[1].get<msg::string>() == error_string) {
            return true;
        }
    }

    return false;
}

std::string mode_string(neovim_mode mode) {
    char buffer[9] = {'u', 'n'};
    buffer[8] = 0;

    memcpy(buffer, &mode, 8);
    return std::string(buffer);
}

static inline bool is_ex_mode(neovim_mode mode) {
    return mode == neovim_mode::ex_mode ||
           mode == neovim_mode::ex_mode_vim;
}

static inline bool is_prompt(neovim_mode mode) {
    const char *bytes = reinterpret_cast<const char*>(&mode);
    return bytes[0] == 'r';
}

static inline bool is_visual_mode(neovim_mode mode) {
    return mode == neovim_mode::visual_block ||
           mode == neovim_mode::visual_char  ||
           mode == neovim_mode::visual_line;
}

static inline bool is_normal_mode(neovim_mode mode) {
    return mode == neovim_mode::normal                  ||
           mode == neovim_mode::normal_ctrli_insert     ||
           mode == neovim_mode::normal_ctrli_replace    ||
           mode == neovim_mode::normal_ctrli_virtual_replace;
}

static inline bool is_select_mode(neovim_mode mode) {
    return mode == neovim_mode::select_block ||
           mode == neovim_mode::select_char  ||
           mode == neovim_mode::select_line;
}

static inline bool is_insert_mode(neovim_mode mode) {
    return mode == neovim_mode::insert            ||
           mode == neovim_mode::insert_completion ||
           mode == neovim_mode::insert_completion_ctrlx;
}

static inline bool is_replace_mode(neovim_mode mode) {
    return mode == neovim_mode::replace                  ||
           mode == neovim_mode::replace_completion       ||
           mode == neovim_mode::replace_completion_ctrlx ||
           mode == neovim_mode::replace_virtual;
}

static inline bool is_command_line_mode(neovim_mode mode) {
    return mode == neovim_mode::command_line;
}

static inline bool is_operator_pending(neovim_mode mode) {
    static constexpr char prefix[2] = {'n', 'o'};
    return memcmp(&mode, prefix, 2) == 0;
}

#define CTRL_C "\x03"
#define CTRL_G "\x07"
#define CTRL_N "\x0e"
#define CTRL_O "\x0f"
#define CTRL_R "\x12"
#define CTRL_W "\x17"
#define CTRL_BACKSLASH "\x1c"

- (IBAction)newDocument:(id)sender {
    [[[NVWindowController alloc] initWithNVWindowController:self] spawn];
}

- (void)normalCommand:(std::string_view)command {
    neovim_mode mode = nvim.get_mode();

    if (mode == neovim_mode::unknown || is_ex_mode(mode) || is_prompt(mode)) {
        return NSBeep();
    }

    if (mode != neovim_mode::normal) {
        nvim.feedkeys(CTRL_BACKSLASH CTRL_N);
    }

    nvim.command(command);
}

static constexpr std::string_view openTabFunction =
R"VIMSCRIPT(function! NeovimForMacTabOpen(path) abort
    if bufnr('$') == 1 && line('$') == 1 && len(bufname(1)) == 0 && len(getline(1)) == 0
        execute "edit " . path
        return
    endif

    let bufnr = bufnr(a:path)

    if bufnr != -1
        let window_ids = getbufinfo(bufnr)[0]["windows"]

        if len(window_ids) == 0
            let bufnr = -1
        endif
    endif

    if bufnr == -1
        execute "tabedit " . a:path
        return
    endif

    let [tabpage, window] = win_id2tabwin(window_ids[0])

    execute "tabnext " . tabpage
    execute window . " wincmd w"
endfunction
)VIMSCRIPT";

- (IBAction)openDocument:(id)sender {
    neovim_mode mode = nvim.get_mode();

    if (mode == neovim_mode::unknown || is_ex_mode(mode) || is_prompt(mode)) {
        return NSBeep();
    }

    NSOpenPanel *panel = [[NSOpenPanel alloc] init];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    
    NSModalResponse response = [panel runModal];
    
    if (response != NSModalResponseOK) {
        return;
    }
        
    std::string command;
    command.reserve(2048);
    command.append(openTabFunction);
    
    for (NSURL *url in [panel URLs]) {
        command.append("call NeovimForMacTabOpen(\"");
        
        const char *file = url.path.UTF8String;
        
        while (char c = *file++) {
            if (c == '"') command.push_back('\\');
            command.push_back(c);
        }
        
        command.append("\")\n");
    }
    
    [self normalCommand:command];
}

static inline bool canSave(neovim &nvim) {
    neovim_mode mode = nvim.get_mode();
    
    if (mode == neovim_mode::unknown  || is_prompt(mode) ||
        mode == neovim_mode::terminal || is_ex_mode(mode)) {
        return false;
    }

    if (mode == neovim_mode::command_line || is_operator_pending(mode)) {
        nvim.feedkeys(CTRL_C);
    }
    
    return true;
}

- (IBAction)saveDocument:(id)sender {
    if (!canSave(nvim)) {
        return NSBeep();
    }

    nvim.command("write", [self](const msg::object &error,
                                 const msg::object &result, bool timed_out) {
        if (is_error(error, "Vim(write):E32: No file name")) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self saveDocumentAs:nil];
            });
        }
    });
}

- (IBAction)saveDocumentAs:(id)sender {
    if (!canSave(nvim)) {
        return NSBeep();
    }
    
    NSSavePanel *savePanel = [[NSSavePanel alloc] init];

    [savePanel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) {
            return;
        }
        
        if (canSave(self->nvim)) {
            return NSBeep();
        }
                
        std::string command("write ");
        command.append(savePanel.URL.path.UTF8String);
        
        self->nvim.command(command);
    }];
}

- (IBAction)newTab:(id)sender {
    [self normalCommand:"tabnew"];
}

- (IBAction)closeTab:(id)sender {
    [self normalCommand:"quit"];
}

- (IBAction)showHelp:(id)sender {
    [self normalCommand:"tab help"];
}

- (IBAction)selectAll:(id)sender {
    neovim_mode mode = nvim.get_mode();

    switch (mode) {
        case neovim_mode::normal:
            nvim.feedkeys("ggVG");
            break;

        case neovim_mode::command_line:
        case neovim_mode::operator_pending:
        case neovim_mode::operator_pending_forced_char:
        case neovim_mode::operator_pending_forced_line:
        case neovim_mode::operator_pending_forced_block:
        case neovim_mode::visual_block:
        case neovim_mode::visual_char:
        case neovim_mode::visual_line:
            nvim.feedkeys(CTRL_C "ggVG");
            break;

        case neovim_mode::normal_ctrli_insert:
        case neovim_mode::normal_ctrli_replace:
        case neovim_mode::normal_ctrli_virtual_replace:
            nvim.feedkeys("gg" CTRL_O "VG");
            break;

        case neovim_mode::insert:
        case neovim_mode::insert_completion:
        case neovim_mode::insert_completion_ctrlx:
        case neovim_mode::replace:
        case neovim_mode::replace_completion:
        case neovim_mode::replace_completion_ctrlx:
        case neovim_mode::replace_virtual:
            nvim.feedkeys(CTRL_O "gg" CTRL_O "VG");
            break;

        case neovim_mode::select_block:
        case neovim_mode::select_line:
        case neovim_mode::select_char:
            nvim.feedkeys(CTRL_C "gggH" CTRL_O "G");

        default:
            NSBeep();
            break;
    }
}

- (IBAction)cut:(id)sender {
    neovim_mode mode = nvim.get_mode();

    if (is_visual_mode(mode)) {
        nvim.feedkeys("\"+x");
        return;
    }

    if (is_select_mode(mode)) {
        nvim.feedkeys(CTRL_O "\"+x");
        return;
    }
    
    NSBeep();
}

- (IBAction)copy:(id)sender {
    neovim_mode mode = nvim.get_mode();

    if (is_visual_mode(mode)) {
        nvim.feedkeys("\"+y");
        return;
    }

    if (is_select_mode(mode)) {
        nvim.feedkeys(CTRL_O "\"+ygv" CTRL_G);
        return;
    }
    
    NSBeep();
}

- (IBAction)paste:(id)sender {
    neovim_mode mode = nvim.get_mode();

    if (is_normal_mode(mode)) {
        nvim.feedkeys("\"+gP");
        return;
    }
    
    if (is_visual_mode(mode)) {
        nvim.feedkeys("\"_dP");
        return;
    }

    if (is_insert_mode(mode) || is_replace_mode(mode)) {
        nvim.feedkeys(CTRL_O "\"+gP");
        return;
    }
    
    if (is_select_mode(mode)) {
        nvim.feedkeys(CTRL_O "\"_dP");
        return;
    }

    if (is_operator_pending(mode)) {
        nvim.feedkeys(CTRL_C "\"+gP");
        return;
    }

    if (is_command_line_mode(mode)) {
        nvim.feedkeys(CTRL_R "+");
        return;
    }
    
    if (mode == neovim_mode::terminal) {
        nvim.feedkeys(CTRL_W "\"+");
        return;
    }
    
    NSBeep();
}

- (IBAction)undo:(id)sender {
    neovim_mode mode = nvim.get_mode();

    if (is_normal_mode(mode)) {
        nvim.feedkeys("u");
        return;
    }

    if (is_insert_mode(mode) || is_replace_mode(mode)) {
        nvim.feedkeys(CTRL_O "u");
        return;
    }

    if (is_command_line_mode(mode) || is_operator_pending(mode) ||
        is_visual_mode(mode)       || is_select_mode(mode)) {
        nvim.feedkeys(CTRL_C "u");
        return;
    }
    
    NSBeep();
}

- (IBAction)redo:(id)sender {
    neovim_mode mode = nvim.get_mode();

    if (is_normal_mode(mode)) {
        nvim.feedkeys(CTRL_R);
        return;
    }

    if (is_insert_mode(mode) || is_replace_mode(mode)) {
        nvim.feedkeys(CTRL_O CTRL_R);
        return;
    }

    if (is_command_line_mode(mode) || is_operator_pending(mode) ||
        is_visual_mode(mode)       || is_select_mode(mode)) {
        nvim.feedkeys(CTRL_C CTRL_R);
        return;
    }
    
    NSBeep();
}

- (IBAction)zoomIn:(id)sender {
    font_family *font = [gridView font];
    CGFloat size = font->unscaled_size() + 1;
    
    if (size > 72) {
        return NSBeep();
    }

    CGFloat scaleFactor = [self.window backingScaleFactor];
    [gridView setFont:fontManager->get_resized(*font, size, scaleFactor)];

    [self neovimDidResize];
    [self cellSizeDidChange];
}

- (IBAction)zoomOut:(id)sender {
    font_family *font = [gridView font];
    CGFloat size = font->unscaled_size() - 1;
    
    if (size < 6) {
        return NSBeep();
    }
    
    CGFloat scaleFactor = [self.window backingScaleFactor];
    [gridView setFont:fontManager->get_resized(*font, size, scaleFactor)];

    [self neovimDidResize];
    [self cellSizeDidChange];
}

- (void)titleDidChange {
    NSString *title = [=](){
        std::lock_guard lock(ui_controller->option_lock);

        return [[NSString alloc] initWithBytes:ui_controller->title.data()
                                        length:ui_controller->title.size()
                                      encoding:NSUTF8StringEncoding];
    }();
    
    [[self window] setTitle:title];
}

- (void)fontDidChange {
    if (!windowIsOpen) {
        return;
    }

    auto [fontDescriptor, fontSize] = getFontDescriptor(nvim, ui_controller);
    
    if (fontDescriptor) {
        CGFloat scaleFactor = [self.window backingScaleFactor];
        font_family newfont = fontManager->get(fontDescriptor.get(), fontSize, scaleFactor);
        
        [gridView setFont:newfont];
        [self neovimDidResize];
        [self cellSizeDidChange];
    }
}

- (void)optionsDidChange {
    static constexpr ui::options expected = {
        .ext_cmdline    = false,
        .ext_hlstate    = false,
        .ext_linegrid   = true,
        .ext_messages   = false,
        .ext_multigrid  = false,
        .ext_popupmenu  = false,
        .ext_tabline    = false,
        .ext_termcolors = false
    };
    
    ui::options opts = [=](){
        std::lock_guard lock(ui_controller->option_lock);
        return ui_controller->opts;
    }();
    
    if (opts != expected) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"Unexpected UI options";
        alert.informativeText = @"Neovim is currently using unsupported UI options. "
                                 "This may cause rendering defects.";
        
        [alert runModal];
    }
}

@end
