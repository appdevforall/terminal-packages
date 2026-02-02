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

script=$(realpath "$0")
script_dir=$(dirname "$script")

# shellcheck source=common.sh
. "${script_dir}/common.sh"

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
    # "libxml2-revert-to-2.14.3.patch"

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

    # Update package name in termux-tools
    "termux-tools-update-package-name.patch"

    # Cleanup OpenJDK 21 to remove postinst & prerm scripts
    "openjdk-21-cleanup.patch"

    # Cleanup vim to remove postinst scripts
    "vim-cleanup.patch"

    # Restore files and cleanup in second stage
    "scripts-cleanup-in-second-stage.patch"

    # Link pulseaudio against libiconv to resolve linker errors at build time
    "pulseaudio-link-against-libiconv.patch"

    # `rm` command complains about missing libacl.so after updating packages
    # This ensures that libacl package is installed before coreutils
    "coreutils-depend-on-libacl.patch"

    # `libapr-1.so` needs to be linked against libandroid-shmem.so
    # in order to fix undefined symbol error when building subversion
    "apr-link-against-libandroid-shmem.patch"
)

# Script configuration
COTG_ARCH=""
COTG_EXPLICIT="false"
COTG_NO_BUILD="false"

usage() {
    echo "Script to build termux-packages for Code On the Go."
    echo ""
    echo "Usage: $0 -a ARCH [options] [package...]"
    echo ""
    echo "Options:"
    echo "  -a        The target architecture. Must be one of [${COTG_ALL_ARCHS}]."
    echo "  -e        Build only the explicitly specified packages."
    echo "  -n        Set up the build, but do not execute."
    echo "  -p        The package name of the application. Defaults to '${COTG_PACKAGE_NAME}'."
    echo "  -r        The repository where the built packages will be published."
    echo "            Defaults to '${COTG_REPO}'."
    echo "  -s        The GPG key used for signing packages. Defaults to '${COTG_GPG_KEY}'."
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
        xargs -L1 sed -i "s/${TERMUX_PACKAGE_NAME//./\\.}/${COTG_PACKAGE_NAME}/g" || \
        scribe_error_exit "Unable to update package name"

    # Removes existing keyrings
    echo "Removing existing GPG keys..."
    rm -rvf packages/termux-keyring/*.gpg

    # Add our own keyring
    echo "Adding our keyring..."
    cp "${COTG_GPG_KEY}" "./packages/termux-keyring/$(basename "$COTG_GPG_KEY")"

    # Create termux-keyring.patch
    termux_keyring_patch="$script_dir/patches/termux-keyring.patch"
    sed "s|@COTG_GPG_KEY@|$(basename "$COTG_GPG_KEY")|g" "${termux_keyring_patch}.in" > "$termux_keyring_patch"

    # Create termux-tools-update-package-name.patch
    termux_tools_update_package_name_patch="$script_dir/patches/termux-tools-update-package-name.patch"
    sed "s|@TERMUX_PACKAGE_NAME@|$COTG_PACKAGE_NAME|g" "${termux_tools_update_package_name_patch}.in" > "${termux_tools_update_package_name_patch}"

    # Apply patches
    for patch in "${PATCHES[@]}"; do
        scribe_info "Applying patch: ${patch}"
        if patch -p1 --no-backup-if-mismatch<"$script_dir/patches/$patch" ||\
            scribe_error_exit "Failed to apply '$patch'"; then
            scribe_ok "Applied '$patch'"
        fi
    done

    # Update the packages repository
    grep -rnI . -e "https://packages-cf.termux.dev/apt/termux-main" -l |\
        xargs -L1 sed -i "s|https://packages-cf.termux.dev/apt/termux-main|${COTG_REPO}|g"

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
    a) COTG_ARCH="$OPTARG"                         ;;
    e) COTG_EXPLICIT="true"                        ;;
    n) COTG_NO_BUILD="true"                        ;;
    p) COTG_PACKAGE_NAME="$OPTARG"                 ;;
    r) COTG_REPO="$OPTARG"                         ;;
    s) COTG_GPG_KEY="$(realpath "$OPTARG")"        ;;
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

if [[ "$COTG_ALL_ARCHS" != *" $COTG_ARCH "* ]]; then
    scribe_error_exit "Unsupported arch: '$COTG_ARCH'"
fi

if [[ -z "${COTG_PACKAGE_NAME}" ]]; then
    scribe_error_exit "A package name must be specified."
fi

if [[ -z "${COTG_REPO}" ]]; then
    scribe_error_exit "A package repository URL must be specified."
fi

if ! [[ -f "${COTG_GPG_KEY}" ]]; then
    scribe_error_exit "${COTG_GPG_KEY} does not exist or is not a file."
fi

# Get extra packages to build
declare -a EXTRA_PACKAGES=("$@")

OUTPUT_DIR="${COTG_OUTPUT_DIR}/$COTG_ARCH"
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
fi

rm -v "$TERMUX_PACKAGES_DIR/output" || true
ln -sf "$OUTPUT_DIR" "$TERMUX_PACKAGES_DIR/output"

if [[ "$COTG_NO_BUILD" == "true" ]]; then
    scribe_ok "Skipping build."
    exit 0
fi

# All the packages that we'll be building
declare -a COTG_PACKAGES

if [[ "$COTG_EXPLICIT" == "true" ]]; then
    # We have been instructed to build only explicitly
    # specified packages
    COTG_PACKAGES=()
fi

COTG_PACKAGES+=("${EXTRA_PACKAGES[@]}")

pushd "$TERMUX_PACKAGES_DIR" || scribe_error_exit "Unable to pushd into termux-packages"

echo
echo "==="
echo "Building packages: ${COTG_PACKAGES[*]}"
echo "==="
echo

if ! { time ./build-package.sh -a "$COTG_ARCH" -o "$OUTPUT_DIR" "${COTG_PACKAGES[@]}" |&\
    tee "$OUTPUT_DIR/build.log"; }; then
    scribe_error_exit "Failed to build packages."
fi

popd || scribe_error_exit "Unable to popd from termux-packages"
