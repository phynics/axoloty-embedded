#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Download and verify the pinned zenohd router and print its directory. The
# version and checksum are the ones Core qualifies in docs/dependencies/zenoh.md.
# The router needs its plugin libraries beside it, so run it from that directory.
#
# Usage: provision-zenohd.sh <scratch-directory>

set -eu

version=1.10.0
archive="zenoh-$version-x86_64-unknown-linux-gnu-standalone.zip"
sha256=43de097382e3db4f95903cbadbbf472a21fbea53d6a3193606ae12b034a20881
destination="$1/zenohd-$version"

if [ ! -x "$destination/zenohd" ]; then
    mkdir -p "$1"
    download="$1/$archive"
    curl -fsSL -o "$download" "https://github.com/eclipse-zenoh/zenoh/releases/download/$version/$archive" >&2
    printf '%s  %s\n' "$sha256" "$download" | sha256sum -c - >&2
    rm -rf "$destination"
    mkdir -p "$destination"
    unzip -q "$download" -d "$destination" >&2
    chmod +x "$destination/zenohd"
fi
printf '%s\n' "$destination"
