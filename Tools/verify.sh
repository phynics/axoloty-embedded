#!/usr/bin/env bash
# The one verification entry point for this repository.
#
# Verification is split into capability tiers because this repository is
# verified from three very different places: a laptop with no embedded
# toolchain, CI with a toolchain and no board, and a bench with a board.
#
#   repo    invariants and repository shape     needs nothing
#   core    locked Core preparation             needs swift and network
#   build   firmware image build per profile    needs the platform toolchain
#   device  flash, monitor, and smoke           needs a physical board
#
# A tier whose capability is absent reports UNAVAILABLE with the reason and is
# NOT counted as a pass. That distinction is the whole point: "I could not run
# it" and "it passed" must never look alike in a report or an issue comment.
#
# Usage:
#   Tools/verify.sh                     run every available tier
#   Tools/verify.sh --tier repo         run one tier
#   Tools/verify.sh --require core      fail if that tier cannot run
#   Tools/verify.sh --profile <name>    limit build and device tiers
#
# Exit status: 0 every attempted tier passed, 1 a tier failed, 2 a required
# tier was unavailable, 3 bad usage.

set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 3

requested_tier=''
required_tiers=''
profile_filter=''

while [ $# -gt 0 ]; do
    case "$1" in
        --tier) requested_tier="${2:-}"; shift 2 || exit 3 ;;
        --require) required_tiers="$required_tiers ${2:-}"; shift 2 || exit 3 ;;
        --profile) profile_filter="${2:-}"; shift 2 || exit 3 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "verify: unknown argument: $1" >&2; exit 3 ;;
    esac
done

failed=0
missing_required=0
summary=''

record() {
    summary="$summary$(printf '%-7s %-12s %s' "$1" "$2" "$3")
"
}

is_required() {
    case " $required_tiers " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

unavailable() {
    local tier="$1" reason="$2"
    if is_required "$tier"; then
        printf '\n== %s: UNAVAILABLE but required: %s\n' "$tier" "$reason" >&2
        record REQUIRED "$tier" "$reason"
        missing_required=1
    else
        printf '\n== %s: UNAVAILABLE (%s)\n' "$tier" "$reason"
        record SKIP "$tier" "$reason"
    fi
}

wanted() {
    [ -z "$requested_tier" ] || [ "$requested_tier" = "$1" ]
}

# ---------------------------------------------------------------------------
# repo
# ---------------------------------------------------------------------------

if wanted repo; then
    printf '\n== repo: repository invariants\n'
    if bash Tools/check-invariants.sh; then
        record PASS repo 'invariants hold'
    else
        record FAIL repo 'see the violations above'
        failed=1
    fi
fi

# ---------------------------------------------------------------------------
# core
# ---------------------------------------------------------------------------

if wanted core; then
    if ! command -v swift >/dev/null 2>&1; then
        unavailable core 'swift is not on PATH, so Core preparation cannot run'
    else
        printf '\n== core: locked Core preparation\n'
        if Tools/prepare-core.sh; then
            record PASS core 'Core prepared at the locked revision'
        else
            record FAIL core 'Core preparation failed'
            failed=1
        fi
    fi
fi

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

profiles() {
    local found
    found="$(find Profiles -mindepth 2 -maxdepth 2 -name profile.json 2>/dev/null |
             sed 's|^Profiles/||; s|/profile.json$||' | sort)"
    if [ -n "$profile_filter" ]; then
        echo "$found" | grep -Fx "$profile_filter" || true
    else
        echo "$found"
    fi
}

if wanted build; then
    available_profiles="$(profiles)"
    if [ -z "$available_profiles" ]; then
        unavailable build 'no profile declares a build yet'
    elif ! command -v idf.py >/dev/null 2>&1; then
        unavailable build 'idf.py is not on PATH, so no firmware image can be produced'
    else
        for profile in $available_profiles; do
            printf '\n== build: %s\n' "$profile"
            if [ -x "Profiles/$profile/build.sh" ]; then
                if "Profiles/$profile/build.sh"; then
                    record PASS "build:$profile" 'image built'
                else
                    record FAIL "build:$profile" 'build failed'
                    failed=1
                fi
            else
                record FAIL "build:$profile" 'the profile declares no executable build.sh'
                failed=1
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
# device
# ---------------------------------------------------------------------------
# A device tier needs an operator to name the board. It is never inferred, and
# it never runs by accident: ordinary verification does not probe hardware.

if wanted device; then
    if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
        unavailable device 'AXOLOTY_DEVICE_PORT is unset, so no board is attached to this run'
    elif ! command -v idf.py >/dev/null 2>&1; then
        unavailable device 'idf.py is not on PATH, so nothing can be flashed'
    else
        for profile in $(profiles); do
            printf '\n== device: %s on %s\n' "$profile" "$AXOLOTY_DEVICE_PORT"
            if [ -x "Profiles/$profile/qualify.sh" ]; then
                if "Profiles/$profile/qualify.sh"; then
                    record PASS "device:$profile" 'qualification passed'
                else
                    record FAIL "device:$profile" 'qualification failed'
                    failed=1
                fi
            else
                record FAIL "device:$profile" 'the profile declares no executable qualify.sh'
                failed=1
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------

printf '\n---- verify summary ----\n%s' "$summary"

if [ "$failed" -ne 0 ]; then
    printf 'verify: FAILED\n'
    exit 1
fi
if [ "$missing_required" -ne 0 ]; then
    printf 'verify: a required tier could not run here\n'
    exit 2
fi
printf 'verify: every attempted tier passed. A SKIP line is not a pass; quote it as-is when reporting.\n'
