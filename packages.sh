#!/usr/bin/env bash

# Base packages, common for both debug and release builds
declare -a COTG_PACKAGES__BASE

# These are the variant-specific additional packages
# that are included in bootstrap archives
declare -a COTG_PACKAGES__DEBUG
declare -a COTG_PACKAGES__RELEASE

# List of all packages
# This is used to list all the packages
# that we need to build
declare -a COTG_PACKAGES

COTG_PACKAGES__BASE=(

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
    "brotli"
    "ed"
    "debianutils"
    "dos2unix"
    "git"
    "inetutils"
    "lsof"
    "mandoc"
    "nano"
    "net-tools"
    "openjdk-21"
    "patch"
    "unzip"
    "zip"
)

# debug-only packages
COTG_PACKAGES__DEBUG=(
    "binutils-libs"
    "coreutils"
    "file"
    "libsqlite"
    "python"
    "sqlite"
    "vim"
    "which"
)

# release-only packages
COTG_PACKAGES__RELEASE=()

# All packages
COTG_PACKAGES=(
    "${COTG_PACKAGES__BASE[@]}"
    "${COTG_PACKAGES__DEBUG[@]}"
    "${COTG_PACKAGES__RELEASE[@]}"
)
