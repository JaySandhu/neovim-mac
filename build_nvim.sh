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
# Neovim build script.
#
# Builds our Neovim fork which includes a few UI related patches.
# Available at: https://github.com/JaySandhu/neovim/tree/release-0.4-patched
# Hopefully we can get these changes merged so we can drop our fork.
#
# The build prerequisites are the same as Neovim.
# See: https://github.com/neovim/neovim/wiki/Building-Neovim#macos
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
    git clone --depth 1 "https://github.com/JaySandhu/neovim.git" -b "release-0.4-patched"
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
