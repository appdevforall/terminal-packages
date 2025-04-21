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
ALL_ARCHS=" aarch64 arm i686 x86_64 "
ARCH=""

usage() {
    echo "Script to build termux-packages for Scribe"
    echo ""
    echo "Usage: $0 [options]"
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

    # Update the path to packages directory in build-bootstraps.sh
    echo "Updating termux-packages path in build-bootstraps.sh..."
    sed -i "s#^TERMUX_PACKAGES_DIRECTORY=.*#TERMUX_PACKAGES_DIRECTORY=\"$TERMUX_PACKAGES_DIR\"#g"\
        scripts/build-bootstraps.sh || \
        scribe_error_exit "Unable to update termux-packages path in build-bootstraps.sh"

    # Update the path to the directory where .deb files are placed
    echo "Update .deb output path in build-bootstrap.sh..."
    sed -i "s#TERMUX_BUILT_DEBS_DIRECTORY=.*#TERMUX_BUILT_DEBS_DIRECTORY=\"$OUTPUT_DIR\"#g"\
        scripts/build-bootstraps.sh || \
        scribe_error_exit "Unable to update output path in build-bootstraps.sh"

    # Fix missing directory error during build
    echo "Fix missing directory error in build-bootstraps.sh..."
    # shellcheck disable=SC2016
    sed -i 's#add_termux_bootstrap_second_stage_files() {#add_termux_bootstrap_second_stage_files() {\n\tmkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX__PREFIX__PROFILE_D_DIR}"#g'\
        ./scripts/build-bootstraps.sh || \
        scribe_error_exit "Unable to add mkdir command"

    # Fix incorrect name for bzip2 package
    sed -i "s/bzip2/libbz2/g" \
        ./scripts/build-bootstraps.sh || \
        scribe_error_exit "Unable to replace 'bzip2' with 'libbz2'"

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

OUTPUT_DIR="$script_dir/output/$ARCH"
mkdir -p "${OUTPUT_DIR}"

# Check required commands
scribe_check_command "git"
scribe_check_command "patch"
scribe_check_command "time"
scribe_check_command "tee"

if ! [[ -f "$TERMUX_PACKAGES_DIR/.scribe-patched" ]]; then
    setup_termux_packages
fi

# Symlink termux-packages/output to OUTPUT_DIR
ln -sf "$OUTPUT_DIR" "$TERMUX_PACKAGES_DIR/output"

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

    ## ---- Plugin packages - Java ---- ##
    "openjdk-21"
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

echo
echo "==="
echo "Generating bootstrap package"
echo "==="
echo

if ! time ./scripts/build-bootstraps.sh --architectures "$ARCH" |\
    tee "$OUTPUT_DIR/bootstrap.log"; then
    scribe_error_exit "Failed to generate bootstrap packages."
fi

# Move bootstrap ZIPs to OUTPUT_DIR
mv "$TERMUX_PACKAGES_DIR/bootstrap-*.zip" "$OUTPUT_DIR/"

popd || scribe_error_exit "Unable to popd from termux-packages"
