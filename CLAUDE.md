# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FptnVPN is an iOS VPN client app that connects to FPTN servers. It uses a pre-built C++ native framework (`fptn_native_lib.framework`) for HTTPS and WebSocket communication, wrapped through an Objective-C++ bridge layer.

## Build

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

- **FptnVPN** — Main SwiftUI app. Bundle ID: `org.fptn.FptnVPN`
- **FptnVPNTunnel** — `NEAppProxyProvider` network extension. Bundle ID: `org.fptn.FptnVPN.FptnVPNTunnel`. Currently a stub — VPN traffic is handled in the main app via WebSocket.
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

The native library is accessed through a two-level bridge:

- **Obj-C++ layer** (`FptnVPN/Cpp/Bridges/*.mm`): wraps C API from `fptn_native_lib` headers
  - `HttpsClientBridge.mm` — wraps `WrapperHttpsClientBridge.h`
  - `WebsocketClientBridge.mm` — wraps `WrapperWebsocketClientBridge.h`
- **Swift wrapper layer** (`FptnVPN/Cpp/Wrappers/*.swift`): exposes Obj-C++ classes to Swift
  - `HttpsClientSwift.swift` — thin Swift class over the Obj-C `HttpsClientSwift`
  - `WebScoketClientBridge.swift` — Swift `WebsocketClientBridge` + private `NativeWebsocketClientBridge`
- **Bridging header**: `FptnVPN/Cpp/FptnVPN-Bridging-Header.h` imports framework headers

### Key Models

- `FPTNToken` — parsed from the login token; contains username, password, and server list
- `VPNServer` — name, host, port, md5_fingerprint (for TLS certificate pinning)
- `VPNConnection` — observable state: isConnected, selectedServer, connectionMode (`.auto` / `.manual(VPNServer)`), speeds, timer

### Global Constants (`ProjectData.swift`)

- `Color.appBackground`, `Color.cian` — app color palette
- `AppLinks.telegramBot`, `AppLinks.website` — external links
