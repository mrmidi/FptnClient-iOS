cmake_minimum_required(VERSION 3.16)
project(fptn_native_lib VERSION 1.0.0 LANGUAGES CXX C OBJCXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
# PR0: C++23 across the stack. Aligned with Conan profiles
# (compiler.cppstd=23) and the fptn submodule (C++23 + YAFF patch).
add_compile_options(-std=c++23)

# Platform-specific deployment target defaults
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # Let the conan profile's os.version win; only fall back if unset.
    # Setting this unconditionally silently overrode the toolchain.
    if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
        set(CMAKE_OSX_DEPLOYMENT_TARGET 16.0)
    endif()
elseif(APPLE)
    # Keep macOS target explicit and valid for local/App Store builds.
    if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
        set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0)
    endif()
endif()
set(CMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE NO)
set(CMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT "dwarf-with-dsym")
set(CMAKE_XCODE_ATTRIBUTE_DWARF_DSYM_FOLDER_PATH "${CMAKE_CURRENT_BINARY_DIR}")


option(COPY_SOURCE_FILES "Copy source files to output directory" ON)
set(SOURCE_COPY_DIR "${CMAKE_CURRENT_BINARY_DIR}/exported_sources" CACHE PATH "Directory to copy source files to")

set(FPTN_IP_ADDRESS_WITHOUT_PCAP ON)
add_compile_definitions(FPTN_IP_ADDRESS_WITHOUT_PCAP)

# include(${CMAKE_BINARY_DIR}/build/generators/conan_toolchain.cmake)

# PR0: removed -DO3 (was a preprocessor macro, not an optimization flag),
# all WSP_GGML_* defines (zero references in any source file — vestigial
# from an unrelated whisper project), and the arm64 WSP_GGML_CPU_GENERIC.
# -DNDEBUG is now configuration-specific: disabled in Debug so assertions
# remain active during development.
if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_definitions(-DNDEBUG)
endif()

# PR0: size-oriented flags for MinSizeRel/Release iOS builds.
# -Oz minimises code size; -ffunction-sections/-fdata-sections +
# -Wl,-dead_strip let the linker discard unreferenced code and data.
if(CMAKE_BUILD_TYPE STREQUAL "MinSizeRel" OR CMAKE_BUILD_TYPE STREQUAL "Release")
    add_compile_options(-Oz -ffunction-sections -fdata-sections)
    add_link_options(-Wl,-dead_strip)
endif()

# Find packages
find_package(fptn REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(nlohmann_json REQUIRED)

include_directories(src/)
include_directories(fptn/src/)
include_directories(fptn/src/fptn-protocol-lib)

# Create library target
add_library(fptn_native_lib SHARED
    src/https/SwiftApiClient.cpp src/https/SwiftApiClient.h
    src/websocket/WrapperWebsocketClientBridge.cpp src/websocket/WrapperWebsocketClientBridge.h
    src/apple/FPTNApplePacketFlowAdapter.h src/apple/FPTNApplePacketFlowAdapter.mm
    src/apple/FPTNTunnelBridge.h src/apple/FPTNTunnelBridge.mm
)

target_compile_features(fptn_native_lib PRIVATE cxx_std_23)
target_compile_options(fptn_native_lib PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_compile_definitions(fptn_native_lib PRIVATE
    BOOST_ASIO_HAS_CO_AWAIT
    BOOST_ASIO_HAS_CO_SPAWN
    BOOST_ASIO_HAS_COROUTINES
)

# PR0: removed -framework Accelerate, Metal, MetalKit (zero references
# in any source file) and duplicate raw -lssl/-lcrypto (OpenSSL::SSL and
# OpenSSL::Crypto already resolve to BoringSSL via Conan).
target_link_libraries(fptn_native_lib PRIVATE
    "-framework Foundation"
    "-framework NetworkExtension"
    fptn::fptn
    OpenSSL::SSL
    OpenSSL::Crypto
)

file(GLOB_RECURSE ALL_HEADERS 
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.hpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.hxx"
    "${CMAKE_CURRENT_SOURCE_DIR}/fptn/src/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/fptn/src/*.hpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/fptn/src/*.hxx"
)

set_target_properties(fptn_native_lib PROPERTIES
    MACOSX_FRAMEWORK_IDENTIFIER "com.fptn.native"
    MACOSX_FRAMEWORK_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING ${PROJECT_VERSION}
    FRAMEWORK TRUE
    FRAMEWORK_VERSION ${PROJECT_VERSION}
    VERSION ${PROJECT_VERSION}
    PUBLIC_HEADER "${ALL_HEADERS}"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    CXX_VISIBILITY_PRESET default
    VISIBILITY_INLINES_HIDDEN OFF
    MACOSX_FRAMEWORK_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
)

# copy all files
foreach(header_file ${ALL_HEADERS})
    file(RELATIVE_PATH relative_path "${CMAKE_CURRENT_SOURCE_DIR}" "${header_file}")
    set(target_file "${CMAKE_CURRENT_BINARY_DIR}/fptn_native_lib.framework/Headers/${relative_path}")
    get_filename_component(target_dir "${target_file}" DIRECTORY)
    add_custom_command(TARGET fptn_native_lib POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "${target_dir}"
        COMMAND ${CMAKE_COMMAND} -E copy "${header_file}" "${target_file}"
        COMMENT "Copying ${relative_path}"
    )
endforeach()
