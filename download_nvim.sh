#!/bin/sh
#
# Neovim Mac
# download_nvim.sh
#
# Copyright © 2023 Jay Sandhu. All rights reserved.
# This file is distributed under the MIT License.
# See LICENSE.txt for details.
#
# ------------------------------------------------------------------------------
#
# Neovim Download Script
#
# Syntax: download_nvim.sh {tag}
# Where tag is a Neovim release tag. If no tag is provided defaults to stable.
#
# Downloads prebuilt Neovim binary. Installs in build/nvim.
#
# Install Directory Structure:
#   build/nvim/bin
#   build/nvim/lib
#   build/nvim/share

set -e

ARCHIVE="nvim.tar.gz"

pushd "$(dirname "$0")"
mkdir -p build
cd build

rm -rf nvim
mkdir nvim

curl -L -o "${ARCHIVE}" "https://github.com/neovim/neovim/releases/download/${1-"stable"}/nvim-macos.tar.gz"
xattr -c "${ARCHIVE}"
tar xzvf nvim.tar.gz -C nvim --strip-components 1
mkdir -p nvim/lib

find nvim/share -type d -not -name "nvim" -mindepth 1 -maxdepth 1 -exec rm -r {} \;
find nvim/lib -type f -not -name "*.dylib" -delete
find nvim/lib -type d -empty -mindepth 1 -delete 

echo "Done"
popd

