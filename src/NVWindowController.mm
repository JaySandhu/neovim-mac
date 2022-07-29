//
//  Neovim Mac
//  NVWindowController.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Carbon/Carbon.h>
#import "NVColorScheme.h"
#import "NVGridView.h"
#import "NVPreferences.h"
#import "NVTabLine.h"
#import "NVWindow.h"
#import "NVWindowController.h"

#include <thread>
#include "log.h"
#include "neovim.hpp"

#define CTRL_C "\x03"
#define CTRL_G "\x07"
#define CTRL_N "\x0e"
#define CTRL_O "\x0f"
#define CTRL_R "\x12"
#define CTRL_W "\x17"
#define CTRL_BACKSLASH "\x1c"

static constexpr int32_t MIN_GRID_WIDTH = 12;
static constexpr int32_t MIN_GRID_HEIGHT = 3;

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

static NSMutableArray<NVWindowController*> *neovimWindows = [[NSMutableArray alloc] init];

@interface NVWindowController() <NVTabLineDelegate>
@end

@implementation NVWindowController {
    NVRenderContextManager *contextManager;
    NVRenderContext *renderContext;
    NVColorScheme *colorScheme;
    NVGridView *gridView;
    NVTabLine *tabLine;
    NSView *titlebarView;

    NSMutableArray<NVTab*> *tabs;
    NSLayoutConstraint *gridViewWidthConstraint;
    NSLayoutConstraint *gridViewHeightConstraint;
    NSLayoutConstraint *titlebarHeightConstraint;

    font_manager *fontManager;
    nvim::process nvim;
    nvim::showtabline showTabLineOption;
    nvim::ui_options uiOptions;
    nvim::grid_size lastGridSize;
    nvim::grid_point lastMouseLocation[3];

    CGFloat scrollingDeltaX;
    CGFloat scrollingDeltaY;

    BOOL titlebarAppearsTransparent;
    BOOL shouldCenter;
    BOOL isOpen;
    BOOL isAlive;
    uint64_t isLiveResizing;
}

+ (NSArray<NVWindowController*>*)windows {
    return neovimWindows;
}

// Lifetimes Summary
//
// The lifetimes of a NVWindowController and an nvim::process are tightly
// coupled. The controller owns the process object, but managing the lifetime
// of a process object is slightly involved. Once a successful remote
// connection is established, a nvim::process expects its lifetime to persist
// until it has shutdown cleanly. To accommodate this, we maintain an array of
// controllers that have a connected process object. When a new connection is
// made, we add the controller to the array. On shutdown, we remove the
// controller from the array. This ensures controllers, and in turn processes,
// are retained until they are safe to destroy.
//
// Having a list of connected Neovim process turns out to be useful in other
// ways too, so we expose it as part of the controller API.
//
// An NVWindowController is also retained by its NSWindow while it is being
// displayed. Once the window closes, the controller is released.

- (instancetype)init {
    NSWindow *window = [[NVWindow alloc] init];
    [window setDelegate:self];
    [window setWindowController:self];
    [window setTabbingMode:NSWindowTabbingModeDisallowed];
    [window registerForDraggedTypes:[NSArray arrayWithObject:NSPasteboardTypeFileURL]];

    [window setStyleMask:NSWindowStyleMaskTitled              |
                         NSWindowStyleMaskClosable            |
                         NSWindowStyleMaskMiniaturizable      |
                         NSWindowStyleMaskFullSizeContentView |
                         NSWindowStyleMaskResizable];

    titlebarAppearsTransparent = [NVPreferences titlebarAppearsTransparent];
    window.titlebarAppearsTransparent = titlebarAppearsTransparent;

    self = [super initWithWindow:window];
    nvim.set_controller((__bridge void*)self);

    colorScheme = [NVColorScheme defaultColorSchemeForAppearance:window.effectiveAppearance];

    [NSDistributedNotificationCenter.defaultCenter addObserver:self
                                                      selector:@selector(systemAppearanceChanged:)
                                                          name:@"AppleInterfaceThemeChangedNotification"
                                                        object:nil];

    titlebarView = [[NSView alloc] init];
    titlebarView.wantsLayer = YES;
    titlebarView.layer.backgroundColor = colorScheme.titleBarColor.CGColor;

    uiOptions = {
        .ext_cmdline    = false,
        .ext_hlstate    = false,
        .ext_linegrid   = true,
        .ext_messages   = false,
        .ext_multigrid  = false,
        .ext_popupmenu  = false,
        .ext_tabline    = (bool)[NVPreferences externalizeTabline],
        .ext_termcolors = false
    };

    if (uiOptions.ext_tabline) {
        tabs = [NSMutableArray arrayWithCapacity:32];
        tabLine = [[NVTabLine alloc] initWithFrame:titlebarView.bounds delegate:self colorScheme:colorScheme];
        tabLine.translatesAutoresizingMaskIntoConstraints = NO;
    }

    return self;
}

- (instancetype)initWithContextManager:(NVRenderContextManager *)contextManager {
    self = [self init];
    self->contextManager = contextManager;
    self->fontManager = contextManager.fontManager;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedFrameString = [defaults valueForKey:@"NVWindowControllerFrameSave"];

    if (savedFrameString) {
        NSRect frame = NSRectFromString(savedFrameString);
        lastGridSize.width = std::max(MIN_GRID_WIDTH, (int32_t)frame.size.width);
        lastGridSize.height = std::max(MIN_GRID_HEIGHT, (int32_t)frame.size.height);
        [self.window setFrameTopLeftPoint:frame.origin];
    } else {
        lastGridSize.width = 80;
        lastGridSize.height = 24;
        shouldCenter = YES;
    }

    return self;
}

- (instancetype)initWithNVWindowController:(NVWindowController *)controller {
    self = [self init];

    contextManager = controller->contextManager;
    fontManager = controller->fontManager;
    lastGridSize = controller->lastGridSize;

    NSWindow *window = [controller window];
    NSRect frame = [window frame];
    NSPoint topLeft = CGPointMake(frame.origin.x, frame.origin.y + frame.size.height);
    NSPoint cascadedTopLeft = [window cascadeTopLeftFromPoint:topLeft];

    [self.window setFrameTopLeftPoint:cascadedTopLeft];
    return self;
}

- (void)windowWillClose:(NSNotification *)notification {
    isOpen = NO;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    nvim.command("quitall");
    return NO;
}

- (nvim::process*)process {
    return &nvim;
}

- (void)close {
    if (isOpen) {
        [super close];
    }
}

- (void)shutdown {
    [neovimWindows removeObjectIdenticalTo:self];
}

// We save the size of the grid and the top left point of the window.
// Autosaving frames are not convenient as we need to know the grid size before
// we attach to the Neovim process. To get a grid size from a frame, we need to
// the cell size, but the cell size depends on the font, and we don't know the
// font until we've attached to the Neovim process.
- (void)saveFrame {
    if (!isOpen) {
        return;
    }

    NSRect rect = [self.window frame];
    rect.origin.y += rect.size.height;
    rect.size.width = lastGridSize.width;
    rect.size.height = lastGridSize.height;

    NSString *stringRect = NSStringFromRect(rect);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setValue:stringRect forKey:@"NVWindowControllerFrameSave"];
}

/// Resizes the window anchored at the top left point.
/// Attempts to constrain the window size to the given screen size.
- (void)resizeWindow:(NSWindow *)window inScreen:(NSScreen *)screen {
    if (!screen) {
        return;
    }

    NSRect screenRect = [screen visibleFrame];
    NSRect windowRect = [window frame];
    NSSize cellSize = [gridView cellSize];

    CGFloat borderHeight = titlebarHeightConstraint.constant;
    CGFloat maxGridHeight = floor((screenRect.size.height - borderHeight) / cellSize.height);
    CGFloat contentHeight = cellSize.height * std::min(maxGridHeight, (CGFloat)lastGridSize.height);
    CGFloat windowHeight = contentHeight + borderHeight;
    CGFloat deltaY = windowRect.size.height - windowHeight;

    windowRect.size.height = windowHeight;
    windowRect.origin.y = std::max(screenRect.origin.y, windowRect.origin.y + deltaY);

    // If we're dealing with a single screen, constrain the x axis too.
    if ([NSScreen screensHaveSeparateSpaces] || [[NSScreen screens] count] == 1) {
        CGFloat maxGridWidth = floor(screenRect.size.width / cellSize.width);
        CGFloat contentWidth = cellSize.width * std::min(maxGridWidth, (CGFloat)lastGridSize.width);
        CGFloat maxX = screenRect.origin.x + (screenRect.size.width - contentWidth);

        windowRect.size.width = contentWidth;
        windowRect.origin.x = std::min(windowRect.origin.x, maxX);
    }

    [window setFrame:windowRect display:isOpen];
}

/// Returns the minimum NVGridView frame size for the given cell size.
static inline NSSize minGridViewSize(NSSize cellSize) {
    return NSMakeSize(cellSize.width * MIN_GRID_WIDTH, cellSize.height * MIN_GRID_HEIGHT);
}

- (void)setFont:(const font_family&)font {
    [gridView setFont:font];
    NSWindow *window = [self window];
    NSSize cellSize = [gridView cellSize];

    [self resizeWindow:window inScreen:window.screen];
    [window setResizeIncrements:cellSize];
    NSSize minSize = minGridViewSize(cellSize);

    if (gridViewWidthConstraint) {
        gridViewWidthConstraint.constant = minSize.width;
    }

    if (gridViewHeightConstraint) {
        gridViewHeightConstraint.constant = minSize.height;
    }
}

/// Returns a font descriptor and font size based on the guifont option.
/// Reports errors to Neovim if the font is not found.
/// @returns A font descriptor and a font size. If none of the fonts given by
/// the guifont option exist, the font descriptor is NULL.
static std::pair<arc_ptr<CTFontDescriptorRef>, CGFloat> getFontDescriptor(nvim::process &nvim) {
    CGFloat defaultSize = [NSFont systemFontSize];
    std::string guifont = nvim.get_guifont();
    std::vector<nvim::font> fonts = nvim::parse_guifont(guifont, defaultSize);

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
        error.append(guifont);
        nvim.error_writeln(error);
    }

    return {{}, defaultSize};
}

- (void)handleScreenChanges:(NSNotification *)notification {
    assert([NSThread isMainThread]);
    NSScreen *screen = [self.window screen];

    if (!screen) {
        return;
    }

    NVRenderContext *oldContext = [gridView renderContext];
    NVRenderContext *newContext = [contextManager renderContextForScreen:screen];

    if (oldContext != newContext) {
        [gridView setRenderContext:newContext];
    }

    const font_family &oldFont = gridView.font;
    CGFloat oldScaleFactor = oldFont.scale_factor();
    CGFloat newScaleFactor = screen.backingScaleFactor;

    if (oldScaleFactor != newScaleFactor) {
        CGFloat fontSize = oldFont.unscaled_size();
        [self setFont:fontManager->get_resized(oldFont, fontSize, newScaleFactor)];
    }
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    if (isOpen) {
        [self handleScreenChanges:notification];
    }
}

- (void)initialRedraw {
    NVWindow *window = (NVWindow *)[self window];
    NSScreen *proposedScreen = [window screen];
    NSView *contentView = [window contentView];
    CGFloat scaleFactor = 1;

    if (proposedScreen) {
        scaleFactor = [proposedScreen backingScaleFactor];
        renderContext = [contextManager renderContextForScreen:proposedScreen];
    } else {
        proposedScreen = [NSScreen mainScreen];
        shouldCenter = YES;

        if (proposedScreen) {
            scaleFactor = [proposedScreen backingScaleFactor];
            renderContext = [contextManager renderContextForScreen:proposedScreen];
        } else {
            renderContext = [contextManager defaultRenderContext];
        }
    }

    const nvim::grid *grid = nvim.get_global_grid();
    auto [fontDescriptor, fontSize] = getFontDescriptor(nvim);

    if (!fontDescriptor) {
        fontDescriptor = font_manager::default_descriptor();
    }

    gridView = [[NVGridView alloc] init];
    gridView.font = fontManager->get(fontDescriptor.get(), fontSize, scaleFactor);
    gridView.grid = grid;

    lastGridSize = grid->size();
    NSSize cellSize = gridView.cellSize;

    [window makeFirstResponder:self];
    [window setAnimationBehavior:NSWindowAnimationBehaviorDocumentWindow];
    [window setResizeIncrements:cellSize];

    [contentView addSubview:titlebarView];
    [contentView addSubview:gridView];
    titlebarView.translatesAutoresizingMaskIntoConstraints = NO;
    gridView.translatesAutoresizingMaskIntoConstraints = NO;

    NSSize minGridSize = minGridViewSize(cellSize);
    gridViewWidthConstraint = [gridView.widthAnchor constraintGreaterThanOrEqualToConstant:minGridSize.width];
    gridViewHeightConstraint = [gridView.heightAnchor constraintGreaterThanOrEqualToConstant:minGridSize.height];
    titlebarHeightConstraint = [titlebarView.heightAnchor constraintEqualToConstant:window.titlebarHeight];

    [NSLayoutConstraint activateConstraints:@[
        [titlebarView.topAnchor constraintEqualToAnchor:contentView.topAnchor],
        [titlebarView.leftAnchor constraintEqualToAnchor:contentView.leftAnchor],
        [titlebarView.rightAnchor constraintEqualToAnchor:contentView.rightAnchor],
        titlebarHeightConstraint,

        [gridView.topAnchor constraintEqualToAnchor:titlebarView.bottomAnchor],
        [gridView.leftAnchor constraintEqualToAnchor:contentView.leftAnchor],
        [gridView.widthAnchor constraintEqualToAnchor:contentView.widthAnchor],
        [gridView.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor],
        gridViewWidthConstraint,
        gridViewHeightConstraint,
    ]];

    [self titleDidChange];
    [self optionShowTabLineDidChange];
    [self resizeWindow:window inScreen:proposedScreen];

    if (shouldCenter) {
        [window center];
    }

    // It's possible we ended up on a different screen after we resized the
    // window. If we have, handle that screen change here.
    if ([window screen] == proposedScreen) {
        gridView.renderContext = renderContext;
    } else {
        [self handleScreenChanges:nil];
    }

    // This notification is posted when the system display settings change.
    // It is also posted when the device driving a display changes, for example,
    // when a system switches between integrated and discrete graphics. In both
    // these cases, we should treat it as a screen change. This allows us to
    // ensure we've got the right scale factor, and that we're using the
    // optimum NVRenderContext.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleScreenChanges:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];

    isOpen = YES;
    [self showWindow:nil];
    [self optionsDidChange];
}

- (void)redraw {
    const nvim::grid *grid = nvim.get_global_grid();
    nvim::grid_size gridSize = grid->size();

    [gridView setGrid:grid];

    if (gridSize != lastGridSize) {
        lastGridSize = gridSize;

        if (!isLiveResizing && gridSize != gridView.desiredGridSize) {
            NSWindow *window = [self window];
            [self resizeWindow:window inScreen:window.screen];
        }
    }
}

- (void)attach {
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC);
    nvim.ui_attach_wait(lastGridSize.width, lastGridSize.height, uiOptions, timeout);

    [neovimWindows addObject:self];
    isAlive = YES;

    [self initialRedraw];
}

- (int)connect:(NSString *)addr {
    int error = nvim.connect([addr UTF8String]);

    if (error) {
        os_log_error(rpc, "Connect error: %i: %s\n", error, strerror(error));
        return error;
    }

    [self attach];
    return 0;
}

- (int)spawnWithArgs:(const char**)argv workingDirectory:(NSString *)directory {
    NSString *nvimExecutable = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"nvim"];

    extern char **environ;
    const char *workingDir = [directory UTF8String];
    const char *path = [nvimExecutable UTF8String];

    int error = nvim.spawn(path, argv, (const char**)environ, workingDir);

    if (error) {
        os_log_error(rpc, "Spawn error: %i: %s\n", error, strerror(error));
        return error;
    }

    [self attach];
    return 0;
}

- (int)spawn {
    static const char *argv[] = {
        "nvim", "--embed", nullptr
    };

    return [self spawnWithArgs:argv workingDirectory:NSHomeDirectory()];
}

- (int)spawnOpenFile:(NSString *)filename {
    const char *argv[4] = {"nvim", "--embed", [filename UTF8String], nullptr};
    NSString *directory = [filename stringByDeletingLastPathComponent];

    return [self spawnWithArgs:argv workingDirectory:directory];
}

- (int)spawnOpenFiles:(NSArray<NSString*> *)filenames {
    if ([filenames count] == 0) {
        return [self spawn];
    }

    NSString *directory = [filenames[0] stringByDeletingLastPathComponent];
    std::vector<const char*> argv{"nvim", "--embed", "-p"};

    for (NSString *file in filenames) {
        argv.push_back([file UTF8String]);
    }

    argv.push_back(nullptr);
    return [self spawnWithArgs:argv.data() workingDirectory:directory];
}

- (int)spawnOpenURLs:(NSArray<NSURL*>*)urls {
    NSMutableArray<NSString*> *paths = [NSMutableArray arrayWithCapacity:[urls count]];

    for (NSURL *url in urls) {
        [paths addObject:[url path]];
    }

    return [self spawnOpenFiles:paths];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    [gridView setActive];
    [self saveFrame];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    [gridView setInactive];
}

- (void)windowWillStartLiveResize:(NSNotification *)notification {
    isLiveResizing += 1;
}

- (void)windowDidEndLiveResize:(NSNotification *)notification {
    // When multiple UIs are connected to Neovim, the grid size is restricted
    // to the smallest UI. It's possible we've resized our window to require
    // a grid larger than Neovim can offer. If that happens, we'll shrink the
    // window to match the grid size we've actually got.
    //
    // Give Neovim some time to update the grids then reconcile any size
    // differences. We track live resizing with an integer count rather than a
    // BOOL to handle the unlikely case where a second live resize starts before
    // we've had a chance to synchronize our grid sizes.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        self->isLiveResizing -= 1;

        if (!self->isLiveResizing) {
            NSSize currentSize = [self->gridView frame].size;
            NSSize desiredSize = [self->gridView desiredFrameSize];

            if (memcmp(&currentSize, &desiredSize, sizeof(NSSize)) != 0) {
                desiredSize.height += self->titlebarHeightConstraint.constant;
                [self.window setContentSize:desiredSize];
            }

            [self saveFrame];
        }
    });
}

- (void)windowDidMove:(NSNotification *)notification {
    [self saveFrame];
}

// In general the size of the window is authoritative, whenever it resizes, we
// resize the Neovim grid to occupy the full window.
- (void)windowDidResize:(NSNotification *)notification {
    nvim::grid_size size = [gridView desiredGridSize];

    if (!isLiveResizing) {
        [self saveFrame];

        if (lastGridSize == size) {
            return;
        }
    }

    nvim.try_resize(size.width, size.height);
}

/// Converts NSEventModifierFlags to Vim notation key modifier strings.
/// For example: NSEventModifierFlagShift is converted to S-.
class input_modifiers {
private:
    char buffer[8];
    size_t length;

    void push_back(char value) {
        const char data[2] = {value, '-'};
        memcpy(buffer + length, data, 2);
        length += 2;
    }

public:
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

static void namedKeyDown(nvim::process &nvim, NSEventModifierFlags flags, std::string_view keyname) {
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

static void keyDownIgnoreModifiers(nvim::process &nvim, NSEventModifierFlags flags, NSEvent *event) {
    NSString *nscharacters = [event charactersIgnoringModifiers];
    const char *characters = [nscharacters UTF8String];
    NSUInteger charlength = [nscharacters lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

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

static constexpr auto CellNotFound = nvim::grid_point{INT32_MAX, INT32_MAX};

static inline bool pointInGrid(nvim::grid_point point, nvim::grid_size size) {
    return point.row >= 0 && point.row < size.height &&
           point.column >= 0 && point.column < size.width;
}

- (void)mouseDown:(NSEvent *)event button:(MouseButton)button {
    nvim::grid_point location = [gridView cellLocation:event.locationInWindow];

    if (!pointInGrid(location, lastGridSize)) {
        lastMouseLocation[button] = CellNotFound;
        return;
    }

    lastMouseLocation[button] = location;
    input_modifiers modifiers = input_modifiers(event.modifierFlags);
    nvim.input_mouse(buttonName(button), "press", modifiers, location.row, location.column);
}

- (void)mouseDragged:(NSEvent *)event button:(MouseButton)button {
    if (lastMouseLocation[button] == CellNotFound) {
        return;
    }

    NSPoint windowLocation = [event locationInWindow];
    nvim::grid_point location = [gridView cellLocation:windowLocation clampTo:lastGridSize];
    nvim::grid_point &lastLocation = lastMouseLocation[button];

    if (location != lastLocation) {
        input_modifiers modifiers = input_modifiers(event.modifierFlags);
        nvim.input_mouse(buttonName(button), "drag", modifiers, location.row, location.column);
        lastLocation = location;
    }
}

- (void)mouseUp:(NSEvent *)event button:(MouseButton)button {
    if (lastMouseLocation[button] == CellNotFound) {
        return;
    }

    NSPoint windowLocation = [event locationInWindow];
    nvim::grid_point location = [gridView cellLocation:windowLocation clampTo:lastGridSize];

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

static void scrollEvent(nvim::process &nvim, size_t count, std::string_view direction,
                        std::string_view modifiers, nvim::grid_point location) {
    for (size_t i=0; i<count; ++i) {
        nvim.input_mouse("wheel", direction, modifiers, location.row, location.column);
    }
}

- (void)scrollWheel:(NSEvent *)event {
    NSEventModifierFlags modifierFlags = [event modifierFlags];
    CGFloat deltaX = [event scrollingDeltaX];
    CGFloat deltaY = [event scrollingDeltaY];

    nvim::grid_point location = [gridView cellLocation:event.locationInWindow];

    if (!pointInGrid(location, lastGridSize)) {
        return;
    }

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
    } else {
        // We're dealing with an actual scroll wheel, i.e. not a trackpad.
        // Holding shift is used to change the scroll direction, ignore it.
        modifierFlags = modifierFlags & ~NSEventModifierFlagShift;

        if (deltaY > 0) {
            deltaY = 1;
        } else if (deltaY < 0) {
            deltaY = -1;
        }

        if (deltaX > 0) {
            deltaX = 1;
        } else if (deltaX < 0) {
            deltaX = -1;
        }
    }

    input_modifiers modifiers = input_modifiers(modifierFlags);

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

- (IBAction)newDocument:(id)sender {
    [[[NVWindowController alloc] initWithNVWindowController:self] spawn];
}

- (void)normalCommand:(std::string_view)command {
    nvim::mode mode = nvim.get_mode();

    if (is_busy(mode) || is_ex_mode(mode) || is_prompt(mode)) {
        if (mode == nvim::mode::cancelled && isOpen) {
            [self.window close];
        } else {
            return NSBeep();
        }
    }

    if (mode != nvim::mode::normal) {
        nvim.feedkeys(CTRL_BACKSLASH CTRL_N);
    }

    nvim.command(command);
}

static std::vector<std::string_view> URLPaths(NSArray<NSURL*> *urls) {
    std::vector<std::string_view> paths;
    paths.reserve([urls count]);

    for (NSURL *url in urls) {
        paths.push_back([[url path] UTF8String]);
    }

    return paths;
}

- (IBAction)openDocument:(id)sender {
    nvim::mode mode = nvim.get_mode();

    if (is_busy(mode) || is_ex_mode(mode) || is_prompt(mode)) {
        return NSBeep();
    }

    if (mode != nvim::mode::normal) {
        nvim.feedkeys(CTRL_BACKSLASH CTRL_N);
    }

    NSOpenPanel *panel = [[NSOpenPanel alloc] init];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;

    NSModalResponse response = [panel runModal];

    if (response != NSModalResponseOK) {
        return;
    }

    nvim.open_tabs(URLPaths([panel URLs]));
}

- (void)openTabs:(const std::vector<std::string_view> *)paths {
    nvim.open_tabs(*paths);
}

static inline bool canSave(nvim::process &nvim) {
    nvim::mode mode = nvim.get_mode();

    if (is_busy(mode) || is_prompt(mode) || is_ex_mode(mode) || is_terminal_mode(mode)) {
        return false;
    }

    if (is_command_line_mode(mode) || is_operator_pending(mode)) {
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

- (void)forceQuit {
    [self normalCommand:"quitall!"];
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

// Keyboard shortcuts are designed to mimic MacVim, which in turn attempts to
// provide a native macOS experience. We query Neovim for the current mode and
// react accordingly. This is inherently racey, the Neovim mode could change
// before we get chance to react, but it's the best we've got. Things aren't as
// dire as they seem, we're usually controlling Neovim's inputs, so the only
// way the mode will change from under us is due to timers or other remote
// clients. Both of which seem pretty rare.
//
// A note on why we're not using key mappings:
// We could implement keyboard shortcuts as regular mappings, perhaps that
// would've been easier. There's two main reasons that we didn't:
//
// 1. Users can change silently change mappings. For example, a user / plugin
//    could change the cmd-A mapping, then our "select all" implementation would
//    stop working.
//
// 2. Eventually we want to allow users to alter / disable the standard keyboard
//    shortcuts via our preferences UI, that would be much harder to accomplish
//    with key mappings.
- (IBAction)selectAll:(id)sender {
    nvim::mode mode = nvim.get_mode();

    switch (mode) {
        case nvim::mode::normal:
            return nvim.feedkeys("ggVG");

        case nvim::mode::command_line:
        case nvim::mode::operator_pending:
        case nvim::mode::operator_pending_forced_char:
        case nvim::mode::operator_pending_forced_line:
        case nvim::mode::operator_pending_forced_block:
        case nvim::mode::visual_block:
        case nvim::mode::visual_char:
        case nvim::mode::visual_line:
            return nvim.feedkeys(CTRL_C "ggVG");

        case nvim::mode::normal_ctrli_insert:
        case nvim::mode::normal_ctrli_replace:
        case nvim::mode::normal_ctrli_virtual_replace:
            return nvim.feedkeys("gg" CTRL_O "VG");

        case nvim::mode::insert:
        case nvim::mode::insert_completion:
        case nvim::mode::insert_completion_ctrlx:
        case nvim::mode::replace:
        case nvim::mode::replace_completion:
        case nvim::mode::replace_completion_ctrlx:
        case nvim::mode::replace_virtual:
            return nvim.feedkeys(CTRL_O "gg" CTRL_O "VG");

        case nvim::mode::select_block:
        case nvim::mode::select_line:
        case nvim::mode::select_char:
            return nvim.feedkeys(CTRL_C "gggH" CTRL_O "G");

        default:
            return NSBeep();
    }
}

- (IBAction)cut:(id)sender {
    nvim::mode mode = nvim.get_mode();

    if (is_visual_mode(mode)) {
        nvim.feedkeys("\"+x");
    } else if (is_select_mode(mode)) {
        nvim.feedkeys(CTRL_O "\"+x");
    } else {
        NSBeep();
    }
}

- (IBAction)copy:(id)sender {
    nvim::mode mode = nvim.get_mode();

    if (is_visual_mode(mode)) {
        nvim.feedkeys("\"+y");
    } else if (is_select_mode(mode)) {
        nvim.feedkeys(CTRL_O "\"+ygv" CTRL_G);
    } else {
        NSBeep();
    }
}

- (IBAction)paste:(id)sender {
    nvim::mode mode = nvim.get_mode();

    if (is_normal_mode(mode)) {
        nvim.feedkeys("\"+gP");
    } else if (is_visual_mode(mode)) {
        nvim.feedkeys("\"_dP");
    } else if (is_insert_mode(mode) || is_replace_mode(mode)) {
        nvim.feedkeys(CTRL_O "\"+gP");
    } else if (is_select_mode(mode)) {
        nvim.feedkeys(CTRL_O "\"_dP");
    } else if (is_operator_pending(mode)) {
        nvim.feedkeys(CTRL_C "\"+gP");
    } else if (is_command_line_mode(mode)) {
        nvim.feedkeys(CTRL_R "+");
    } else if (is_terminal_mode(mode)) {
        nvim.feedkeys(CTRL_W "\"+");
    } else {
        NSBeep();
    }
}

- (IBAction)undo:(id)sender {
    nvim::mode mode = nvim.get_mode();

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
    nvim::mode mode = nvim.get_mode();

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

- (void)performZoom:(CGFloat)delta {
    const font_family &font = [gridView font];
    CGFloat size = font.unscaled_size() + delta;

    if (size > 72 || size < 6) {
        return NSBeep();
    }

    CGFloat scaleFactor = [self.window backingScaleFactor];
    [self setFont:fontManager->get_resized(font, size, scaleFactor)];
}

- (IBAction)zoomIn:(id)sender {
    [self performZoom:1];
}

- (IBAction)zoomOut:(id)sender {
    [self performZoom:-1];
}

static std::string joinURLs(NSArray<NSURL*> *urls, char delim) {
    std::string string;
    string.reserve(1024);

    for (NSURL *url in urls) {
        string.append([[url path] UTF8String]);
        string.push_back(delim);
    }

    return string;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return NSDragOperationCopy;
}

// MacVim opens files when they're drag and dropped into the window, the usual
// behavior on macOS is to paste the file path. We diverge with MacVim here and
// paste the path. This could be user configurable in the future.
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pasteboard = [sender draggingPasteboard];
    NSArray<NSURL*> *urls = [pasteboard readObjectsForClasses:@[[NSURL class]] options:nil];

    if (![urls count]) {
        return NO;
    }

    nvim::mode mode = nvim.get_mode();

    if (is_busy(mode) || is_prompt(mode)) {
        return NO;
    }

    if (is_terminal_mode(mode) || is_command_line_mode(mode) || is_ex_mode(mode)) {
        std::string filenames = joinURLs(urls, ' ');
        nvim.paste(std::string_view(filenames.data(), filenames.size() - 1));
        return YES;
    }

    if (mode != nvim::mode::normal) {
        nvim.feedkeys(CTRL_BACKSLASH CTRL_N);
    }

    nvim.drop_text(URLPaths(urls));
    return YES;
}

- (void)titleDidChange {
    NSString *title = NSStringFromStringView(nvim.get_title());
    [[self window] setTitle:title];
}

- (void)fontDidChange {
    if (isOpen) {
        auto [fontDescriptor, fontSize] = getFontDescriptor(nvim);

        if (fontDescriptor) {
            CGFloat scaleFactor = [self.window backingScaleFactor];
            [self setFont:fontManager->get(fontDescriptor.get(), fontSize, scaleFactor)];
        }
    }
}

- (void)optionsDidChange {
    nvim::ui_options opts = nvim.get_ui_options();

    if (opts != uiOptions) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"Unexpected UI options";
        alert.informativeText = @"Neovim is currently using unsupported UI options. "
                                 "This may cause rendering defects.";

        if (isOpen) {
            [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse){}];
        } else {
            [alert runModal];
        }
    }
}

static inline NSString* NSStringFromStringView(std::string_view string) {
    return [[NSString alloc] initWithBytes:string.data()
                                    length:string.size()
                                  encoding:NSUTF8StringEncoding];
}

- (void)showTabLine {
    if (!uiOptions.ext_tabline || tabLine.isShown) {
        return;
    }

    NVWindow *window = (NVWindow *)[self window];

    CGFloat currentTitleBarHeight = window.titlebarHeight;
    CGFloat titleBarHeightDelta = 42 - currentTitleBarHeight;

    [window setTitlebarHeight:42];
    [window setTitleVisibility:NSWindowTitleHidden];
    [window setTitlebarAppearsTransparent:YES];
    [window setMovable:NO];

    titlebarHeightConstraint.constant = 42;
    [titlebarView addSubview:tabLine];

    [NSLayoutConstraint activateConstraints:@[
        [tabLine.topAnchor constraintEqualToAnchor:titlebarView.topAnchor],
        [tabLine.bottomAnchor constraintEqualToAnchor:titlebarView.bottomAnchor],
        [tabLine.leftAnchor constraintEqualToAnchor:titlebarView.leftAnchor],
        [tabLine.rightAnchor constraintEqualToAnchor:titlebarView.rightAnchor]
    ]];

    NSRect windowFrame = [window frame];
    windowFrame.size.height += titleBarHeightDelta;
    windowFrame.origin.y -= titleBarHeightDelta;

    tabLine.isShown = YES;
    tabLine.needsLayout = YES;

    [window setFrame:windowFrame display:YES animate:YES];
}

- (void)hideTabLine {
    if (!tabLine.isShown) {
        return;
    }

    NVWindow *window = (NVWindow *)[self window];

    [window setTitlebarHeight:NVWindowSystemTitleBarHeight];
    [window setTitleVisibility:NSWindowTitleVisible];
    [window setTitlebarAppearsTransparent:titlebarAppearsTransparent];
    [window setMovable:YES];

    CGFloat newTitleBarHeight = window.titlebarHeight;
    CGFloat titleBarHeightDelta = newTitleBarHeight - 42;

    titlebarHeightConstraint.constant = newTitleBarHeight;

    [tabLine cancelAllAnimations];
    [tabLine removeFromSuperview];
    [tabLine setIsShown:NO];

    NSRect windowFrame = [window frame];
    windowFrame.size.height += titleBarHeightDelta;
    windowFrame.origin.y -= titleBarHeightDelta;

    [window setFrame:windowFrame display:YES animate:YES];
}


static inline bool shouldShowTabLine(size_t tabsCount, nvim::showtabline showtabline) {
    switch (showtabline) {
        case nvim::showtabline::never:
            return false;

        case nvim::showtabline::if_multiple:
            return tabsCount > 1;

        case nvim::showtabline::always:
            return true;
    }
}

- (void)optionShowTabLineDidChange {
    if (!uiOptions.ext_tabline) {
        return;
    }

    showTabLineOption = nvim.get_showtabline();

    if (shouldShowTabLine(tabs.count, showTabLineOption)) {
        [self showTabLine];
    } else {
        [self hideTabLine];
    }
}

- (void)tabLineUpdate {
    if (!uiOptions.ext_tabline) {
        return;
    }

    std::lock_guard<unfair_lock> lg(nvim.get_tab_lock());

    auto tabpages = nvim.get_tabs();
    auto selected = nvim.get_selected_tab();
    auto tabCount = tabpages.size();

    bool shownAtStart = tabLine.isShown;
    bool shownAtEnd = shouldShowTabLine(tabCount, showTabLineOption);
    bool shouldAnimate = shownAtStart && shownAtEnd;

    if (shownAtStart && !shownAtEnd) {
        [self hideTabLine];
    }

    for (NVTab *tab in tabs) {
        auto *tabpage = static_cast<nvim::tabpage*>(tab.tabpage);

        if (tabpage->closed) {
            nvim.free_tabpage(tabpage);

            if (shouldAnimate) {
                [tabLine animateCloseTab:tab];
            } else {
                [tabLine closeTab:tab];
            }
        } else {
            if (tabpage->name_changed) {
                tabpage->name_changed = false;
                tab.title = NSStringFromStringView(tabpage->name);
            }

            if (tabpage->filetype_changed) {
                tabpage->filetype_changed = false;
                tab.filetype = NSStringFromStringView(tabpage->filetype);
            }
        }
    }

    [tabs removeAllObjects];

    for (size_t index=0; index<tabCount; ++index) {
        auto tabpage = tabpages[index];
        NVTab *tab = (__bridge NVTab*)tabpage->nvtab;

        if (!tab) {
            NSString *title = NSStringFromStringView(tabpage->name);
            NSString *filetype = NSStringFromStringView(tabpage->filetype);
            tab = [[NVTab alloc] initWithTitle:title filetype:filetype tabpage:tabpage tabLine:tabLine];
            tabpage->nvtab = (__bridge void*)tab;

            if (shouldAnimate) {
                [tabLine animateAddTab:tab atIndex:index isSelected:tabpage == selected];
            }
        }

        [tabs addObject:tab];
    }

    if (shouldAnimate) {
        [tabLine animateSetTabs:tabs selectedTab:(__bridge NVTab*)selected->nvtab];
    } else {
        [tabLine setTabs:tabs];
        [tabLine setSelectedTab:(__bridge NVTab*)selected->nvtab];
    }

    if (!shownAtStart && shownAtEnd) {
        [self showTabLine];
    }
}

- (void)tabLineAddNewTab:(NVTabLine *)tabLine {
    [self normalCommand:"tabnew"];
}

- (void)tabLine:(NVTabLine *)tabLine closeTab:(NVTab *)tab {
    if (tabs.count == 1) {
        return [self normalCommand:"quit"];
    }

    auto tabpage = static_cast<nvim::tabpage*>(tab.tabpage);

    std::string command;
    command.reserve(256);
    command.append("execute \"tabclose \" . nvim_tabpage_get_number(");
    command.append(std::to_string(tabpage->handle));
    command.push_back(')');

    [self normalCommand:command];
}

- (BOOL)tabLine:(NVTabLine *)tabLine shouldSelectTab:(NVTab *)tab {
    nvim::mode mode = nvim.get_mode();

    if (is_busy(mode) || is_ex_mode(mode) || is_prompt(mode)) {
        return NO;
    }

    if (mode != nvim::mode::normal) {
        nvim.feedkeys(CTRL_BACKSLASH CTRL_N);
    }

    auto tabpage = static_cast<nvim::tabpage*>(tab.tabpage);

    std::string command;
    command.reserve(256);
    command.append("execute \"tabnext \" . nvim_tabpage_get_number(");
    command.append(std::to_string(tabpage->handle));
    command.push_back(')');

    auto response = nvim.sync_command(command, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
    return !response.timed_out && response.error.is<msg::null>();
}

- (void)tabLine:(NVTabLine *)tabLine didMoveTab:(NVTab *)tab fromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex {
    if (fromIndex == toIndex) {
        return;
    }

    std::string command;
    command.reserve(256);
    command.append("tabmove ");
    command.append(std::to_string(fromIndex > toIndex ? toIndex : toIndex + 1));

    [self normalCommand:command];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self tabLineUpdate];
    });
}

- (void)colorschemeUpdate {
    nvim::colorscheme nvimColorScheme = nvim.get_colorscheme();
    NSWindow *window = self.window;
    NSAppearance *appearance;

    if (nvimColorScheme.appearance == nvim::appearance::light) {
        appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        window.appearance = appearance;
    } else if (nvimColorScheme.appearance == nvim::appearance::dark) {
        appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        window.appearance = appearance;
    } else {
        appearance = [NSApp effectiveAppearance];
    }

    colorScheme = [[NVColorScheme alloc] initWithColorScheme:&nvimColorScheme appearance:appearance];
    titlebarView.layer.backgroundColor = colorScheme.titleBarColor.CGColor;
    tabLine.colorScheme = colorScheme;
}

- (void)systemAppearanceChanged:(NSNotification *)notifcation {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self colorschemeUpdate];
    });
}

@end

// nvim::window_controller implementation. Declared in ui.hpp.
// We forward the messages and ensure they execute in the main thread.
namespace nvim {

void window_controller::close() {
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context close];
    });
}

void window_controller::shutdown() {
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context shutdown];
    });
}

void window_controller::redraw() {
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context redraw];
    });
}

void window_controller::title_set() {
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context titleDidChange];
    });
}

void window_controller::font_set() {
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context fontDidChange];
    });
}

void window_controller::options_set() {
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context optionsDidChange];
    });
}

void window_controller::showtabline_set() {
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context optionShowTabLineDidChange];
    });
}

void window_controller::tabline_update() {
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context tabLineUpdate];
    });
}

void window_controller::colorscheme_update() {
    dispatch_async_f(dispatch_get_main_queue(), controller, [](void *context) {
        [(__bridge NVWindowController*)context colorschemeUpdate];
    });
}

} // namespace nvim
