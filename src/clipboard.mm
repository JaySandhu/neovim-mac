//
//  Neovim Mac
//  clipboard.mm
//
//  Copyright © 2023 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Cocoa/Cocoa.h>

#include "log.h"
#include "clipboard.hpp"

namespace {

// Pasteboard type and register type constants are shared with Vim to preserve
// copying and pasting compatibility. Do not change!
NSString * const NVimPasteboardType = @"VimPboardType";

enum class register_type {
    character = 0,
    line = 1,
    block = 2,
    unknown = -1
};

register_type to_register_type(msg::string regtype) {
    if (regtype.empty()) {
        return register_type::unknown;
    }

    switch (regtype[0]) {
        case 'c':
        case 'v':
            return register_type::character;

        case 'l':
        case 'V':
            return register_type::line;

        case 'b':
        case 0x16: // CTRL-V
            return register_type::block;

        default:
            return register_type::unknown;
    }
}

msg::string to_register_string(register_type regtype) {
    switch (regtype) {
        case register_type::character:
            return "c";

        case register_type::line:
            return "l";

        case register_type::block:
            return "b";

        default:
            return "";
    }
}

clipboard_data make_clipboard_data(register_type regtype, NSString *string) {
    NSCharacterSet *newLines = [NSCharacterSet newlineCharacterSet];
    NSArray *nsLines = [string componentsSeparatedByCharactersInSet:newLines];

    std::vector<std::string> lines;
    lines.reserve([nsLines count]);

    for (NSString *line in nsLines) {
        lines.emplace_back([line UTF8String]);
    }

    return clipboard_data(std::move(lines), to_register_string(regtype));
}

clipboard_data autoreleased_clipboard_get() {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSArray *supportedTypes = @[NVimPasteboardType, NSPasteboardTypeString];

    NSString *available = [pasteboard availableTypeFromArray:supportedTypes];

    if ([available isEqual:NVimPasteboardType]) {
        // This should be an array with two objects:
        //   1. Register type (NSNumber)
        //   2. Text (NSString)
        //
        // If this is not the case we fall back on using NSPasteboardTypeString.
        NSArray *plist = [pasteboard propertyListForType:NVimPasteboardType];

        if ([plist isKindOfClass:[NSArray class]] && [plist count] == 2 &&
            [plist[0] isKindOfClass:[NSNumber class]] &&
            [plist[1] isKindOfClass:[NSString class]]) {
            auto regtype = static_cast<register_type>((int)[plist[0] intValue]);
            return make_clipboard_data(regtype, plist[1]);
        }
    }

    NSString *string = [pasteboard stringForType:NSPasteboardTypeString];

    if (!string) {
        return clipboard_data();
    }

    return make_clipboard_data(register_type::unknown, string);
}

void autoreleased_clipboard_set(msg::array lines, msg::string regstring) {
    std::string buffer;
    buffer.reserve(lines.size() * 128);

    for (auto object : lines) {
        msg::string line = object.get<msg::string>();
        buffer.append(line.data(), line.size());
        buffer.push_back('\n');
    }

    size_t length = std::max(buffer.length(), 1ul) - 1;
    NSString *string = [[NSString alloc] initWithBytes:buffer.data()
                                                length:length
                                              encoding:NSUTF8StringEncoding];

    register_type regtype = to_register_type(regstring);
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSArray *supportedTypes = @[NVimPasteboardType, NSPasteboardTypeString];
    NSArray *plist = @[[NSNumber numberWithInt:(int)regtype], string];

    [pasteboard declareTypes:supportedTypes owner:nil];
    [pasteboard setPropertyList:plist forType:NVimPasteboardType];
    [pasteboard setString:string forType:NSPasteboardTypeString];
}

bool type_check_args(msg::array args) {
    return args.size() == 2 &&
           args[0].is<msg::array>() &&
           args[1].is<msg::string>();
}

bool type_check_lines(msg::array lines) {
    for (msg::object line : lines) {
        if (!line.is<msg::string>()) {
            return false;
        }
    }

    return true;
}

} // internal

clipboard_data clipboard_get() {
    @autoreleasepool {
        return autoreleased_clipboard_get();
    }
}

void clipboard_set(msg::array args) {
    if (type_check_args(args)) {
        msg::array lines = args[0].get<msg::array>();
        msg::string regtype = args[1].get<msg::string>();

        if (type_check_lines(lines)) {
            @autoreleasepool {
                return autoreleased_clipboard_set(lines, regtype);
            }
        }
    }

    return os_log_info(rpc, "Clipboard set type error - Args=%s",
                       msg::to_string(args).c_str());
}
