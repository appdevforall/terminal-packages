#!/usr/bin/env bash

#
# Copyright (C) 2025 Akash Yadav
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

set -euo pipefail

script=$(realpath "$0")
script_dir=$(dirname "$script")

# shellcheck source=utils.sh
. "$script_dir/utils.sh"

TERMUX_PACKAGES_DIR="$script_dir/termux-packages"
TERMUX_PACKAGE_NAME="com.termux"

SCRIBE_PACKAGE_NAME="com.scribe"

# Configure build environment variables
TERMUX_SCRIPTDIR="$TERMUX_PACKAGES_DIR"
export TERMUX_SCRIPTDIR

TERMUX_PKG_API_LEVEL=28
export TERMUX_PKG_API_LEVEL

declare -a PATCHES=(

    # Adds our own GPG keys
    "termux-keyring.patch"

    # Makes some of the packages depend on and link against libandroid-shmem.so
    # Required to fix some build failures
    "make-libdb-depend-on-android-shmem.patch"
    "make-libunbound-depend-on-android-shmem.patch"
    "make-libx11-depend-on-android-shmem.patch"
)

# Script configuration
ALL_ARCHS=" aarch64 x86_64 "
ARCH=""

usage() {
    echo "Script to build termux-packages for Scribe"
    echo ""
    echo "Usage: $0 [options] [package...]"
    echo ""
    echo "Options:"
    echo "  -a        The target architecture. Must be one of ${ALL_ARCHS}."
    echo "  -h        Show this help message and exit"
    echo ""
}

sed_escape() {
  printf '%s\n' "$1" | sed -e 's/[.[\*^$/]/\\&/g' -e 's/\\/\\\\/g' -e 's/#/\\#/g'
}

setup_termux_packages() {
    pushd "$TERMUX_PACKAGES_DIR" || scribe_error_exit "Unable to pushd into termux-packages"

    # Change package name
    echo "Updating package name.."
    grep -rniF . -e "${TERMUX_PACKAGE_NAME}" -l\
        --exclude-dir=".git" | \
        xargs -L1 sed -i "s/${TERMUX_PACKAGE_NAME//./\\.}/${SCRIBE_PACKAGE_NAME}/g" || \
        scribe_error_exit "Unable to update package name"

    # Removes existing keyrings
    echo "Removing existing GPG keys..."
    rm -rvf packages/termux-keyring/*.gpg

    # Add our own keyring
    echo "Adding our keyring..."
    cp "$script_dir/scribe-oss.gpg" "./packages/termux-keyring/scribe-oss.gpg"

    # Apply patches
    for patch in "${PATCHES[@]}"; do
        if patch -p1 --no-backup-if-mismatch<"$script_dir/patches/$patch" ||\
            scribe_error_exit "Failed to apply '$patch'"; then
            scribe_ok "Applied '$patch'"
        fi
    done

    # Update the packages repository
    grep -rnI . -e "https://packages-cf.termux.dev/apt/termux-main" -l |\
        xargs -L1 sed -i 's|https://packages-cf.termux.dev/apt/termux-main|https://gitlab.com/scribe-oss/core/scribe-packages-repo/-/raw/main|g'

    # Marked patched
    touch .scribe-patched

    popd || scribe_error_exit "Unable to popd from termux-packages"
}

if [[ $# -eq 0 ]]; then
    # No arguments provided
    usage
    exit 1
fi

# Argument parsing
while getopts "a:h" opt; do
    case "$opt" in
    a) ARCH="$OPTARG" ;;
    h)
        usage
        exit 0
        ;;
    *)
        echo "Invalid option" >&2
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

if [[ "$ALL_ARCHS" != *" $ARCH "* ]]; then
    scribe_error_exit "Unsupported arch: '$ARCH'"
fi

# Get extra packages to build
declare -a EXTRA_PACKAGES=("$@")

OUTPUT_DIR="$script_dir/output/$ARCH"
mkdir -p "${OUTPUT_DIR}"

# For termux build scripts
TERMUX_OUTPUT_DIR="$OUTPUT_DIR/debs"
export TERMUX_OUTPUT_DIR

# Check required commands
scribe_check_command "git"
scribe_check_command "patch"
scribe_check_command "tee"
scribe_check_command "time"

if ! [[ -f "$TERMUX_PACKAGES_DIR/.scribe-patched" ]]; then
    setup_termux_packages
fi

# Symlink termux-packages/output to TERMUX_OUTPUT_DIR
if ! [[ -L "$TERMUX_PACKAGES_DIR/output" ]]; then
    rm -rf "$TERMUX_PACKAGES_DIR/output"
    ln -sf "$TERMUX_OUTPUT_DIR" "$TERMUX_PACKAGES_DIR/output"
fi

# All the packages that we'll be building
declare -a SCRIBE_PACKAGES=(

    ## ---- Bootstrap packages ---- ##

    # Core utilities.
    "apt"
    "bash"
    "command-not-found"
    "coreutils"
    "dash"
    "diffutils"
    "findutils"
    "gawk"
    "grep"
    "gzip"
    "less"
    "libbz2"
    "procps"
    "psmisc"
    "sed"
    "tar"
    "termux-core"
    "termux-exec"
    "termux-keyring"
    "termux-tools"
    "util-linux"

    # Additional.
    "ed"
    "debianutils"
    "dos2unix"
    "inetutils"
    "lsof"
    "nano"
    "net-tools"
    "patch"
    "unzip"

    ## ---- Plugin packages - C/C++ ---- ##
    "clang"

    ## ---- Plugin packages - Java ---- ##
    "openjdk-21"

    ## ---- Plugin packages - Python ---- ##
    "python"
    "python-pip"

    ## ---- Extra packages ---- #
    "${EXTRA_PACKAGES[@]}"
)

pushd "$TERMUX_PACKAGES_DIR" || scribe_error_exit "Unable to pushd into termux-packages"

echo
echo "==="
echo "Building packages: ${SCRIBE_PACKAGES[*]}"
echo "==="
echo

if ! time ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" "${SCRIBE_PACKAGES[@]}" |\
    tee "$OUTPUT_DIR/build.log"; then
    scribe_error_exit "Failed to build packages."
fi

popd || scribe_error_exit "Unable to popd from termux-packages"
