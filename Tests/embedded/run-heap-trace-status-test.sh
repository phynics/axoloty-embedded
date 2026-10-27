#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

for tool in clang swiftc; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "run-heap-trace-status-test: required compiler '$tool' is unavailable" >&2
        exit 69
    }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/axoloty-heap-trace-status.XXXXXX")"
cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$work/tmp" "$work/home" "$work/module-cache"
export HOME="$work/home"
export TMPDIR="$work/tmp"

clang -std=c11 -Wall -Wextra -Werror \
    -I Tests/embedded/heap-trace-status-stubs -I Interop \
    Platforms/esp32c6-idf/main/log_helper.c \
    Platforms/esp32c6-idf/main/heap_trace_platform_adapter.c \
    Tests/embedded/heap-trace-status-test.c \
    -o "$work/heap-trace-status-test"
"$work/heap-trace-status-test"

swiftc -swift-version 5 -import-objc-header Interop/axoloty_application_entry_v1.h \
    -I Interop -module-cache-path "$work/module-cache" \
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift \
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift \
    Tests/embedded/heap-trace-status-swift-test.swift \
    -o "$work/heap-trace-status-swift-test"
"$work/heap-trace-status-swift-test"
