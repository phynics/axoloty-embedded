#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Drives the real is_required function from Tools/verify.sh over small cases:
# a required tier covers its tier:detail entries, an exact entry covers only
# itself. It needs only bash.
set -u
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
eval "$(sed -n '/^is_required() {/,/^}/p' "$repo_root/Tools/verify.sh")"
failures=0
check() {
    required_tiers=$1
    if is_required "$2"; then got=required; else got=optional; fi
    if [ "$got" != "$3" ]; then
        echo "FAIL: --require '${1# }' and '$2' gave $got, expected $3" >&2
        failures=$((failures + 1))
    fi
}
check ' device' device required
check ' device' device:esp32c6-mqtt required
check ' device' device:esp32c6-mqtt:gate required
check ' device' devices optional
check ' build:host-smoke' build optional
check ' build:host-smoke' build:host-smoke required
check ' build:host-smoke' build:other optional
check ' build:host-smoke' build:host-smoke-2 optional
check '' device optional
[ "$failures" -eq 0 ] || exit 1
echo "verify is_required cases passed"
