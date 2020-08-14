<img align="left" src="https://i.postimg.cc/5t3x3nhw/icon-128x128.png">

# Neovim for macOS

A fast minimal Neovim GUI for macOS.

## Features
 * Fast Metal based renderer.
 * Native clipboard support.
 * Native macOS keyboard shortcuts and behavior.

## Screenshots
![screenshot 1](https://i.postimg.cc/5N8LJQD6/Screen-Shot-2020-08-14-at-19-00-21.png)
![screenshot 2](https://i.postimg.cc/g2dR2kP4/Screen-Shot-2020-08-14-at-19-01-20.png)

## Roadmap
 * Externalized tab bar.
 * Externalized popup menu.
 * Proper input method handling.
 * Ligature support.

## Building from Source
Neovim for macOS uses a forked version of
[Neovim](https://github.com/JaySandhu/neovim/tree/release-0.4-patched) which adds:
 * Native clipboard support (https://github.com/neovim/neovim/pull/12452).
 * A mousescroll option (https://github.com/neovim/neovim/pull/12355).
 * Scrolling fixes (https://github.com/neovim/neovim/pull/12356).

We'll also be building our modified version of Neovim, so before we begin, ensure you have the
[build perquisites](https://github.com/neovim/neovim/wiki/Building-Neovim#build-prerequisites).
Building is as simple as:

```
git clone https://github.com/JaySandhu/neovim-mac.git
cd neovim-mac
./build_nvim.sh
xcodebuild -configuration Release
```

If everything went as planned, you'll find Neovim.app in build/release.

## Credits
 * https://github.com/vim - For Vim.
 * https://github.com/neovim - For Neovim.
 * https://github.com/jasonlong - For the Neovim logo.

## License

[![License](http://img.shields.io/:license-mit-blue.svg?style=flat-square)](http://badges.mit-license.org)

 * [MIT License](https://mit-license.org/)
 * Copyright 2020 © Jay Sandhu.

