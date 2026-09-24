#!/usr/bin/env bash
# The one verification entry point for this repository.
#
# Verification is split into capability tiers because this repository is
# verified from three very different places: a laptop with no embedded
# toolchain, CI with a toolchain and no board, and a bench with a board.
#
#   repo    invariants and repository shape     needs nothing
#   core    locked Core preparation             needs swift and network
#   build   host firmware checks and the         needs a host compiler; the
#           firmware image build per profile    image part needs ESP-IDF
#   broker  broker-only checks                  self-provisions or uses a broker
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
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    repo_failed=0
    bash Tools/check-invariants.sh || repo_failed=1
    printf '\n== repo: release manifest validator\n'
    python3 Tools/test-validate-release-manifest.py || repo_failed=1
    # The smoke case set is pinned separately: a validator that expects fewer
    # cases still reports a clean pass on a board, so nothing downstream can
    # catch it shrinking.
    printf '\n== repo: smoke case coverage\n'
    bash Tools/check-smoke-coverage.sh || repo_failed=1
    if [ "$repo_failed" -eq 0 ]; then
        record PASS repo 'invariants hold and the smoke case set matches its baseline'
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
# Two kinds of firmware check live here. Host checks compile the real firmware
# sources with a host compiler and need no board, SDK, or broker. Image checks
# need the platform toolchain and produce the firmware image. A check that
# needs a board is never here; it is in `device`.

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

# Run a check script. Exit 69 from the script means its capability is absent.
# This script does not run under `set -e`, so a failing check is captured here
# instead of aborting the run before the summary.
check_script() {
    local label="$1" reason="$2"
    shift 2
    printf '\n== build: %s\n' "$label"
    "$@"
    local status=$?
    case "$status" in
        0) record PASS "build:$label" 'passed' ;;
        69) unavailable "build:$label" "$reason" ;;
        *) record FAIL "build:$label" 'check failed'; failed=1 ;;
    esac
}

if wanted build; then
    check_script runtime-identity \
        'no host C compiler is available for the runtime identity check' \
        Tests/embedded/run-runtime-identity-test.sh
    check_script shared-flags \
        'no host C compiler is available for the shared flags check' \
        Tests/embedded/run-shared-flags-test.sh
    check_script mqtt-host-seam \
        'swiftc or a host C compiler is not available for the MQTT seam check' \
        Tests/embedded/run-mqtt-host-test.sh
    check_script zenoh-host-seam \
        'swiftc or a host C compiler is not available for the Zenoh seam check' \
        Tests/embedded/run-zenoh-host-test.sh
    check_script host-smoke \
        'swiftc, a host C compiler, or the prepared Core is not available for the host smoke check' \
        Tests/embedded/run-host-smoke-test.sh

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
            check_script "reproducible-build:$profile" \
                'idf.py is required to rebuild the firmware' \
                Tests/embedded/check-reproducible-build.sh "$profile"
            check_script "swift-linker:$profile" \
                'idf.py is required to link the firmware' \
                Tests/embedded/check-swift-linker.sh "$profile"
        done
    fi
fi

# ---------------------------------------------------------------------------
# broker
# ---------------------------------------------------------------------------
# A broker-only check needs a reachable MQTT broker but no board. The owned
# check self-provisions one when no operator broker is configured. Checks that
# need a broker *and* a board are device checks and belong to `device`.

if wanted broker; then
    broker_host=${AXOLOTY_MQTT_HOST:-}
    broker_port=${AXOLOTY_MQTT_PORT:-1883}
    broker_checks="$(find Tests/embedded/broker -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort)"
    if [ -z "$broker_checks" ]; then
        if [ -z "$broker_host" ]; then
            unavailable broker 'AXOLOTY_MQTT_HOST is unset and no self-provisioned broker check is owned yet'
        else
            unavailable broker 'a broker is configured, but no broker-only check is owned yet'
        fi
    elif [ -n "$broker_host" ] && ! (exec 3<>"/dev/tcp/$broker_host/$broker_port") 2>/dev/null; then
        unavailable broker "no MQTT broker is reachable at $broker_host:$broker_port"
    else
        for broker_check in $broker_checks; do
            printf '\n== broker: %s\n' "$broker_check"
            if "$broker_check"; then
                record PASS "broker:$(basename "$broker_check")" 'passed'
            else
                broker_status=$?
                if [ "$broker_status" -eq 69 ]; then
                    unavailable broker "the broker check toolchain is unavailable for $(basename "$broker_check")"
                else
                    record FAIL "broker:$(basename "$broker_check")" 'check failed'
                    failed=1
                fi
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

# A SKIP is a statement about this run, not about the repository. The toolchain
# lives in a container, so a bare host almost always skips everything below the
# repo tier. Say so here, where the reader actually is, rather than letting them
# conclude the work is unverifiable.
if printf '%s' "$summary" | grep -q '^SKIP'; then
    printf '\nA tier skipped. Before concluding anything is unverifiable, run\n'
    printf '"docker images" and read docs/container-builds.md: axoloty-embedded-dev,\n'
    printf 'built from .devcontainer/Dockerfile, carries Swift and ESP-IDF, and the\n'
    printf 'build and core tiers run inside it.\n'
fi

if [ "$failed" -ne 0 ]; then
    printf 'verify: FAILED\n'
    exit 1
fi
if [ "$missing_required" -ne 0 ]; then
    printf 'verify: a required tier could not run here\n'
    exit 2
fi
printf 'verify: every attempted tier passed. A SKIP line is not a pass; quote it as-is when reporting.\n'
