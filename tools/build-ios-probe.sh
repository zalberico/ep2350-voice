#!/bin/bash
# Build only: no signing, provisioning, simulator boot, or device installation.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_kind="${1:-all}"
if [[ $# -gt 1 || ! "$build_kind" =~ ^(all|device|simulator)$ ]]; then
    printf 'Usage: %s [all|device|simulator]\n' "$0" >&2
    exit 2
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

build_root="${EP2350_IOS_BUILD_DIR:-$repo_dir/.build/ios-probe}"
mkdir -p "$build_root"
build_root="$(cd "$build_root" && pwd)"
mkdir -p "$build_root/logs" "$build_root/module-cache"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"

build_app() {
    local kind="$1"
    local sdk="$2"
    local destination="$3"
    local product_directory="$4"
    local log_file="$build_root/logs/$kind.log"
    printf 'Building unsigned iOS probe for %s…\n' "$kind"
    if ! xcodebuild \
        -project "$repo_dir/ios/EP2350Probe.xcodeproj" \
        -scheme EP2350Probe \
        -configuration Debug \
        -sdk "$sdk" \
        -destination "$destination" \
        -derivedDataPath "$build_root/$kind" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY= \
        "CLANG_MODULE_CACHE_PATH=$build_root/module-cache" \
        "SWIFT_MODULE_CACHE_PATH=$build_root/module-cache" \
        build >"$log_file" 2>&1; then
        tail -n 80 "$log_file" >&2
        printf 'Build failed. Full log: %s\n' "$log_file" >&2
        return 1
    fi
    printf 'Built %s\n' "$build_root/$kind/Build/Products/$product_directory/EP2350Probe.app"
    printf 'Build log: %s\n' "$log_file"
}

if [[ "$build_kind" == all || "$build_kind" == device ]]; then
    build_app device iphoneos 'generic/platform=iOS' Debug-iphoneos
fi
if [[ "$build_kind" == all || "$build_kind" == simulator ]]; then
    build_app simulator iphonesimulator 'generic/platform=iOS Simulator' Debug-iphonesimulator
fi
