<img align="left" src="https://i.postimg.cc/XNcvqZp4/icon-128x128.png">

# Neovim for macOS

A fast, minimal, Neovim GUI for macOS.

## Features
 * Fast Metal based renderer.
 * Externalized Chrome style tab bar. 
 * Native clipboard support.
 * Native macOS keyboard shortcuts and behavior.

## Roadmap
 - [x] Externalized tab bar.
 - [ ] Externalized popup menu.
 - [ ] Input handling for non latin alphabets.
 - [ ] Ligature support.

## Screenshots
![screenshot 1](https://i.postimg.cc/L8vwLJh2/screenshot-dark.png)
![screenshot 2](https://i.postimg.cc/4NgS069X/screenshot-dark-tabs.png)
![screenshot 3](https://i.postimg.cc/hv6PSCWZ/screenshot-light.png)
![screenshot 4](https://i.postimg.cc/BQz16gB0/screenshot-light-tabs.png)

## Color Scheme Support 

Neovim for macOS comes with a light and dark theme. By default, a theme
will be chosen in accordance to your system appearance settings. The colors of
GUI elements can be further customized via the `neovim_mac#Colorscheme()`
function. The function accepts a dictionary with the following key / value
pairs:

| Key                    | Value                                                                       |
| ---------------------- | --------------------------------------------------------------------------- |
| `appearance`           | `"light"` or `"dark"`, sets default theme and sets window title color       |
| `titlebar`             | Window title bar color                                                      |
| `tab_background`       | Unselected tabs background color                                            | 
| `tab_selected`         | Selected tab background color                                               | 
| `tab_hover`            | Tab background color on mouse over                                          | 
| `tab_title`            | Tab title color                                                             | 
| `tab_separator`        | Tab separator color                                                         | 
| `tab_button`           | Tab button foreground color (close tab, add tab buttons)                    | 
| `tab_button_hover`     | Tab button background color on mouse over                                   | 
| `tab_button_highlight` | Tab button background color on mouse click                                  | 

Colors should be in the format `#rrggbb`. Where `xx` is a hexadecimal number
between `00` and `ff`. Alpha values are not supported. The `#` sign is required.

**Example**

To set the selected tab color to red:
```
:call neovim_mac#Colorscheme({"tab_selected" : "#ff0000"})
```

## Building from Source
Neovim for macOS uses a forked version of
[Neovim](https://github.com/JaySandhu/neovim/tree/release-0.4-patched) which adds:
 * Native clipboard support (https://github.com/neovim/neovim/pull/12452).
 * ~~A mousescroll option~~ (https://github.com/neovim/neovim/pull/12355 - Merged).
 * ~~Scrolling fixes~~ (https://github.com/neovim/neovim/pull/12356 - Merged).

Hopefully these changes will eventually be accepted into Neovim. Until then,
we'll need to build our modified version from source, so before we begin, ensure you have the
[build prerequisites](https://github.com/neovim/neovim/wiki/Building-Neovim#build-prerequisites).
After that, building is as simple as:

```
git clone https://github.com/JaySandhu/neovim-mac.git
cd neovim-mac
./build_nvim.sh
xcodebuild -configuration Release -arch {x86_64 or arm64}
```

If everything went as planned, you'll find Neovim.app in build/release.

## Credits
 * https://github.com/vim - For Vim.
 * https://github.com/neovim - For Neovim.
 * https://github.com/jasonlong - For the Neovim logo.

## License

[![License](http://img.shields.io/:license-mit-blue.svg?style=flat-square)](http://badges.mit-license.org)

 * [MIT License](https://mit-license.org/).
 * Copyright 2020 © Jay Sandhu.

