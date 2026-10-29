#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Shared post-link gate for ESP-IDF images. Arguments: repository root,
# selected app directory, profile name, build directory, evidence directory,
# and platform-selected archive owner.
set -eu

if [ "$#" -ne 6 ]; then
    echo "usage: static-storage-build-gate.sh REPO APP PROFILE BUILD EVIDENCE ARCHIVE_OWNER" >&2
    exit 64
fi
repo_root=$1
app_dir=$2
profile=$3
build_dir=$4
evidence_dir=$5
archive_owner=$6
manifest="$app_dir/app.json"
inventory="$app_dir/storage-inventory.json"
elf="$build_dir/axoloty-swift.elf"
linker_map="$build_dir/axoloty-swift.map"
report="$evidence_dir/linked-static-storage-budget.json"
receipt="$evidence_dir/static-storage-policy.json"
policy_tool="$repo_root/Tools/EmbeddedApplicationMacros/static_storage_policy.py"
auditor="$repo_root/Tools/EmbeddedApplicationMacros/linked_storage_audit.py"

rm -f "$report" "$receipt"
policy=$(python3 "$policy_tool" --cache "$build_dir/CMakeCache.txt" \
    --app-manifest "$manifest" --inventory "$inventory")
case "$policy" in
    c-only)
        printf '{"schema":"axoloty.app-static-storage-policy.v1","profile":"%s","status":"not-applicable","reason":"configured C-only carrier qualification image"}\n' \
            "$profile" > "$receipt"
        echo "static-storage budget: not applicable to configured C-only image"
        exit 0
        ;;
    swift-not-configured)
        printf '{"schema":"axoloty.app-static-storage-policy.v1","profile":"%s","status":"not-configured"}\n' \
            "$profile" > "$receipt"
        echo "static-storage budget: policy not configured for selected app"
        exit 0
        ;;
    swift-configured:*)
        map_member=${policy#swift-configured:}
        ;;
    *)
        echo "static-storage policy: unexpected classification: $policy" >&2
        exit 2
        ;;
esac

if [ ! -f "$elf" ] || [ ! -f "$linker_map" ]; then
    echo "error: final Swift ELF/map are required for configured static-storage enforcement" >&2
    exit 1
fi
# The selected transport declares the build's wire profile. Inventory entries
# scoped to another profile are not expected in this image.
wire_profile_args=""
if [ -n "${AXOLOTY_TRANSPORT_DIR:-}" ] && [ -f "$AXOLOTY_TRANSPORT_DIR/transport.json" ]; then
    wire_profile=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("wireProfile",""))' \
        "$AXOLOTY_TRANSPORT_DIR/transport.json")
    [ -z "$wire_profile" ] || wire_profile_args="--wire-profile $wire_profile"
fi
# The archive owner comes from the platform launcher. The selected member
# comes only from the app's SDK-neutral storage inventory.
python3 "$auditor" \
    --elf "$elf" \
    --map "$linker_map" \
    --combined-object "$archive_owner($map_member)" \
    --profile "$profile" \
    $wire_profile_args \
    --app-manifest "$manifest" \
    --enforce-static-storage-budget \
    --inventory "$inventory" \
    --output "$report"
printf '{"schema":"axoloty.app-static-storage-policy.v1","profile":"%s","status":"enforced","report":"linked-static-storage-budget.json"}\n' \
    "$profile" > "$receipt"
echo "static-storage budget: $report"
