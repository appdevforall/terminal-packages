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

# shellcheck source=utils.sh
. "$script_dir/utils.sh"

TERMUX_PACKAGES_DIR="$script_dir/termux-packages"
TERMUX_PACKAGE_NAME="com.termux"

SCRIBE_PACKAGE_NAME="com.scribe"
SCRIBE_GPG_KEY="$script_dir/scribe-oss.gpg"

# Configure build environment variables
TERMUX_SCRIPTDIR="$TERMUX_PACKAGES_DIR"
export TERMUX_SCRIPTDIR

TERMUX_PKG_API_LEVEL=28
export TERMUX_PKG_API_LEVEL

declare -a PATCHES=(

    # Adds our own GPG keys
    "termux-keyring.patch"

    # Update mirror configurations
    "termux-tools-mirrors.patch"

    # Update motd
    "termux-tools-motd.patch"

    # Makes some of the packages depend on and link against libandroid-shmem.so
    # Required to fix some build failures
    "libdb-depend-on-android-shmem.patch"
    "libunbound-depend-on-android-shmem.patch"
    "libx11-depend-on-android-shmem.patch"

    # Fix dependencies in binutils-libs
    "binutils-libs-fix-dependencies.patch"

    # libxml2 v2.14.4 has build errors
    "libxml2-revert-to-2.14.3.patch"

    # Remove 'scalar' binary from $PREFIX/bin and make it a symlink
    # to $PREFIX/libexec/git-core/scalar
    "git-symlink-scalar.patch"

    # subversion fails to compile, complaining that the `apr.h` and other headers
    # could not be found. These headers are located in $PREFIX/include/apr-1
    "subversion-missing-apr-includes.patch"

    # libuv has missing sources in their Makefile configuration
    # This missing source issue was fixed in their CMake configuration
    # So we force termux-packages to build using CMake instead of Makefile
    "libuv-force-cmake-build.patch"

    # Changes for our version of bootstrap-*.zip files
    # This also handles the process of creating a brotli archive
    # from the generated ZIP archive
    "scripts-generate-bootstraps-CoGo-changes.patch"
)

# Script configuration
SCRIBE_ALL_ARCHS=" aarch64 arm i686 x86_64 "
SCRIBE_ARCH=""
SCRIBE_EXPLICIT="false"
SCRIBE_NO_BUILD="false"
SCRIBE_REPO="https://gitlab.com/scribe-oss/core/scribe-packages-repo/-/raw/main"

usage() {
    echo "Script to build termux-packages for Scribe"
    echo ""
    echo "Usage: $0 -a ARCH [options] [package...]"
    echo ""
    echo "Options:"
    echo "  -a        The target architecture. Must be one of [${SCRIBE_ALL_ARCHS}]."
    echo "  -e        Build only the explicitly specified packages."
    echo "  -n        Set up the build, but do not execute."
    echo "  -p        The package name of the application. Defaults to '${SCRIBE_PACKAGE_NAME}'."
    echo "  -r        The repository where the built packages will be published."
    echo "            Defaults to '${SCRIBE_REPO}'."
    echo "  -s        The GPG key used for signing packages. Defaults to '${SCRIBE_GPG_KEY}'."
    echo
    echo "  -h        Show this help message and exit."
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
    cp "${SCRIBE_GPG_KEY}" "./packages/termux-keyring/$(basename "$SCRIBE_GPG_KEY")"

    # Create termux-keyring.patch
    termux_keyring_patch="$script_dir/patches/termux-keyring.patch"
    sed "s|@SCRIBE_GPG_KEY@|$(basename "$SCRIBE_GPG_KEY")|g" "${termux_keyring_patch}.in" > "$termux_keyring_patch"

    # Apply patches
    for patch in "${PATCHES[@]}"; do
        if patch -p1 --no-backup-if-mismatch<"$script_dir/patches/$patch" ||\
            scribe_error_exit "Failed to apply '$patch'"; then
            scribe_ok "Applied '$patch'"
        fi
    done

    # Update the packages repository
    grep -rnI . -e "https://packages-cf.termux.dev/apt/termux-main" -l |\
        xargs -L1 sed -i "s|https://packages-cf.termux.dev/apt/termux-main|${SCRIBE_REPO}|g"

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
while getopts "a:enp:r:s:h" opt; do
    case "$opt" in
    a) SCRIBE_ARCH="$OPTARG"                         ;;
    e) SCRIBE_EXPLICIT="true"                        ;;
    n) SCRIBE_NO_BUILD="true"                        ;;
    p) SCRIBE_PACKAGE_NAME="$OPTARG"                 ;;
    r) SCRIBE_REPO="$OPTARG"                         ;;
    s) SCRIBE_GPG_KEY="$(realpath "$OPTARG")"        ;;
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

if [[ "$SCRIBE_ALL_ARCHS" != *" $SCRIBE_ARCH "* ]]; then
    scribe_error_exit "Unsupported arch: '$SCRIBE_ARCH'"
fi

if [[ -z "${SCRIBE_PACKAGE_NAME}" ]]; then
    scribe_error_exit "A package name must be specified."
fi

if [[ -z "${SCRIBE_REPO}" ]]; then
    scribe_error_exit "A package repository URL must be specified."
fi

if ! [[ -f "${SCRIBE_GPG_KEY}" ]]; then
    scribe_error_exit "${SCRIBE_GPG_KEY} does not exist or is not a file."
fi

# Get extra packages to build
declare -a EXTRA_PACKAGES=("$@")

OUTPUT_DIR="$script_dir/output/$SCRIBE_ARCH"
mkdir -p "${OUTPUT_DIR}"

# Check required commands
scribe_check_command "git"
scribe_check_command "patch"
scribe_check_command "tee"
scribe_check_command "time"

if ! [[ -f "$TERMUX_PACKAGES_DIR/.scribe-patched" ]]; then
    setup_termux_packages
fi

# Symlink termux-packages/output to OUTPUT_DIR
if ! [[ -L "$TERMUX_PACKAGES_DIR/output" ]]; then
    rm -rf "$TERMUX_PACKAGES_DIR/output"
    ln -sf "$OUTPUT_DIR" "$TERMUX_PACKAGES_DIR/output"
fi

if [[ "$SCRIBE_NO_BUILD" == "true" ]]; then
    scribe_ok "Skipping build."
    exit 0
fi

# All the packages that we'll be building
declare -a SCRIBE_PACKAGES

if [[ "$SCRIBE_EXPLICIT" != "true" ]]; then
    SCRIBE_PACKAGES+=(

        ## ---- Bootstrap packages ---- ##

        # Core utilities.
        "apt"
        "bash"
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
        "libllvm"

        ## ---- Plugin packages - Java ---- ##
        "openjdk-21"

        ## ---- Plugin packages - Python ---- ##
        "python"
        "python-pip"
    )
fi

SCRIBE_PACKAGES+=("${EXTRA_PACKAGES[@]}")

pushd "$TERMUX_PACKAGES_DIR" || scribe_error_exit "Unable to pushd into termux-packages"

echo
echo "==="
echo "Building packages: ${SCRIBE_PACKAGES[*]}"
echo "==="
echo

if ! { time ./build-package.sh -a "$SCRIBE_ARCH" -o "$OUTPUT_DIR" "${SCRIBE_PACKAGES[@]}" |&\
    tee "$OUTPUT_DIR/build.log"; }; then
    scribe_error_exit "Failed to build packages."
fi

popd || scribe_error_exit "Unable to popd from termux-packages"
