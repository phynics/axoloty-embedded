#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for profile in esp32c6-mqtt esp32c6-zenoh esp32c6-sensor-node-mqtt esp32c6-sensor-node-zenoh; do
    python3 "$repo_root/Tools/validate-composition.py" --repo-root "$repo_root" \
        --profile "$repo_root/Profiles/$profile/profile.json"
done

# The carrier bounds come from the selected application's declared capacities,
# through one generator, into the C header, the Swift constants and the CMake
# file the zenoh-pico component reads.
expect_bounds() {
    # $1 profile, $2 topic bound, $3 payload bound
    out="$tmp/bounds-$1"
    mkdir -p "$out"
    python3 "$repo_root/Tools/validate-composition.py" --repo-root "$repo_root" \
        --profile "$repo_root/Profiles/$1/profile.json" \
        --emit-carrier-bounds-header "$out/bounds.h" --emit-carrier-bounds-swift "$out/Bounds.swift" \
        --emit-carrier-bounds-cmake "$out/bounds.cmake" >/dev/null
    grep -Fx "#define AXOLOTY_CARRIER_MAX_TOPIC_BYTES $2" "$out/bounds.h" >/dev/null &&
        grep -Fx "#define AXOLOTY_CARRIER_MAX_PAYLOAD_BYTES $3" "$out/bounds.h" >/dev/null &&
        grep -F "static let maxTopicLength = $2" "$out/Bounds.swift" >/dev/null &&
        grep -F "static let maxPayloadSize = $3" "$out/Bounds.swift" >/dev/null &&
        grep -F "typealias TopicStorage = InlineArray<$2, UInt8>" "$out/Bounds.swift" >/dev/null &&
        grep -Fx "set(AXOLOTY_CARRIER_MAX_TOPIC_BYTES $2)" "$out/bounds.cmake" >/dev/null &&
        grep -Fx "set(AXOLOTY_CARRIER_MAX_PAYLOAD_BYTES $3)" "$out/bounds.cmake" >/dev/null || {
        echo "FAIL: $1 did not emit carrier bounds $2/$3" >&2
        exit 1
    }
}
expect_bounds esp32c6-mqtt 256 2048
expect_bounds esp32c6-zenoh 256 2048
expect_bounds esp32c6-sensor-node-mqtt 128 512
expect_bounds esp32c6-sensor-node-zenoh 128 512

# The host package builds the MQTT carrier for the smoke application from files
# it keeps in the tree. They must say what the generator says for that profile.
cmp -s "$tmp/bounds-esp32c6-mqtt/bounds.h" "$repo_root/Tests/host-carrier-bounds/include/axoloty_carrier_bounds.h" || {
    echo "FAIL: Tests/host-carrier-bounds/include/axoloty_carrier_bounds.h differs from the generated smoke bounds" >&2
    exit 1
}
python3 - "$tmp/bounds-esp32c6-mqtt/Bounds.swift" "$repo_root/Tests/host-carrier-bounds/Sources/HostCarrierBounds/CarrierBounds.swift" <<'PY' || {
import re, sys
def body(path):
    text = open(path).read().replace("public ", "")
    return [line for line in text.splitlines() if not line.startswith("//")]
sys.exit(0 if body(sys.argv[1]) == body(sys.argv[2]) else 1)
PY
    echo "FAIL: Tests/host-carrier-bounds CarrierBounds.swift differs from the generated smoke bounds" >&2
    exit 1
}

# An application whose capacity exceeds a transport's fixed ceiling stops the
# configure step; a capacity equal to the ceiling is accepted.
ceiling_root="$tmp/ceiling"
mkdir -p "$ceiling_root/Applications" "$ceiling_root/Platforms" "$ceiling_root/Profiles"
cp -R "$repo_root/Transports" "$ceiling_root/Transports"
cp -R "$repo_root/Applications/sensor-node" "$ceiling_root/Applications/sensor-node"
mkdir -p "$ceiling_root/Platforms/esp32c6-idf"
cp "$repo_root/Platforms/esp32c6-idf/platform.json" "$ceiling_root/Platforms/esp32c6-idf/platform.json"
cp "$repo_root/axoloty-core.lock.json" "$ceiling_root/axoloty-core.lock.json"
for profile in esp32c6-sensor-node-mqtt esp32c6-sensor-node-zenoh; do
    mkdir -p "$ceiling_root/Profiles/$profile"
    cp "$repo_root/Profiles/$profile/profile.json" "$ceiling_root/Profiles/$profile/profile.json"
done
set_capacity() {
    # $1 name, $2 value
    python3 - "$ceiling_root/Applications/sensor-node/app.json" "$1" "$2" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["capacities"][sys.argv[2]] = int(sys.argv[3])
path.write_text(json.dumps(value))
PY
}
for profile in esp32c6-sensor-node-mqtt esp32c6-sensor-node-zenoh; do
    for case in "maxPayloadSize 2049 2048" "maxTopicLength 257 256"; do
        set -- $case
        set_capacity "$1" "$2"
        if python3 "$repo_root/Tools/validate-composition.py" --repo-root "$ceiling_root" \
            --profile "$ceiling_root/Profiles/$profile/profile.json" >"$tmp/ceiling.log" 2>&1; then
            echo "FAIL: $profile accepted capacities.$1 $2 above the transport ceiling $3" >&2
            exit 1
        fi
        grep -F "capacities.$1 $2 exceeds the fixed ceiling $3 of transport" "$tmp/ceiling.log" >/dev/null || {
            cat "$tmp/ceiling.log" >&2
            echo "FAIL: $profile rejected capacities.$1 $2 for an unexpected reason" >&2
            exit 1
        }
        set_capacity "$1" "$3"
        python3 "$repo_root/Tools/validate-composition.py" --repo-root "$ceiling_root" \
            --profile "$ceiling_root/Profiles/$profile/profile.json" >/dev/null || {
            echo "FAIL: $profile rejected capacities.$1 $3 at the transport ceiling" >&2
            exit 1
        }
        set_capacity "$1" "$([ "$1" = maxPayloadSize ] && echo 512 || echo 128)"
    done
done
# A transport that declares no ceiling is not composed.
python3 - "$ceiling_root/Transports/mqtt-espidf/transport.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
del value["limits"]
path.write_text(json.dumps(value))
PY
if python3 "$repo_root/Tools/validate-composition.py" --repo-root "$ceiling_root" \
    --profile "$ceiling_root/Profiles/esp32c6-sensor-node-mqtt/profile.json" >"$tmp/nolimits.log" 2>&1; then
    echo "FAIL: a transport without limits was accepted" >&2
    exit 1
fi
grep -F "limits must declare exactly maxTopicLength, maxPayloadSize" "$tmp/nolimits.log" >/dev/null || {
    cat "$tmp/nolimits.log" >&2
    echo "FAIL: a transport without limits was rejected for an unexpected reason" >&2
    exit 1
}

# zenoh-pico reassembles at most FRAG_MAX_SIZE bytes, silently dropping more.
# The rule that sets it must hold the largest legal frame with headers, and must
# leave the smoke bounds at zenoh-pico's own default.
if command -v cmake >/dev/null 2>&1; then
    frag_size() {
        # $1 payload bound, $2 topic bound
        cmake -DPAYLOAD="$1" -DKEY="$2" -P "$tmp/frag-probe.cmake" 2>&1 | sed -n 's/^FRAG=//p'
    }
    cat > "$tmp/frag-probe.cmake" <<EOF
include("$repo_root/Platforms/esp32c6-idf/components/zenoh_pico/fragmentation.cmake")
axoloty_zenoh_pico_frag_max_size("\${PAYLOAD}" "\${KEY}" FRAG)
message("FRAG=\${FRAG}")
EOF
    [ "$(frag_size 512 128)" = 2048 ] || { echo "FAIL: FRAG_MAX_SIZE for 512/128 is not 2048" >&2; exit 1; }
    [ "$(frag_size 2048 256)" = 4096 ] || { echo "FAIL: FRAG_MAX_SIZE for 2048/256 is not zenoh-pico's 4096" >&2; exit 1; }
    for pair in "1 1" "512 128" "1000 100" "2048 256"; do
        set -- $pair
        # The largest frame plus 512 bytes of headers must fit.
        [ "$(frag_size "$1" "$2")" -ge $(($1 + $2 + 512)) ] || {
            echo "FAIL: FRAG_MAX_SIZE for $1/$2 cannot hold the largest frame and its headers" >&2
            exit 1
        }
    done
    frag_note="FRAG_MAX_SIZE holds the largest frame and headers"
else
    echo "SKIP: cmake is absent, so the zenoh-pico FRAG_MAX_SIZE rule was not evaluated" >&2
    frag_note="FRAG_MAX_SIZE rule SKIPPED (no cmake)"
fi

python3 - "$repo_root/Applications/device-smoke-agent/app.json" "$tmp/invalid.json" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["requirements"]["carrier"].append("missing.required.capability")
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
if python3 "$repo_root/Tools/validate-composition.py" --repo-root "$repo_root" \
    --app-manifest "$tmp/invalid.json" --emit-requirements "$tmp/Requirements.swift" \
    >"$tmp/invalid.log" 2>&1; then
    echo "FAIL: invalid required capability was accepted" >&2
    exit 1
fi
grep -F "unknown carrier capability name: missing.required.capability" "$tmp/invalid.log" >/dev/null || {
    cat "$tmp/invalid.log" >&2
    echo "FAIL: invalid capability was rejected for an unexpected reason" >&2
    exit 1
}
python3 - "$repo_root/Profiles/esp32c6-mqtt/profile.json" "$tmp/misspelled.json" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["budgest"] = value.pop("budgets")
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
if python3 "$repo_root/Tools/validate-composition.py" --repo-root "$repo_root" \
    --profile "$tmp/misspelled.json" >"$tmp/misspelled.log" 2>&1; then
    echo "FAIL: misspelled profile key was accepted" >&2
    exit 1
fi
grep -F "unknown top-level key: budgest" "$tmp/misspelled.log" >/dev/null || {
    cat "$tmp/misspelled.log" >&2
    echo "FAIL: misspelled profile key was rejected for an unexpected reason" >&2
    exit 1
}
echo "profile composition: MQTT and Zenoh pass for smoke and sensor-node; carrier bounds follow the application, a capacity above a transport ceiling is rejected, $frag_note; invalid required capability and misspelled profile key are rejected"
