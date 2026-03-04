#!/bin/bash
set -euo pipefail

# PATH setup (homebrew is often not in Xcode's PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v conan &> /dev/null || ! command -v cmake &> /dev/null; then
    echo "error: conan or cmake not found in PATH. Please install them to build FptnLib."
    exit 1
fi

ROOT_DIR="${SRCROOT:-$(cd "$(dirname "$0")" && pwd)}"
LIB_DIR="${ROOT_DIR}/FptnLib"

TARGET="${1:-ios-device}"

case "$TARGET" in
    ios|ios-device)
        HOST_PROFILE="conan-device-profile"
        OUTPUT_DIR="build-ios"
        DEST_DIR="${ROOT_DIR}/FptnVPN/Cpp"
        MIN_IOS_VERSION="17.0"
        echo "Building fptn_native_lib for iOS device..."
        ;;
    ios-simulator)
        HOST_PROFILE="conan-simulator-profile"
        OUTPUT_DIR="build-simulator"
        DEST_DIR="${ROOT_DIR}/FptnVPN/Cpp"
        MIN_IOS_VERSION="17.0"
        echo "Building fptn_native_lib for iOS simulator..."
        ;;
    macos)
        HOST_PROFILE="conan-macos-profile"
        OUTPUT_DIR="build-macos"
        DEST_DIR="${ROOT_DIR}/Fptn-macOS/Cpp"
        MIN_IOS_VERSION=""
        echo "Building fptn_native_lib for macOS..."
        ;;
    *)
        echo "Usage: $0 [ios-device|ios-simulator|macos]"
        exit 1
        ;;
esac

cd "$LIB_DIR"

conan install . --profile:host="$HOST_PROFILE" --profile:build=default --build=missing --output-folder="$OUTPUT_DIR"

cd "$OUTPUT_DIR"
cmake .. -DCMAKE_TOOLCHAIN_FILE=./build/Debug/generators/conan_toolchain.cmake -DCMAKE_BUILD_TYPE=Debug
cmake --build . --config Debug

# Copy to Xcode expected location
mkdir -p "$DEST_DIR"
rm -rf "${DEST_DIR}/fptn_native_lib.framework"
cp -R fptn_native_lib.framework "$DEST_DIR/"

# Add iOS-specific MinimumOSVersion when building for iOS outputs
FRAMEWORK_PLIST="${DEST_DIR}/fptn_native_lib.framework/Info.plist"
if [ -n "$MIN_IOS_VERSION" ] && [ -f "$FRAMEWORK_PLIST" ]; then
    echo "Adding MinimumOSVersion=${MIN_IOS_VERSION} to framework Info.plist..."
    /usr/libexec/PlistBuddy -c "Delete :MinimumOSVersion" "$FRAMEWORK_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string ${MIN_IOS_VERSION}" "$FRAMEWORK_PLIST"
fi

# Copy dSYM if it exists (for crash reporting)
if [ -d "fptn_native_lib.framework.dSYM" ]; then
    echo "Copying dSYM for crash reporting..."
    rm -rf "${DEST_DIR}/fptn_native_lib.framework.dSYM"
    cp -R fptn_native_lib.framework.dSYM "$DEST_DIR/"
fi

# Sign the framework so dyld accepts it.
# Xcode will re-sign with the full distribution/development cert during the
# "Embed Frameworks" phase; this ensures the binary has a valid cdhash.
SIGN_IDENTITY="${FPTN_CODESIGN_IDENTITY:--}"
echo "Signing fptn_native_lib.framework with identity: ${SIGN_IDENTITY}"
codesign --force --sign "${SIGN_IDENTITY}" \
    "${DEST_DIR}/fptn_native_lib.framework"

echo "Build complete. Framework output: ${DEST_DIR}/fptn_native_lib.framework"
