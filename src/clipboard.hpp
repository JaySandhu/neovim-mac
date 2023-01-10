//
//  Neovim Mac
//  clipboard.hpp
//
//  Copyright © 2023 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#ifndef CLIPBOARD_HPP
#define CLIPBOARD_HPP

#include <string>
#include <tuple>
#include <vector>

#include "msgpack.hpp"

/// System Clipboard Integration
///
/// These functions are called via RPC requests from the embedded Neovim
/// process. They set / get the contents of the system clipboard in a way that
/// preserves the register type for other Neovim and Vim processes (required
/// for block pasting to work correctly).
///
/// They replace the usual macOS clipboard providers (pbcopy, pbpaste), which
/// do not handle block pasting correctly.
///
/// See :help clipboard for more.

/// Clipboard data
///
/// A tuple of:
///   1. An array of lines.
///   2. A string representing the register type.
using clipboard_data = std::tuple<std::vector<std::string>, msg::string>;

/// Sets the system clipboard.
///
/// @param args The arguments to the RPC request, where:
///             - args[0] is an array of lines.
///             - args[1] is the register type.
///
/// If the args array is malformed the clipboard is not set.
void clipboard_set(msg::array args);

/// Get the contents of the system clipboard.
/// @returns A clipboard_data object.
clipboard_data clipboard_get();

#endif // CLIPBOARD_HPP
