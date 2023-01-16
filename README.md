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
1. Clone the repository and change working directories.

```
git clone https://github.com/JaySandhu/neovim-mac.git
cd neovim-mac
```

2. Build or download Neovim. 

To build Neovim from source, ensure you have the required 
[build dependencies](https://github.com/neovim/neovim/wiki/Building-Neovim#macos),
then run the build script: 

```
./build_nvim.sh {release_tag}
```

Alternatively, you can download a pre-built Neovim release:

```
./download_nvim.sh {release_tag}
```

Both the build script and the download script accept an optional [release
tag](https://github.com/neovim/neovim/tags) argument (e.g. `v0.8.0`, `nightly`,
`stable`). If no release is specified, the scripts default to `stable`. Neovim
versions `v0.8.0` and newer supported.

3. Build the app.

```
xcodebuild -configuration Release
```

If everything went as planned, you'll find Neovim.app in `build/release`.

## Credits
 * https://github.com/vim - For Vim.
 * https://github.com/neovim - For Neovim.
 * https://github.com/jasonlong - For the Neovim logo.

## License
[![License](http://img.shields.io/:license-mit-blue.svg?style=flat-square)](http://badges.mit-license.org)

 * [MIT License](https://mit-license.org/).
 * Copyright 2020 © Jay Sandhu.

