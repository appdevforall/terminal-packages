#!/usr/bin/env bash

#
# Copyright (C) 2025 Akash Yadav
#
# This file is part of The Scribe Project.
#
# Scribe is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Scribe is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Scribe.  If not, see <https://www.gnu.org/licenses/>.
#

set -euo pipefail

script=$(realpath "$0")
script_dir=$(dirname "$script")

# Include utilities
. "$script_dir/utils.sh"

# Supported architectures
declare -a ARCHS=(
    "aarch64"
    "arm"
)

termux_packages="$script_dir/termux-packages"
output_dir="$script_dir/output"
repo_dir="$output_dir/repo"
debs_dir="$output_dir/debs"
termux_apt_repo="$output_dir/termux-apt-repo"

# Clean
rm -rf "$debs_dir"
rm -rf "$repo_dir"

if ! [ -f "$termux_apt_repo" ]; then
    # Download termux-apt-repo script
    wget https://github.com/termux/termux-apt-repo/raw/refs/heads/master/termux-apt-repo -O "$termux_apt_repo"

    # Make it executable
    chmod +x "$termux_apt_repo"
fi

# Create dirs
mkdir -p "$debs_dir"
mkdir -p "$repo_dir"

# Add symlinks to deb files to the repo dir
for arch in "${ARCHS[@]}"; do
    find "$output_dir/$arch"\
        -mindepth 1\
        -maxdepth 1\
        -type f\
        -name "*.deb"\
        -exec ln -sf {} "$debs_dir/" \; ||\
        scribe_error_exit "Failed to symlink '$arch' debs"
done

# Generate APT repository
"$termux_apt_repo" "$debs_dir" "$repo_dir" stable main ||\
    scribe_error_exit "Failed to create local API repository"

# Clean
rm -rf "$debs_dir"
