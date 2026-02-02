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
    "python-pip"
    "vim"
    "wget"
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

# Extra packages that need to be available
# for use in Code On the Go
# Note: When adding new packages here,
#   mention the reason for inclusion
COTG_PACKAGES+=(

    # Required for self-bootstrapping Code On the Go
    "libprotobuf",

    # Commonly used tools
    "wget"

    # cmake and libllvm for Android
    # useful for Android SDK
    "cmake"
    "libllvm"
)
