#!/usr/bin/env bash

set -euo pipefail

script=$(realpath "$0")
script_dir=$(dirname "$script")

. "$script_dir/common.sh"

for v in R2_ENDPOINT R2_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TERMUX_PACKAGE_PRIVATE_GPG_KEY; do
    [[ -n "${!v:-}" ]] || scribe_error_exit "$v is not set"
done

remote="s3://$R2_BUCKET/${COTG_REPO#*://*/}"
current="$COTG_OUTPUT_DIR/current"
listed="$COTG_OUTPUT_DIR/current.sha256"

s3() {
    aws --endpoint-url "$R2_ENDPOINT" s3 "$@" --no-progress
}

rm -rf "$current"
mkdir -p "$current/dists/stable" "$COTG_OUTPUT_DIR/aarch64" "$COTG_OUTPUT_DIR/arm"

scribe_info "Reading the published repository from $remote"
s3 cp "$remote/dists/stable/Release" "$current/dists/stable/Release" >/dev/null ||
    scribe_error_exit "No repository at $remote"

: > "$listed"
for arch in aarch64 arm all; do
    packages="dists/stable/main/binary-$arch/Packages"
    s3 cp "$remote/$packages" "$current/$packages" >/dev/null
    awk '/^Filename: /{f=$2} /^SHA256: /{s=$2} /^$/{if (f && s) print s "  " f; f = s = ""} END{if (f && s) print s "  " f}' \
        "$current/$packages" >> "$listed"
done

s3 sync "$remote/dists/stable/main/" "$current/dists/stable/main/" --exclude '*' --include '*.deb' --only-show-errors
(cd "$current" && sha256sum --quiet -c "$listed")
scribe_ok "$(wc -l < "$listed") published packages verified"

declare -A built_version built_files
shopt -s nullglob
for deb in "$COTG_OUTPUT_DIR"/aarch64/*.deb "$COTG_OUTPUT_DIR"/arm/*.deb; do
    key="$(dpkg-deb -f "$deb" Package)|$(dpkg-deb -f "$deb" Architecture)"
    built_version[$key]=$(dpkg-deb -f "$deb" Version)
    built_files[$key]+="$deb"$'\n'
done

while read -r _ path; do
    deb="$current/$path"
    name=$(dpkg-deb -f "$deb" Package)
    arch=$(dpkg-deb -f "$deb" Architecture)
    version=$(dpkg-deb -f "$deb" Version)
    key="$name|$arch"
    if [[ -n "${built_version[$key]:-}" ]]; then
        built="${built_version[$key]}"
        if dpkg --compare-versions "$built" gt "$version"; then
            scribe_info "Updating $name ($arch) $version -> $built"
            continue
        fi
        if dpkg --compare-versions "$built" lt "$version"; then
            echo "::warning title=$name::kept published $version ($arch), built $built is older"
        fi
        while IFS= read -r f; do
            [[ -n "$f" ]] && rm -f "$f"
        done <<< "${built_files[$key]}"
        unset "built_version[$key]"
    fi
    if [[ "$arch" == "arm" ]]; then
        cp -p "$deb" "$COTG_OUTPUT_DIR/arm/"
    else
        cp -p "$deb" "$COTG_OUTPUT_DIR/aarch64/"
    fi
done < "$listed"

for key in "${!built_version[@]}"; do
    scribe_info "Adding ${key%|*} (${key#*|}) ${built_version[$key]}"
done

"$script_dir/generate-apt-repo.sh"

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'gpgconf --kill gpg-agent; rm -rf "$GNUPGHOME"' EXIT

gpg_args=(--batch --yes --pinentry-mode loopback)
if [[ -n "${TERMUX_PACKAGE_GPG_PASSPHRASE:-}" ]]; then
    printf '%s' "$TERMUX_PACKAGE_GPG_PASSPHRASE" > "$GNUPGHOME/passphrase"
    gpg_args+=(--passphrase-file "$GNUPGHOME/passphrase")
fi
gpg "${gpg_args[@]}" --import <<< "$TERMUX_PACKAGE_PRIVATE_GPG_KEY"

fingerprint=$(gpg --batch --with-colons --show-keys "$COTG_GPG_KEY" | awk -F: '$1 == "fpr" {print $10; exit}')
dist="$COTG_REPO_DIR/dists/stable"
gpg "${gpg_args[@]}" --local-user "$fingerprint" --digest-algo SHA256 --clearsign -o "$dist/InRelease" "$dist/Release"
gpg "${gpg_args[@]}" --local-user "$fingerprint" --digest-algo SHA256 --armor --detach-sign -o "$dist/Release.gpg" "$dist/Release"
gpgv --keyring "$COTG_GPG_KEY" "$dist/InRelease"
gpgv --keyring "$COTG_GPG_KEY" "$dist/Release.gpg" "$dist/Release"

scribe_info "Uploading to $remote"
s3 sync "$COTG_REPO_DIR/" "$remote/" --size-only --exclude '*' --include '*.deb'
s3 cp "$dist/main/" "$remote/dists/stable/main/" --recursive --exclude '*.deb' --cache-control no-cache
for f in Release Release.gpg InRelease; do
    s3 cp "$dist/$f" "$remote/dists/stable/$f" --cache-control no-cache
done
s3 cp "$remote/dists/stable/InRelease" - | cmp - "$dist/InRelease"

scribe_ok "Published $(cat "$dist"/main/binary-*/Packages | grep -c '^Package: ') packages to $remote"
