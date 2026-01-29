set -euo pipefail

script=$(realpath "$0")
script_dir=$(dirname "$script")

# shellcheck source=utils.sh
. "$script_dir/utils.sh"

# shellcheck source=packages.sh
. "$script_dir/packages.sh"

# The directory where the termux-packages repository
# is cloned
TERMUX_PACKAGES_DIR="$script_dir/termux-packages"
export TERMUX_PACKAGES_DIR

# Package name of the Termux application
# Should not be changed
TERMUX_PACKAGE_NAME="com.termux"
export TERMUX_PACKAGE_NAME

# The package name of the intended application
COTG_PACKAGE_NAME="com.itsaky.androidide"
export COTG_PACKAGE_NAME

# Path to the public key
# this is used for signature verification
# while installing packages
COTG_GPG_KEY="$script_dir/adfa-dev-team.gpg"
export COTG_GPG_KEY

# Configure build environment variables
TERMUX_SCRIPTDIR="$TERMUX_PACKAGES_DIR"
export TERMUX_SCRIPTDIR

# The target SDK version of the final Android application
TERMUX_PKG_API_LEVEL=28
export TERMUX_PKG_API_LEVEL

# The URL of the repository where the packages will be published
COTG_REPO="https://packages.appdevforall.org/apt/termux-main"
export COTG_REPO

# All supported CPU ABIs
# Must begin and end with spaces
# Must be separated with spaces
COTG_ALL_ARCHS=" aarch64 arm "
export COTG_ALL_ARCHS

# The base output directory
COTG_OUTPUT_DIR="$script_dir/output"

# The directory where local repository is created
COTG_REPO_DIR="${COTG_OUTPUT_DIR}/repo"
