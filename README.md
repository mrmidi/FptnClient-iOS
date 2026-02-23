
# BUILD 


```bash
sudo xcode-select -switch /Applications/Xcode.app/Contents/Developer

cd FptnLib/
git submodule update --init --recursive
```

### Xcode Integration (Recommended)
We have added a script to build this automatically when you build the iOS app.
1. Open `FptnVPN.xcodeproj` in Xcode
2. Go to **FptnVPN** target -> **Build Phases**
3. Add a **New Run Script Phase** at the very top
4. Name it "Build FptnLib" and set the script to:
   `"${SRCROOT}/build_fptn_lib.sh"`

### Manual Build (Alternative)
```bash
./build_fptn_lib.sh
```





```bash
conan install . --profile:host=conan-device-profile --profile:build=default --build=missing --output-folder=build-ios 
cd build-ios
cmake .. -DCMAKE_TOOLCHAIN_FILE=./build/Debug/generators/conan_toolchain.cmake  -DCMAKE_BUILD_TYPE=Debug
cmake --build . --config Debug
copy to fptn-cpp


codesign --force --sign - --timestamp=none FptnVPN/Cpp/fptn_native_lib.framework/fptn_native_lib
codesign --force --sign - --preserve-metadata=identifier,entitlements,flags --timestamp=none FptnVPN/Cpp/fptn_native_lib.framework
codesign -dv FptnVPN/Cpp/fptn_native_lib.framework/fptn_native_lib 
```
