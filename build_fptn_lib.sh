#!/bin/bash
set -euo pipefail

# PATH setup (homebrew is often not in Xcode's PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v conan &> /dev/null || ! command -v cmake &> /dev/null; then
    echo "error: conan or cmake not found in PATH. Please install them to build FptnLib."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
ROOT_DIR="${SRCROOT:-${SCRIPT_DIR}}"
LIB_DIR="${ROOT_DIR}/FptnLib"

resolve_default_target() {
    if [ -n "${FPTN_NATIVE_TARGET:-}" ]; then
        echo "$FPTN_NATIVE_TARGET"
        return
    fi

    case "${PLATFORM_NAME:-}" in
        iphonesimulator)
            echo "ios-simulator"
            ;;
        iphoneos)
            echo "ios-device"
            ;;
        appletvsimulator)
            echo "tvos-simulator"
            ;;
        appletvos)
            echo "tvos-device"
            ;;
        macosx)
            echo "macos"
            ;;
        *)
            echo "ios-device"
            ;;
    esac
}

TARGET="${1:-$(resolve_default_target)}"

# PR0: map Xcode configuration to CMake build type.
# Debug → Debug, Release/Measurement → MinSizeRel.
# Absent $CONFIGURATION (manual invocation) defaults to Debug.
# Unknown named configurations fail to prevent silent misbuilds.
resolve_build_type() {
    case "${CONFIGURATION:-}" in
        "")
            echo "Debug"
            ;;
        Debug)
            echo "Debug"
            ;;
        Release|Measurement)
            echo "MinSizeRel"
            ;;
        *)
            echo "error: unknown CONFIGURATION '${CONFIGURATION}'. Expected Debug, Release, or Measurement." >&2
            exit 1
            ;;
    esac
}

BUILD_TYPE="$(resolve_build_type)"

# PR1A: iOS socket buffer experiment parameter.
# 0 = kernel default. Override: FPTN_IOS_SOCKET_BUFFER_BYTES=262144
SOCKET_BUFFER_BYTES="${FPTN_IOS_SOCKET_BUFFER_BYTES:-0}"
case "$SOCKET_BUFFER_BYTES" in
    0|262144|524288) ;;
    *)
        echo "error: invalid FPTN_IOS_SOCKET_BUFFER_BYTES=$SOCKET_BUFFER_BYTES (expected 0, 262144, or 524288)" >&2
        exit 1
        ;;
esac

# `set(... CACHE)` in the conan toolchain never overrides an existing cache
# entry, so a stale CMAKE_OSX_DEPLOYMENT_TARGET (e.g. 17.0) would silently
# win and bake the wrong minos into the binary. Wipe it on mismatch instead.
purge_stale_cmake_cache() {
    local build_dir="$1"
    if [ -f "${build_dir}/CMakeCache.txt" ] &&
       ! grep -q "CMAKE_OSX_DEPLOYMENT_TARGET:STRING=${DEPLOYMENT_TARGET}" "${build_dir}/CMakeCache.txt"; then
        echo "Stale CMake cache (deployment target mismatch); purging ${build_dir}/CMakeCache.txt"
        rm -f "${build_dir}/CMakeCache.txt"
        rm -rf "${build_dir}/CMakeFiles"
    fi
}

resolve_framework_binary() {
    local framework_path="$1"
    if [ -f "${framework_path}/Versions/1.0.0/fptn_native_lib" ]; then
        echo "${framework_path}/Versions/1.0.0/fptn_native_lib"
    else
        echo "${framework_path}/fptn_native_lib"
    fi
}

framework_is_built() {
    local framework_path="$1"
    local binary_path

    binary_path="$(resolve_framework_binary "${framework_path}")"
    [ -d "${framework_path}" ] && [ -s "${binary_path}" ]
}

framework_matches_target() {
    local framework_path="$1"
    local expected_platform="$2"
    local binary_path

    framework_is_built "$framework_path" || return 1

    if command -v vtool >/dev/null && [ -n "$expected_platform" ]; then
        binary_path="$(resolve_framework_binary "${framework_path}")"
        vtool -show-build "$binary_path" 2>/dev/null | awk -v platform="$expected_platform" '$1 == "platform" && $2 == platform { found = 1 } END { exit found ? 0 : 1 }'
    fi
}

generate_framework_dsym() {
    local framework_path="$1"
    local dsym_path="${framework_path}.dSYM"
    local binary_path

    binary_path="$(resolve_framework_binary "${framework_path}")"
    if [ ! -f "${binary_path}" ]; then
        echo "warning: framework binary not found for dSYM generation: ${binary_path}"
        return 1
    fi

    rm -rf "${dsym_path}"
    echo "Generating dSYM for ${framework_path}..."
    dsymutil "${binary_path}" -o "${dsym_path}"
}

copy_dsym_to_archive_products() {
    local dsym_path="$1"

    if [ -n "${DWARF_DSYM_FOLDER_PATH:-}" ] && [ -d "${dsym_path}" ]; then
        mkdir -p "${DWARF_DSYM_FOLDER_PATH}"
        rm -rf "${DWARF_DSYM_FOLDER_PATH}/$(basename "${dsym_path}")"
        cp -R "${dsym_path}" "${DWARF_DSYM_FOLDER_PATH}/"
    fi
}

copy_existing_dsym_to_archive_products() {
    local candidate
    local candidates=(
        "${DEST_DIR}/fptn_native_lib.framework.dSYM"
        "${LIB_DIR}/${OUTPUT_DIR}/fptn_native_lib.framework.dSYM"
    )

    if [ "$TARGET" = "ios-device" ] || [ "$TARGET" = "ios" ]; then
        candidates+=("${LIB_DIR}/build-ios-release/fptn_native_lib.framework.dSYM")
    fi

    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate" ]; then
            copy_dsym_to_archive_products "$candidate"
            return 0
        fi
    done

    echo "warning: fptn_native_lib.framework.dSYM not found; App Store symbol upload may warn."
}

sync_ios_release_output() {
    local source_framework_dir="$1"
    local source_dsym_dir="$2"
    local release_dir="${LIB_DIR}/build-ios-release"

    mkdir -p "${release_dir}"
    rm -rf "${release_dir}/fptn_native_lib.framework"
    cp -R "${source_framework_dir}" "${release_dir}/"
    rm -rf "${release_dir}/fptn_native_lib.framework.dSYM"
    cp -R "${source_dsym_dir}" "${release_dir}/"
}

run_aggregate_build() {
    local aggregate_name="$1"
    local target_name
    local targets=(
        "ios-device"
        "tvos-device"
        "macos"
    )

    echo "Building all Apple frameworks (${aggregate_name})..."
    echo "Build order keeps copied iOS/tvOS frameworks on device slices."

    for target_name in "${targets[@]}"; do
        echo
        echo "==== ${target_name} ===="
        "${SCRIPT_PATH}" "${target_name}"
    done

    echo
    echo "Build complete for all Apple frameworks."
    exit 0
}

case "$TARGET" in
    all|apple|all-apple)
        run_aggregate_build "$TARGET"
        ;;
    ios|ios-device)
        HOST_PROFILE="conan-device-profile"
        OUTPUT_DIR="build-ios-${BUILD_TYPE}"
        DEST_DIR="${ROOT_DIR}/FptnVPN/Cpp"
        SECONDARY_DEST_DIR=""
        MIN_PLATFORM_VERSION="16.0"
        DEPLOYMENT_TARGET="16.0"
        echo "Building fptn_native_lib for iOS device..."
        ;;
    ios-simulator)
        HOST_PROFILE="conan-simulator-profile"
        OUTPUT_DIR="build-simulator-${BUILD_TYPE}"
        DEST_DIR="${ROOT_DIR}/FptnVPN/Cpp"
        SECONDARY_DEST_DIR=""
        MIN_PLATFORM_VERSION="16.0"
        DEPLOYMENT_TARGET="16.0"
        echo "Building fptn_native_lib for iOS simulator..."
        ;;
    tvos|tvos-device)
        HOST_PROFILE="conan-tvos-profile"
        OUTPUT_DIR="build-tvos-${BUILD_TYPE}"
        DEST_DIR="${ROOT_DIR}/Fptn-tvOS/Cpp"
        SECONDARY_DEST_DIR="${ROOT_DIR}/Fptn-tvOS-Tunnel/Cpp"
        MIN_PLATFORM_VERSION="15.6"
        DEPLOYMENT_TARGET="15.6"
        echo "Building fptn_native_lib for tvOS device..."
        ;;
    tvos-simulator)
        HOST_PROFILE="conan-tvos-simulator-profile"
        OUTPUT_DIR="build-tvos-simulator-${BUILD_TYPE}"
        DEST_DIR="${ROOT_DIR}/Fptn-tvOS/Cpp"
        SECONDARY_DEST_DIR="${ROOT_DIR}/Fptn-tvOS-Tunnel/Cpp"
        MIN_PLATFORM_VERSION="15.6"
        DEPLOYMENT_TARGET="15.6"
        echo "Building fptn_native_lib for tvOS simulator..."
        ;;
    macos)
        HOST_PROFILE="conan-macos-profile"
        OUTPUT_DIR="build-macos-${BUILD_TYPE}"
        DEST_DIR="${ROOT_DIR}/Fptn-macOS/Cpp"
        SECONDARY_DEST_DIR=""
        MIN_PLATFORM_VERSION=""
        DEPLOYMENT_TARGET="13.0"
        echo "Building fptn_native_lib for macOS (universal)..."
        ;;
    *)
        echo "Usage: $0 [all|apple|all-apple|ios-device|ios-simulator|tvos-device|tvos-simulator|macos]"
        exit 1
        ;;
esac

if [ "${FPTN_NATIVE_BUILD_IF_MISSING:-0}" = "1" ]; then
    EXPECTED_PLATFORM=""
    case "$TARGET" in
        ios|ios-device) EXPECTED_PLATFORM="IOS" ;;
        ios-simulator) EXPECTED_PLATFORM="IOSSIMULATOR" ;;
        tvos|tvos-device) EXPECTED_PLATFORM="TVOS" ;;
        tvos-simulator) EXPECTED_PLATFORM="TVOSSIMULATOR" ;;
        macos) EXPECTED_PLATFORM="MACOS" ;;
    esac

    # PR0: validate full cache identity via the build manifest so a
    # stale framework is never silently reused. Checks configuration,
    # fptn commit, wrapper source hash, and build-file hash.
    manifest_matches() {
        local manifest_path="$1/fptn_native_lib.build-manifest.json"
        [ -f "$manifest_path" ] || return 1

        local current_fptn_commit current_wrapper_hash current_build_hash current_compiler_id
        current_fptn_commit="$(git -C "${LIB_DIR}/fptn" rev-parse HEAD 2>/dev/null || echo unknown)"
        current_wrapper_hash="$(find "${LIB_DIR}/src" -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) -print0 2>/dev/null | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}')"
        current_build_hash="$(
            {
                printf '%s\n' \
                    "${SCRIPT_PATH}" \
                    "${LIB_DIR}/CMakeLists.txt" \
                    "${LIB_DIR}/conanfile.py" \
                    "${LIB_DIR}/Info.plist.in"
                find "${LIB_DIR}" -maxdepth 1 -type f -name 'conan-*-profile' -print
            } | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}'
        )"
        current_compiler_id="$(xcrun clang++ --version 2>/dev/null | head -1 || echo unknown)"

        grep -q "\"configuration\": \"${BUILD_TYPE}\"" "$manifest_path" 2>/dev/null || return 1
        grep -q "\"fptn_commit\": \"${current_fptn_commit}\"" "$manifest_path" 2>/dev/null || return 1
        grep -q "\"wrapper_hash\": \"${current_wrapper_hash}\"" "$manifest_path" 2>/dev/null || return 1
        grep -q "\"build_hash\": \"${current_build_hash}\"" "$manifest_path" 2>/dev/null || return 1
        grep -Fq "\"compiler\": \"${current_compiler_id}\"" "$manifest_path" 2>/dev/null || return 1
        grep -q "\"ios_socket_buffer_bytes\": ${SOCKET_BUFFER_BYTES}" "$manifest_path" 2>/dev/null || return 1
        return 0
    }

    if framework_matches_target "${DEST_DIR}/fptn_native_lib.framework" "$EXPECTED_PLATFORM" &&
       manifest_matches "$DEST_DIR" &&
       { [ -z "$SECONDARY_DEST_DIR" ] || framework_matches_target "${SECONDARY_DEST_DIR}/fptn_native_lib.framework" "$EXPECTED_PLATFORM"; }; then
        echo "fptn_native_lib already built for ${TARGET} (${BUILD_TYPE}); skipping native build."
        copy_existing_dsym_to_archive_products
        exit 0
    fi
fi

cd "$LIB_DIR"

if [ "$TARGET" = "macos" ]; then
    # ── arm64 slice ──────────────────────────────────────────────────────────
    ARM64_DIR="build-macos-${BUILD_TYPE}"
    echo "Building arm64 slice (${BUILD_TYPE})..."
    conan install . --profile:host="conan-macos-profile" --profile:build=conan-macos-profile --build=missing --output-folder="$ARM64_DIR" -s build_type="$BUILD_TYPE" -o "fptn/*:ios_socket_buffer_bytes=${SOCKET_BUFFER_BYTES}"
    purge_stale_cmake_cache "$ARM64_DIR"
    cd "$ARM64_DIR"
    cmake .. -DCMAKE_TOOLCHAIN_FILE=./build/${BUILD_TYPE}/generators/conan_toolchain.cmake \
             -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
             -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
             -DCMAKE_OSX_ARCHITECTURES=arm64
    rm -rf fptn_native_lib.framework fptn_native_lib.framework.dSYM
    cmake --build . --config "$BUILD_TYPE"
    cd "$LIB_DIR"

    # ── x86_64 slice ─────────────────────────────────────────────────────────
    X86_DIR="build-macos-x86_64-${BUILD_TYPE}"
    echo "Building x86_64 slice (${BUILD_TYPE})..."
    conan install . --profile:host="conan-macos-x86_64-profile" --profile:build=conan-macos-profile --build=missing --output-folder="$X86_DIR" -s build_type="$BUILD_TYPE" -o "fptn/*:ios_socket_buffer_bytes=${SOCKET_BUFFER_BYTES}"
    purge_stale_cmake_cache "$X86_DIR"
    cd "$X86_DIR"
    cmake .. -DCMAKE_TOOLCHAIN_FILE=./build/${BUILD_TYPE}/generators/conan_toolchain.cmake \
             -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
             -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
             -DCMAKE_OSX_ARCHITECTURES=x86_64
    rm -rf fptn_native_lib.framework fptn_native_lib.framework.dSYM
    cmake --build . --config "$BUILD_TYPE"
    cd "$LIB_DIR"

    # ── Combine into universal binary with lipo ───────────────────────────────
    echo "Creating universal (fat) framework with lipo..."
    # Use the arm64 framework as the base (headers, plists, etc.)
    UNIVERSAL_FW="${LIB_DIR}/fptn_native_lib.framework"
    rm -rf "$UNIVERSAL_FW"
    cp -R "${ARM64_DIR}/fptn_native_lib.framework" "$UNIVERSAL_FW"

    # Resolve the actual (non-symlink) binary path within the framework
    if [ -f "${ARM64_DIR}/fptn_native_lib.framework/Versions/1.0.0/fptn_native_lib" ]; then
        INNER_BIN="Versions/1.0.0/fptn_native_lib"
    else
        INNER_BIN="fptn_native_lib"
    fi

    lipo -create \
        "${ARM64_DIR}/fptn_native_lib.framework/${INNER_BIN}" \
        "${X86_DIR}/fptn_native_lib.framework/${INNER_BIN}" \
        -output "${UNIVERSAL_FW}/${INNER_BIN}"

    generate_framework_dsym "${UNIVERSAL_FW}"

    # ── Copy to all macOS destination directories ─────────────────────────────
    TUNNEL_DEST_DIR="${ROOT_DIR}/Fptn-macOS-Tunnel/Cpp"
    for DEST in "$DEST_DIR" "$TUNNEL_DEST_DIR"; do
        mkdir -p "$DEST"
        rm -rf "${DEST}/fptn_native_lib.framework"
        cp -R "$UNIVERSAL_FW" "$DEST/"
        rm -rf "${DEST}/fptn_native_lib.framework.dSYM"

        if [ "${FPTN_SKIP_NATIVE_CODESIGN:-0}" != "1" ]; then
            SIGN_IDENTITY="${FPTN_CODESIGN_IDENTITY:--}"
            echo "Signing ${DEST}/fptn_native_lib.framework with identity: ${SIGN_IDENTITY}"
            codesign --force --sign "${SIGN_IDENTITY}" "${DEST}/fptn_native_lib.framework"
        else
            echo "Skipping native framework signing for ${DEST}; Xcode will sign the embedded copy."
        fi
    done

    copy_dsym_to_archive_products "${UNIVERSAL_FW}.dSYM"

    rm -rf "$UNIVERSAL_FW"
    rm -rf "${UNIVERSAL_FW}.dSYM"
    echo "Build complete. Universal framework copied to:"
    echo "  ${DEST_DIR}/fptn_native_lib.framework"
    echo "  ${TUNNEL_DEST_DIR}/fptn_native_lib.framework"
    exit 0
fi

conan install . --profile:host="$HOST_PROFILE" --profile:build=conan-macos-profile --build=missing --output-folder="$OUTPUT_DIR" -s build_type="$BUILD_TYPE" -o "fptn/*:ios_socket_buffer_bytes=${SOCKET_BUFFER_BYTES}"

purge_stale_cmake_cache "$OUTPUT_DIR"

cd "$OUTPUT_DIR"
cmake .. -DCMAKE_TOOLCHAIN_FILE=./build/${BUILD_TYPE}/generators/conan_toolchain.cmake -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
rm -rf fptn_native_lib.framework fptn_native_lib.framework.dSYM
cmake --build . --config "$BUILD_TYPE"
generate_framework_dsym "fptn_native_lib.framework"

if [ "$TARGET" = "ios-device" ] || [ "$TARGET" = "ios" ]; then
    sync_ios_release_output "fptn_native_lib.framework" "fptn_native_lib.framework.dSYM"
fi

copy_framework_to_dest() {
    local destination="$1"

    mkdir -p "$destination"
    rm -rf "${destination}/fptn_native_lib.framework"
    cp -R fptn_native_lib.framework "$destination/"

    local framework_plist="${destination}/fptn_native_lib.framework/Info.plist"
    if [ -n "$MIN_PLATFORM_VERSION" ] && [ -f "$framework_plist" ]; then
        echo "Adding MinimumOSVersion=${MIN_PLATFORM_VERSION} to framework Info.plist for ${destination}..."
        /usr/libexec/PlistBuddy -c "Delete :MinimumOSVersion" "$framework_plist" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string ${MIN_PLATFORM_VERSION}" "$framework_plist"
    fi

    rm -rf "${destination}/fptn_native_lib.framework.dSYM"

    # PR0: write the build manifest BESIDE the framework (not inside it)
    # BEFORE codesign, so the signature is not invalidated. The manifest
    # records full cache identity: configuration, fptn commit, wrapper
    # source hash, build-file hash, and compiler identity.
    local fptn_commit wrapper_hash build_hash compiler_id
    fptn_commit="$(git -C "${LIB_DIR}/fptn" rev-parse HEAD 2>/dev/null || echo unknown)"
    wrapper_hash="$(find "${LIB_DIR}/src" -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) -print0 2>/dev/null | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}')"
    build_hash="$(
        {
            printf '%s\n' \
                "${SCRIPT_PATH}" \
                "${LIB_DIR}/CMakeLists.txt" \
                "${LIB_DIR}/conanfile.py" \
                "${LIB_DIR}/Info.plist.in"
            find "${LIB_DIR}" -maxdepth 1 -type f -name 'conan-*-profile' -print
        } | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}'
    )"
    compiler_id="$(xcrun clang++ --version 2>/dev/null | head -1 || echo unknown)"
    cat > "${destination}/fptn_native_lib.build-manifest.json" <<MANIFEST
{
  "platform": "${TARGET}",
  "configuration": "${BUILD_TYPE}",
  "fptn_commit": "${fptn_commit}",
  "wrapper_hash": "${wrapper_hash}",
  "build_hash": "${build_hash}",
  "compiler": "${compiler_id}",
  "ios_socket_buffer_bytes": ${SOCKET_BUFFER_BYTES},
  "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
MANIFEST

    if [ "${FPTN_SKIP_NATIVE_CODESIGN:-0}" != "1" ]; then
        SIGN_IDENTITY="${FPTN_CODESIGN_IDENTITY:--}"
        echo "Signing ${destination}/fptn_native_lib.framework with identity: ${SIGN_IDENTITY}"
        codesign --force --sign "${SIGN_IDENTITY}" "${destination}/fptn_native_lib.framework"
    else
        echo "Skipping native framework signing for ${destination}; Xcode will sign the embedded copy."
    fi
}

copy_framework_to_dest "$DEST_DIR"

if [ -n "$SECONDARY_DEST_DIR" ]; then
    copy_framework_to_dest "$SECONDARY_DEST_DIR"
fi

copy_dsym_to_archive_products "fptn_native_lib.framework.dSYM"

echo "Build complete. Framework output: ${DEST_DIR}/fptn_native_lib.framework"
if [ -n "$SECONDARY_DEST_DIR" ]; then
    echo "Build complete. Framework output: ${SECONDARY_DEST_DIR}/fptn_native_lib.framework"
fi
