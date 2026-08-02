# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

FptnVPN is an iOS VPN client app that connects to FPTN servers. It uses a pre-built C++ native framework (`fptn_native_lib.framework`) for HTTPS and WebSocket communication, accessed via Swift C++ interop (C++23, `SWIFT_OBJC_INTEROP_MODE: objcxx`).

## Build

 The project uses automatic file discovery (no explicit file references in pbxproj for Swift files).

### Native C++ Library (FptnLib)

The C++ library relies on Conan (for dependencies like Protobuf/BoringSSL) and CMake.

**Recommended: Automatic Xcode Integration**
We have added a `build_fptn_lib.sh` script to automate this. To use it:
1. Open `FptnVPN.xcodeproj` in Xcode.
2. Go to the **FptnVPN** target -> **Build Phases**.
3. Click the `+` button at the top left and select **New Run Script Phase**.
4. Drag the new phase to the **very top** (before "Dependencies" or "Compile Sources").
5. Rename it (double-click) to "Build FptnLib (Conan+CMake)".
6. Paste the following line into the script box:
   `"${SRCROOT}/build_fptn_lib.sh"`

Now, Xcode will automatically build the C++ code for your iOS device whenever you hit `Cmd+B`.

**Initialize submodules first (if you haven't):**
```bash
cd FptnLib/
git submodule update --init --recursive
```

**Alternative: Manual Build (For debugging)**
If you prefer running it manually (the Xcode script does exactly this):
```bash
./build_fptn_lib.sh
```

**Re-sign after copying (if Xcode complains):**
```bash
codesign --force --sign - --timestamp=none FptnVPN/Cpp/fptn_native_lib.framework/fptn_native_lib
codesign --force --sign - --preserve-metadata=identifier,entitlements,flags --timestamp=none FptnVPN/Cpp/fptn_native_lib.framework
```

**Select Xcode command line tools if needed:**
```bash
sudo xcode-select -switch /Applications/Xcode.app/Contents/Developer
```

### iOS App

Open `FptnVPN.xcodeproj` in Xcode. Tests are in `FptnVPNTests` (Swift Testing framework).

## Architecture

### App Targets

- **FptnVPN** — Main SwiftUI app. Bundle ID: `net.mrmidi.FptnVPN`
- **FptnVPNTunnel** — `NEPacketTunnelProvider` network extension. Bundle ID: `net.mrmidi.FptnVPN.FptnVPNTunnel`. Handles VPN traffic via WebSocket through the native C++ bridge.
- **FptnLib** — C++ shared library (`fptn_native_lib.framework`). Built with CMake/Conan; not a Swift package.

### Authentication & Token Format

Users receive a token from `@fptn_bot` (Telegram). Token format: `fptn:<base64-encoded JSON>`. The JSON decodes to `FPTNToken` (version, service_name, username, password, servers array). `LoginView` parses this and `TokenService` persists it in `UserDefaults`.

### VPN Connection Flow (`VPNService.swift`)

1. Select server (auto = first in list, manual = user-selected)
2. POST `/api/v1/login` with credentials → receive `access_token`
3. GET `/api/v1/dns` → receive `dnsIPv4` / `dnsIPv6`
4. Configure `NETunnelProviderManager` and save to preferences
5. Start `WebsocketClientBridge` — actual traffic tunneling via WebSocket over HTTPS

### C++ Bridge Layer

The native library is accessed through Swift C++ interop (no Objective-C++ `.mm` files). C++ classes are imported via bridging headers and used directly from Swift:

- **C++ classes** (compiled into `fptn_native_lib.framework`):
  - `SwiftApiClient` (`FptnLib/src/https/SwiftApiClient.h`) — HTTPS API client
  - `WebsocketSwiftBridge` (`FptnLib/src/websocket/WrapperWebsocketClientBridge.h`) — WebSocket transport with C function-pointer callbacks
- **Swift wrapper layer** (`FptnVPN/Cpp/Wrappers/*.swift`, `FptnVPNTunnel/Cpp/*.swift`):
  - `ApiClientBridge.swift` — Swift wrapper over `SwiftApiClient`
  - `WebScoketClientBridge.swift` — Swift `WebsocketClientBridge` wrapping `WebsocketSwiftBridge`, passes `Unmanaged` context pointers for C callbacks
- **Bridging headers**: `FptnVPN/Cpp/FptnVPN-Bridging-Header.h` (app), `FptnVPNTunnel/Cpp/FptnVPNTunnel-Bridging-Header.h` (tunnel) — `#include` the C++ headers from the framework
- Both C++ classes are annotated `SWIFT_NONCOPYABLE` (move-only, imported as `~Copyable` in Swift)

### Key Models

- `FPTNToken` — parsed from the login token; contains username, password, and server list
- `VPNServer` — name, host, port, md5_fingerprint (for TLS certificate pinning)
- `VPNConnection` — observable state: isConnected, selectedServer, connectionMode (`.auto` / `.manual(VPNServer)`), speeds, timer

### Global Constants (`ProjectData.swift`)

- `Color.appBackground`, `Color.cian` — app color palette
- `AppLinks.telegramBot`, `AppLinks.website` — external links

## asc cli reference

See `ASC.md` for the command catalog and workflows.
