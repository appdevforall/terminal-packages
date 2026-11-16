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

  # v0.7 of the libandroid-shmem library patches shmem.c to use ASharedMemory_* from libandroid.so
  # to work with shared memory regions. However, libandroid.so pulls in a bunch of other system
  # libraries, including libperfetto_framework_jni.so, which assumes an ART environment and tries
  # to register native methods of classes. This makes our tooling API server, running in a JVM env,
  # crash due to the obviously missing Android-specific classes.
  "libandroid-shmem-revert-a-shared-memory-patch.patch"

  # termux-packages/build-package.sh contains hardcoded names for keyring files
  # these keyring files are used when we build packages with the -I flag
  # since we use a different signing key, we need to update the reference here
  "use-our-keys-to-install-deps.patch"

  # Codeberg regenerated foot's 1.25.0 source archive, changing its SHA-256
  # (ncurses pulls foot's terminfo from it). Contents are identical to the
  # 1.25.0 git tag; only the archive packaging differs.
  "foot-update-source-checksum.patch"

  # dos2unix's upstream host (XS4ALL homepages) is gone and serves an HTML
  # "not found" page. Fetch the identical release tarball from SourceForge;
  # the pinned SHA-256 is unchanged.
  "dos2unix-use-sourceforge-mirror.patch"
)

# Script configuration
COTG_ARCH=""
COTG_EXPLICIT="false"
COTG_NO_BUILD="false"
COTG_INSTALL_DEPS="false"

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
  echo "  -I        Prefer downloading packages from remote repository if the versions match."
  echo
  echo "  -h        Show this help message and exit."
  echo ""
}

sed_escape() {
  printf '%s\n' "$1" | sed -e 's/[.[\*^$/]/\\&/g' -e 's/\\/\\\\/g' -e 's/#/\\#/g'
}

# Replaces the Termux package name with ours in the text files under $1.
# Binary files are left alone, and file names may contain any character.
update_package_name() {
  # grep exits 1 when no file matches, which is not a failure here.
  { grep -rlIZF --exclude-dir=".git" -e "${TERMUX_PACKAGE_NAME}" -- "$1" || [[ $? -eq 1 ]]; } |
    xargs -0 -r sed -i "s/${TERMUX_PACKAGE_NAME//./\\.}/${COTG_PACKAGE_NAME}/g"
}

setup_termux_packages() {
  pushd "$TERMUX_PACKAGES_DIR" || scribe_error_exit "Unable to pushd into termux-packages"

  # Change package name
  echo "Updating package name.."
  update_package_name . || scribe_error_exit "Unable to update package name"

  # Removes existing keyrings
  echo "Removing existing GPG keys..."
  rm -rvf packages/termux-keyring/*.gpg

  # Add our own keyring
  echo "Adding our keyring..."
  cp "${COTG_GPG_KEY}" "./packages/termux-keyring/$(basename "$COTG_GPG_KEY")"

  # Create termux-keyring.patch
  termux_keyring_patch="$script_dir/patches/termux-keyring.patch"
  sed "s|@COTG_GPG_KEY@|$(basename "$COTG_GPG_KEY")|g" "${termux_keyring_patch}.in" >"$termux_keyring_patch"

  # Create termux-tools-update-package-name.patch
  termux_tools_update_package_name_patch="$script_dir/patches/termux-tools-update-package-name.patch"
  sed "s|@TERMUX_PACKAGE_NAME@|$COTG_PACKAGE_NAME|g" "${termux_tools_update_package_name_patch}.in" >"${termux_tools_update_package_name_patch}"

  # Apply patches
  for patch in "${PATCHES[@]}"; do
    scribe_info "Applying patch: ${patch}"
    if patch -p1 --no-backup-if-mismatch <"$script_dir/patches/$patch" ||
      scribe_error_exit "Failed to apply '$patch'"; then
      scribe_ok "Applied '$patch'"
    fi
  done

  # Update the packages repository
  grep -rnI . -e "https://packages-cf.termux.dev/apt/termux-main" -l |
    xargs -L1 sed -i "s|https://packages-cf.termux.dev/apt/termux-main|${COTG_REPO}|g"

  # Marked patched
  touch .scribe-patched

  popd || scribe_error_exit "Unable to popd from termux-packages"
}

# Marks our copies in termux-packages, so the cleanup removes only folders it
# made. Whether a package is upstream's is for git to say: a marker can
# outlast a checkout of a newer termux-packages that adds a package of the
# same name.
COTG_OWN_PACKAGE_MARKER=".cotg-own-package"

# Runs git in termux-packages. It drops git variables inherited from a caller,
# such as GIT_DIR or GIT_INDEX_FILE in a git hook, which would make git answer
# for another repository or index.
termux_packages_git() {
  (
    local -a git_vars
    mapfile -t git_vars < <(git rev-parse --local-env-vars)
    unset "${git_vars[@]}"
    git -C "$TERMUX_PACKAGES_DIR" "$@"
  )
}

# Stops the build unless termux-packages is a git checkout of its own, so that
# git answers for it and not for a repository around it.
check_termux_packages_checkout() {
  local toplevel
  toplevel="$(termux_packages_git rev-parse --show-toplevel)" ||
    scribe_error_exit "Unable to read termux-packages with git; see git's message above"
  [[ "$(realpath "$toplevel")" == "$(realpath "$TERMUX_PACKAGES_DIR")" ]] ||
    scribe_error_exit "termux-packages is not a git checkout of its own (git found '$toplevel'); run 'git submodule update --init'"
}

# Succeeds if git tracks a file under $1, a path inside termux-packages.
# Stops the build if git cannot answer.
termux_packages_tracks() {
  local files
  files="$(termux_packages_git --literal-pathspecs ls-files -- "$1")" ||
    scribe_error_exit "Unable to ask git whether termux-packages has '$1'"
  [[ -n "$files" ]]
}

# Copies our own packages (packages/<name>/) into termux-packages/packages/.
# Runs on every build, unlike the patches, so the copies always match
# packages/. A build in the same container still skips a package it already
# built at the same version, and publishing keeps a published file of the
# same version, so a change must raise TERMUX_PKG_VERSION or
# TERMUX_PKG_REVISION to reach users.
# They must be new packages: a change to an upstream package is a patch in
# PATCHES.
sync_own_packages() {
  local pkg_dir pkg_name dest repo_dir
  local -a repo_dirs

  # The package directories build-package.sh searches.
  mapfile -t repo_dirs < <(jq --raw-output 'del(.pkg_format) | keys | .[]' "$TERMUX_PACKAGES_DIR/repo.json")
  [[ ${#repo_dirs[@]} -gt 0 ]] || scribe_error_exit "Unable to read package directories from termux-packages/repo.json"

  check_termux_packages_checkout

  # Drop copies of packages that are no longer ours, so they are not built.
  for dest in "$TERMUX_PACKAGES_DIR"/packages/*/; do
    pkg_name="$(basename "$dest")"
    if [[ -e "$dest/$COTG_OWN_PACKAGE_MARKER" && ! -d "$script_dir/packages/$pkg_name" ]]; then
      if termux_packages_tracks "packages/$pkg_name"; then
        scribe_error_exit "termux-packages/packages/$pkg_name is upstream's but has our $COTG_OWN_PACKAGE_MARKER from an older build; reset termux-packages with 'git -C termux-packages reset --hard && git -C termux-packages clean -fdx' and run again"
      fi
      rm -rf "$dest"
      scribe_ok "Removed package '$pkg_name', which is no longer in packages/"
    fi
  done

  for pkg_dir in "$script_dir"/packages/*/; do
    [[ -d "$pkg_dir" ]] || continue
    pkg_name="$(basename "$pkg_dir")"
    dest="$TERMUX_PACKAGES_DIR/packages/$pkg_name"

    for repo_dir in "${repo_dirs[@]}"; do
      if termux_packages_tracks "$repo_dir/$pkg_name" ||
        compgen -G "$TERMUX_PACKAGES_DIR/$repo_dir/*/$pkg_name.subpackage.sh" >/dev/null; then
        scribe_error_exit "termux-packages already has a package named '$pkg_name' in $repo_dir/; change it with a patch instead"
      fi
      # Not upstream's, so a folder of that name is our copy or someone's own work.
      if [[ -e "$TERMUX_PACKAGES_DIR/$repo_dir/$pkg_name" && ! -e "$TERMUX_PACKAGES_DIR/$repo_dir/$pkg_name/$COTG_OWN_PACKAGE_MARKER" ]]; then
        scribe_error_exit "termux-packages/$repo_dir/$pkg_name is not upstream's and not our copy; move it out of termux-packages"
      fi
    done

    # The marker goes in before the files, so a copy cut short is still known
    # as ours and is replaced on the next run.
    rm -rf "$dest"
    { mkdir "$dest" && touch "$dest/$COTG_OWN_PACKAGE_MARKER" && cp -r "$pkg_dir." "$dest/"; } ||
      scribe_error_exit "Unable to copy package '$pkg_name'"

    # The same package name update setup_termux_packages makes upstream.
    update_package_name "$dest" || scribe_error_exit "Unable to update package name in '$pkg_name'"

    scribe_ok "Copied package '$pkg_name'"
  done
}

if [[ $# -eq 0 ]]; then
  # No arguments provided
  usage
  exit 1
fi

# Argument parsing
while getopts "a:enp:r:s:Ih" opt; do
  case "$opt" in
  a) COTG_ARCH="$OPTARG" ;;
  e) COTG_EXPLICIT="true" ;;
  n) COTG_NO_BUILD="true" ;;
  p) COTG_PACKAGE_NAME="$OPTARG" ;;
  r) COTG_REPO="$OPTARG" ;;
  s) COTG_GPG_KEY="$(realpath "$OPTARG")" ;;
  I) COTG_INSTALL_DEPS="true" ;;
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
scribe_check_command "jq"

if ! [[ -f "$TERMUX_PACKAGES_DIR/.scribe-patched" ]]; then
  setup_termux_packages
fi

sync_own_packages

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

declare -a BUILD_ARGS
BUILD_ARGS=(
  "-a" "${COTG_ARCH}"
  "-o" "${OUTPUT_DIR}"
)

if [[ "${COTG_INSTALL_DEPS}" == "true" ]]; then
  BUILD_ARGS+=("-I")
fi

BUILD_ARGS+=("${COTG_PACKAGES[@]}")

if ! { time ./build-package.sh "${BUILD_ARGS[@]}" |&
  tee "$OUTPUT_DIR/build.log"; }; then
  scribe_error_exit "Failed to build packages."
fi

popd || scribe_error_exit "Unable to popd from termux-packages"
