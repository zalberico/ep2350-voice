#!/bin/bash
# Offline signal checks only: no simulator, device, microphone, or signing access.
set -euo pipefail

if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

test_root="${EP2350_IOS_TEST_DIR:-$repo_dir/.build/ios-probe-tests}"
mkdir -p "$test_root"
test_root="$(cd "$test_root" && pwd)"
mkdir -p "$test_root/module-cache"
export CLANG_MODULE_CACHE_PATH="$test_root/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$test_root/module-cache"

xcrun --sdk macosx swiftc \
    -swift-version 5 \
    -strict-concurrency=complete \
    -module-cache-path "$test_root/module-cache" \
    "$repo_dir/Sources/FXMicCore/NativeHandleMonitor.swift" \
    "$repo_dir/Sources/FXMicCore/ChirpDetector.swift" \
    "$repo_dir/Sources/FXMicCore/Goertzel.swift" \
    "$repo_dir/Sources/FXMicCore/Levels.swift" \
    "$repo_dir/ios/EP2350ProbeCore/ProbeSignalAccumulator.swift" \
    "$repo_dir/ios/Tests/ProbeSignalAccumulatorCheck.swift" \
    -o "$test_root/ProbeSignalAccumulatorCheck"

"$test_root/ProbeSignalAccumulatorCheck"
