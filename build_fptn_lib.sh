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

TARGET="${1:-ios-device}"

resolve_framework_binary() {
    local framework_path="$1"
    if [ -f "${framework_path}/Versions/1.0.0/fptn_native_lib" ]; then
        echo "${framework_path}/Versions/1.0.0/fptn_native_lib"
    else
        echo "${framework_path}/fptn_native_lib"
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
        "ios-simulator"
        "ios-device"
        "tvos-simulator"
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
        OUTPUT_DIR="build-ios"
        DEST_DIR="${ROOT_DIR}/FptnVPN/Cpp"
        SECONDARY_DEST_DIR=""
        MIN_PLATFORM_VERSION="17.0"
        echo "Building fptn_native_lib for iOS device..."
        ;;
    ios-simulator)
        HOST_PROFILE="conan-simulator-profile"
        OUTPUT_DIR="build-simulator"
        DEST_DIR="${ROOT_DIR}/FptnVPN/Cpp"
        SECONDARY_DEST_DIR=""
        MIN_PLATFORM_VERSION="17.0"
        echo "Building fptn_native_lib for iOS simulator..."
        ;;
    tvos|tvos-device)
        HOST_PROFILE="conan-tvos-profile"
        OUTPUT_DIR="build-tvos"
        DEST_DIR="${ROOT_DIR}/Fptn-tvOS/Cpp"
        SECONDARY_DEST_DIR="${ROOT_DIR}/Fptn-tvOS-Tunnel/Cpp"
        MIN_PLATFORM_VERSION="15.6"
        echo "Building fptn_native_lib for tvOS device..."
        ;;
    tvos-simulator)
        HOST_PROFILE="conan-tvos-simulator-profile"
        OUTPUT_DIR="build-tvos-simulator"
        DEST_DIR="${ROOT_DIR}/Fptn-tvOS/Cpp"
        SECONDARY_DEST_DIR="${ROOT_DIR}/Fptn-tvOS-Tunnel/Cpp"
        MIN_PLATFORM_VERSION="15.6"
        echo "Building fptn_native_lib for tvOS simulator..."
        ;;
    macos)
        HOST_PROFILE="conan-macos-profile"
        OUTPUT_DIR="build-macos"
        DEST_DIR="${ROOT_DIR}/Fptn-macOS/Cpp"
        SECONDARY_DEST_DIR=""
        MIN_PLATFORM_VERSION=""
        echo "Building fptn_native_lib for macOS (universal)..."
        ;;
    *)
        echo "Usage: $0 [all|apple|all-apple|ios-device|ios-simulator|tvos-device|tvos-simulator|macos]"
        exit 1
        ;;
esac

cd "$LIB_DIR"

if [ "$TARGET" = "macos" ]; then
    # ── arm64 slice ──────────────────────────────────────────────────────────
    ARM64_DIR="build-macos"
    echo "Building arm64 slice..."
    conan install . --profile:host="conan-macos-profile" --profile:build=default --build=missing --output-folder="$ARM64_DIR"
    cd "$ARM64_DIR"
    cmake .. -DCMAKE_TOOLCHAIN_FILE=./build/Debug/generators/conan_toolchain.cmake \
             -DCMAKE_BUILD_TYPE=Debug \
             -DCMAKE_OSX_ARCHITECTURES=arm64
    cmake --build . --config Debug
    cd "$LIB_DIR"

    # ── x86_64 slice ─────────────────────────────────────────────────────────
    X86_DIR="build-macos-x86_64"
    echo "Building x86_64 slice..."
    conan install . --profile:host="conan-macos-x86_64-profile" --profile:build=default --build=missing --output-folder="$X86_DIR"
    cd "$X86_DIR"
    cmake .. -DCMAKE_TOOLCHAIN_FILE=./build/Debug/generators/conan_toolchain.cmake \
             -DCMAKE_BUILD_TYPE=Debug \
             -DCMAKE_OSX_ARCHITECTURES=x86_64
    cmake --build . --config Debug
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

        SIGN_IDENTITY="${FPTN_CODESIGN_IDENTITY:--}"
        echo "Signing ${DEST}/fptn_native_lib.framework with identity: ${SIGN_IDENTITY}"
        codesign --force --sign "${SIGN_IDENTITY}" "${DEST}/fptn_native_lib.framework"
    done

    copy_dsym_to_archive_products "${UNIVERSAL_FW}.dSYM"

    rm -rf "$UNIVERSAL_FW"
    rm -rf "${UNIVERSAL_FW}.dSYM"
    echo "Build complete. Universal framework copied to:"
    echo "  ${DEST_DIR}/fptn_native_lib.framework"
    echo "  ${TUNNEL_DEST_DIR}/fptn_native_lib.framework"
    exit 0
fi

conan install . --profile:host="$HOST_PROFILE" --profile:build=default --build=missing --output-folder="$OUTPUT_DIR"

cd "$OUTPUT_DIR"
cmake .. -DCMAKE_TOOLCHAIN_FILE=./build/Debug/generators/conan_toolchain.cmake -DCMAKE_BUILD_TYPE=Debug
cmake --build . --config Debug
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

    SIGN_IDENTITY="${FPTN_CODESIGN_IDENTITY:--}"
    echo "Signing ${destination}/fptn_native_lib.framework with identity: ${SIGN_IDENTITY}"
    codesign --force --sign "${SIGN_IDENTITY}" "${destination}/fptn_native_lib.framework"
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
