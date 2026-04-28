#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_FILE="${ROOT_DIR}/FptnVPN.xcodeproj"
DERIVED_DATA_PATH="${FPTN_DERIVED_DATA_PATH:-${ROOT_DIR}/.build/DerivedData}"
TMP_ROOT="${FPTN_TMPDIR:-${ROOT_DIR}/.build/tmp}"
CONFIGURATION="Debug"
SCHEME="FptnVPN"
SDK="iphonesimulator"
DESTINATION="generic/platform=iOS Simulator"
NATIVE_TARGET="ios-simulator"
BUILD_NATIVE="if-missing"
REGENERATE_PROJECT=1
ONLY_ACTIVE_ARCH="YES"
ARCHS_OVERRIDE=""

usage() {
    cat <<'USAGE'
Usage: ./build.sh [options]

Options:
  --debug                  Build Debug configuration (default)
  --release                Build Release configuration
  --scheme NAME            Xcode scheme to build (default: FptnVPN)
  --sdk NAME               xcodebuild SDK (default: iphonesimulator)
  --destination VALUE      xcodebuild destination (default: generic/platform=iOS Simulator)
  --native-target NAME     Native build target if framework is missing (default: ios-simulator)
  --native-always          Always build fptn_native_lib before xcodebuild
  --native-skip            Do not build/check fptn_native_lib in this wrapper
  --no-xcodegen            Skip xcodegen generate
  --all-archs              Build all valid architectures instead of active arch only
  --derived-data PATH      xcodebuild DerivedData path (default: .build/DerivedData)
  -h, --help               Show this help

Examples:
  ./build.sh
  ./build.sh --release
  ./build.sh --scheme Fptn-tvOS --sdk appletvsimulator --destination 'generic/platform=tvOS Simulator' --native-target tvos-simulator
  ./build.sh --scheme Fptn-macOS --sdk macosx --destination 'platform=macOS' --native-target macos
USAGE
}

log() {
    printf '\033[1;34m==>\033[0m %s\n' "$*"
}

fail() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

framework_binary() {
    local framework_path="$1"

    if [ -f "${framework_path}/Versions/1.0.0/fptn_native_lib" ]; then
        printf '%s\n' "${framework_path}/Versions/1.0.0/fptn_native_lib"
    else
        printf '%s\n' "${framework_path}/fptn_native_lib"
    fi
}

framework_is_built() {
    local framework_path="$1"
    local binary_path

    binary_path="$(framework_binary "$framework_path")"
    [ -d "$framework_path" ] && [ -s "$binary_path" ]
}

expected_native_platform() {
    case "$NATIVE_TARGET" in
        ios|ios-device) printf '%s\n' "IOS" ;;
        ios-simulator) printf '%s\n' "IOSSIMULATOR" ;;
        tvos|tvos-device) printf '%s\n' "TVOS" ;;
        tvos-simulator) printf '%s\n' "TVOSSIMULATOR" ;;
        macos) printf '%s\n' "MACOS" ;;
        *) printf '%s\n' "" ;;
    esac
}

framework_matches_native_target() {
    local framework_path="$1"
    local expected_platform
    local binary_path

    framework_is_built "$framework_path" || return 1

    expected_platform="$(expected_native_platform)"
    if command -v vtool >/dev/null && [ -n "$expected_platform" ]; then
        binary_path="$(framework_binary "$framework_path")"
        vtool -show-build "$binary_path" 2>/dev/null | awk -v platform="$expected_platform" '$1 == "platform" && $2 == platform { found = 1 } END { exit found ? 0 : 1 }' || return 1
    fi
}

native_framework_paths() {
    case "$NATIVE_TARGET" in
        ios|ios-device|ios-simulator)
            printf '%s\n' "${ROOT_DIR}/FptnVPN/Cpp/fptn_native_lib.framework"
            ;;
        tvos|tvos-device|tvos-simulator)
            printf '%s\n' "${ROOT_DIR}/Fptn-tvOS/Cpp/fptn_native_lib.framework"
            printf '%s\n' "${ROOT_DIR}/Fptn-tvOS-Tunnel/Cpp/fptn_native_lib.framework"
            ;;
        macos)
            printf '%s\n' "${ROOT_DIR}/Fptn-macOS/Cpp/fptn_native_lib.framework"
            printf '%s\n' "${ROOT_DIR}/Fptn-macOS-Tunnel/Cpp/fptn_native_lib.framework"
            ;;
        all|apple|all-apple)
            printf '%s\n' "${ROOT_DIR}/FptnVPN/Cpp/fptn_native_lib.framework"
            printf '%s\n' "${ROOT_DIR}/Fptn-tvOS/Cpp/fptn_native_lib.framework"
            printf '%s\n' "${ROOT_DIR}/Fptn-tvOS-Tunnel/Cpp/fptn_native_lib.framework"
            printf '%s\n' "${ROOT_DIR}/Fptn-macOS/Cpp/fptn_native_lib.framework"
            printf '%s\n' "${ROOT_DIR}/Fptn-macOS-Tunnel/Cpp/fptn_native_lib.framework"
            ;;
        *)
            fail "unknown native target '${NATIVE_TARGET}'"
            ;;
    esac
}

native_is_built() {
    local path

    while IFS= read -r path; do
        framework_matches_native_target "$path" || return 1
    done < <(native_framework_paths)

    return 0
}

filter_xcodebuild_output() {
    awk '
        BEGIN { showing = 0; symbol_block = 0 }
        /^Failed frontend command:/ { next }
        /^SwiftDriverJobDiscovery / || /^SwiftDriver/ { next }
        /^SwiftCompile normal / && /\/Applications\/Xcode/ { next }
        /^    cd / { next }
        /^    builtin-/ { next }
        /^    / && /Applications.Xcode/ && /swift/ { next }
        /^    / && /Applications.Xcode/ && /clang/ { next }
        /^    / && /Applications.Xcode/ && /ld/ { next }
        /^    [-[:alnum:]_]+/ && showing == 0 { next }
        /^\*\* BUILD/ { print; next }
        /^Undefined symbols/ { print; symbol_block = 1; next }
        symbol_block && /^ld: symbol/ { print; next }
        symbol_block && /^  "_/ { print; next }
        symbol_block && /^      / { print; next }
        symbol_block && /^$/ { symbol_block = 0; next }
        /^error:/ || / error: / || /:[0-9]+:[0-9]+: error:/ { print; showing = 2; next }
        /^warning:/ || / warning: / || /:[0-9]+:[0-9]+: warning:/ { print; showing = 2; next }
        /^note:/ && showing > 0 { print; next }
        /^Resolve Package Graph/ { print; next }
        /^Resolved source packages:/ { print; showing = 8; next }
        /^Package: / { print; next }
        /^SwiftCompile / || /^CompileC / || /^Ld / || /^PhaseScriptExecution / || /^ProcessInfoPlistFile / || /^CodeSign / {
            phase = $1
            target = ""
            if (match($0, /\(in target '\''[^'\'']+'\'' from project '\''[^'\'']+'\''\)/)) {
                target = substr($0, RSTART, RLENGTH)
            }
            key = phase target
            if (!seen[key]++) {
                print phase " " target
            }
            next
        }
        showing > 0 { print; showing--; next }
    '
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --debug)
            CONFIGURATION="Debug"
            shift
            ;;
        --release)
            CONFIGURATION="Release"
            shift
            ;;
        --scheme)
            [ "$#" -ge 2 ] || fail "--scheme requires a value"
            SCHEME="$2"
            shift 2
            ;;
        --sdk)
            [ "$#" -ge 2 ] || fail "--sdk requires a value"
            SDK="$2"
            shift 2
            ;;
        --destination)
            [ "$#" -ge 2 ] || fail "--destination requires a value"
            DESTINATION="$2"
            shift 2
            ;;
        --native-target)
            [ "$#" -ge 2 ] || fail "--native-target requires a value"
            NATIVE_TARGET="$2"
            shift 2
            ;;
        --native-always)
            BUILD_NATIVE="always"
            shift
            ;;
        --native-skip)
            BUILD_NATIVE="skip"
            shift
            ;;
        --no-xcodegen)
            REGENERATE_PROJECT=0
            shift
            ;;
        --all-archs)
            ONLY_ACTIVE_ARCH="NO"
            ARCHS_OVERRIDE=""
            shift
            ;;
        --derived-data)
            [ "$#" -ge 2 ] || fail "--derived-data requires a value"
            DERIVED_DATA_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument '$1'"
            ;;
    esac
done

[ -f "${ROOT_DIR}/project.yml" ] || fail "project.yml not found"
[ -x "${ROOT_DIR}/build_fptn_lib.sh" ] || fail "build_fptn_lib.sh is missing or not executable"
command -v xcodebuild >/dev/null || fail "xcodebuild not found"
mkdir -p "$TMP_ROOT"
export TMPDIR="${TMP_ROOT}/"

if [ "$REGENERATE_PROJECT" = "1" ]; then
    command -v xcodegen >/dev/null || fail "xcodegen not found"
    log "Regenerating Xcode project"
    (cd "$ROOT_DIR" && xcodegen generate)
fi

if [ "$BUILD_NATIVE" = "always" ]; then
    log "Building native library (${NATIVE_TARGET})"
    (cd "$ROOT_DIR" && FPTN_SKIP_NATIVE_CODESIGN=1 ./build_fptn_lib.sh "$NATIVE_TARGET")
elif [ "$BUILD_NATIVE" = "if-missing" ]; then
    if native_is_built; then
        log "Native library already present (${NATIVE_TARGET})"
    else
        log "Native library missing; building ${NATIVE_TARGET}"
        (cd "$ROOT_DIR" && FPTN_SKIP_NATIVE_CODESIGN=1 ./build_fptn_lib.sh "$NATIVE_TARGET")
    fi
fi

log "Building ${SCHEME} (${CONFIGURATION}, ${SDK})"
mkdir -p "$DERIVED_DATA_PATH"

if [ -z "$ARCHS_OVERRIDE" ] && [ "$ONLY_ACTIVE_ARCH" = "YES" ]; then
    case "$SDK" in
        iphonesimulator|appletvsimulator)
            ARCHS_OVERRIDE="$(uname -m)"
            ;;
    esac
fi

XCODEBUILD_SETTINGS=(
    "ONLY_ACTIVE_ARCH=${ONLY_ACTIVE_ARCH}"
    "FPTN_NATIVE_BUILD_IF_MISSING=1"
    "FPTN_NATIVE_TARGET=${NATIVE_TARGET}"
    "FPTN_SKIP_NATIVE_CODESIGN=1"
)

if [ -n "$ARCHS_OVERRIDE" ]; then
    XCODEBUILD_SETTINGS+=("ARCHS=${ARCHS_OVERRIDE}")
fi

set +e
(
    cd "$ROOT_DIR"
    NSUnbufferedIO=YES xcodebuild \
        -project "$PROJECT_FILE" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -sdk "$SDK" \
        -destination "$DESTINATION" \
        "${XCODEBUILD_SETTINGS[@]}" \
        build 2>&1
) | filter_xcodebuild_output
status=${PIPESTATUS[0]}
set -e

if [ "$status" -eq 0 ]; then
    log "Build succeeded"
else
    fail "xcodebuild failed with exit code ${status}"
fi
