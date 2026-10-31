#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Download and verify the pinned zenoh-c archive the Zenoh host peer links, and
# print the unpacked directory. The version and checksum are the ones Core
# qualifies in its docs/dependencies/zenoh.md.
#
# Usage: provision-zenoh-c.sh <scratch-directory>

set -eu

version=1.10.0
archive="zenoh-c-$version-x86_64-unknown-linux-gnu-standalone.zip"
sha256=1168b3dffa7f4f48ffabfd640a3878ec0527c0a612ce825aa6f93e2cd05762d1
destination="$1/zenoh-c-$version"

if [ ! -f "$destination/lib/pkgconfig/zenohc.pc" ]; then
    mkdir -p "$1"
    download="$1/$archive"
    curl -fsSL -o "$download" "https://github.com/eclipse-zenoh/zenoh-c/releases/download/$version/$archive" >&2
    printf '%s  %s\n' "$sha256" "$download" | sha256sum -c - >&2
    rm -rf "$destination"
    mkdir -p "$destination"
    unzip -q "$download" -d "$destination" >&2
    # The archive's pkg-config file names its install prefix.
    sed -i "s|^prefix=.*|prefix=$destination|" "$destination/lib/pkgconfig/zenohc.pc"
fi
printf '%s\n' "$destination"
