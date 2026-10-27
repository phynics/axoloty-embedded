#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
package_dir="$repo_root/Tools/EmbeddedApplicationMacros"
resolved_file="$package_dir/Package.resolved"

for tool in swift swiftc clang python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "UNAVAILABLE: $tool is required for the first-init host fixture" >&2
        exit 69
    fi
done
if [[ ! -f "$resolved_file" ]]; then
    echo "UNAVAILABLE: pinned macro dependencies are missing ($resolved_file)" >&2
    exit 69
fi

jobs="${AXOLOTY_SWIFT_JOBS:-4}"
if [[ ! "$jobs" =~ ^[1-4]$ ]]; then
    echo "AXOLOTY_SWIFT_JOBS must be an integer from 1 through 4" >&2
    exit 3
fi

scratch_base="${AXOLOTY_SCRATCH:-${TMPDIR:-/tmp}}"
mkdir -p "$scratch_base"
scratch="$(mktemp -d "$scratch_base/first-init.XXXXXX")"
mkdir -p "$scratch"/{cache,config,security,plugin-build,fixture}
echo "first-init scratch: $scratch"

swift --version >"$scratch/swift-version.txt" 2>&1
swift build \
    --package-path "$package_dir" \
    --scratch-path "$scratch/plugin-build" \
    --cache-path "$scratch/cache" \
    --config-path "$scratch/config" \
    --security-path "$scratch/security" \
    --jobs "$jobs" \
    --configuration release --skip-update --force-resolved-versions \
    --product embedded-application-macro-probe \
    >"$scratch/plugin-build.log" 2>&1
plugin_bin="$(swift build \
    --package-path "$package_dir" \
    --scratch-path "$scratch/plugin-build" \
    --cache-path "$scratch/cache" \
    --config-path "$scratch/config" \
    --security-path "$scratch/security" \
    --jobs "$jobs" \
    --configuration release --skip-update --force-resolved-versions \
    --show-bin-path)"
plugin="$plugin_bin/EmbeddedApplicationMacroImplementation"
if [[ ! -x "$plugin" ]]; then
    echo "macro plugin build completed without executable: $plugin" >&2
    exit 1
fi
sha256sum "$plugin" >"$scratch/plugin.sha256"

bash "$package_dir/run-first-init-unit.sh" "$scratch/fixture" "$plugin" \
    >"$scratch/first-init-fixtures.log" 2>&1
cat "$scratch/first-init-fixtures.log"
echo "PASS production macro plugin and first-init host fixtures; evidence: $scratch"
