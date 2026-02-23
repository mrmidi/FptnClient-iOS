#!/bin/bash
set -e

# PATH setup (homebrew is often not in Xcode's PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v conan &> /dev/null || ! command -v cmake &> /dev/null; then
    echo "error: conan or cmake not found in PATH. Please install them to build FptnLib."
    exit 1
fi

cd "${SRCROOT}/FptnLib"

echo "Building for iOS Device (Network Extensions only support real devices)..."
conan install . --profile:host=conan-device-profile --profile:build=default --build=missing --output-folder=build-ios

cd build-ios
cmake .. -DCMAKE_TOOLCHAIN_FILE=./build/Debug/generators/conan_toolchain.cmake -DCMAKE_BUILD_TYPE=Debug
cmake --build . --config Debug

# Copy to Xcode expected location
rm -rf "${SRCROOT}/FptnVPN/Cpp/fptn_native_lib.framework"
cp -R fptn_native_lib.framework "${SRCROOT}/FptnVPN/Cpp/"

# Sign the framework so dyld accepts it.
# Xcode will re-sign with the full distribution/development cert during the
# "Embed Frameworks" phase; this ensures the binary has a valid cdhash.
echo "Signing fptn_native_lib.framework..."
codesign --force --sign "Apple Development" \
    "${SRCROOT}/FptnVPN/Cpp/fptn_native_lib.framework"
