#!/bin/sh
#
# Neovim Mac
# build_nvim.sh
#
# Copyright © 2020 Jay Sandhu. All rights reserved.
# This file is distributed under the MIT License.
# See LICENSE.txt for details.
#
# ------------------------------------------------------------------------------
#
# Neovim Build Script
#
# Syntax: download_nvim.sh {tag}
# Where tag is a Neovim release tag. If no tag is provided defaults to stable.
#
# Build Prerequisites:
# https://github.com/neovim/neovim/wiki/Building-Neovim#macos
#
# Builds Neovim and its dependencies in build/neovim. Installs in build/nvim.
#
# Install Directory Structure:
#   build/nvim/bin
#   build/nvim/lib
#   build/nvim/share

set -e

pushd "$(dirname "$0")"
mkdir -p build
cd build

if [ ! -d "neovim" ]; then
    git clone --depth 1 --branch ${1-"stable"} "https://github.com/neovim/neovim.git"
fi

cd neovim
make CMAKE_BUILD_TYPE=Release CMAKE_EXTRA_FLAGS="-DCMAKE_INSTALL_PREFIX:PATH=.."
make install
cd ..

echo "Making directories"
rm -rf nvim
mkdir -p nvim/bin
mkdir -p nvim/share/nvim
mkdir -p nvim/lib

echo "Copying files"
cp "neovim/bin/nvim" "nvim/bin/nvim"
cp -r "neovim/share/nvim/runtime" "nvim/share/nvim/runtime"

echo "Relocating libraries"
libs=($(otool -L "nvim/bin/nvim" | sed 1d | awk -F ' ' '{print $1}' | grep -v '^/System\|^/usr/lib'))

for lib in "${libs[@]}"; do
    echo "Relocating library: $lib"

    name="${lib##*/}"
    cp -L "$lib" "nvim/lib/$name"
    install_name_tool -change "$lib" "@executable_path/../lib/$name" "nvim/bin/nvim"
done

echo "Done"
popd

