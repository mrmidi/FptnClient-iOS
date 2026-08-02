# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FptnVPN is a VPN client for Apple platforms (iOS, macOS, tvOS) that connects to FPTN servers. It uses a C++ native framework (`fptn_native_lib.framework`, built from the `FptnLib/fptn` submodule) for HTTPS and WebSocket communication. The SwiftUI apps consume that framework directly via Swift↔C++ interop (HTTPS) and a thin C++ wrapper (WebSocket).

## Project Generation (XcodeGen)

**`FptnVPN.xcodeproj` is generated from `project.yml` via XcodeGen — never edit the `.xcodeproj` by hand.** Source files are discovered automatically from the directories listed in `project.yml` (no per-file references), so adding a `.swift` file to a target's source directory is enough; just regenerate.

```bash
xcodegen generate     # regenerate the project after editing project.yml or adding/moving files
```

`build.sh` runs `xcodegen generate` automatically unless `--no-xcodegen` is passed.

## Build

### Native C++ Library (FptnLib)

The C++ library (`build_fptn_lib.sh`) uses Conan (Protobuf/BoringSSL, etc.) + CMake, and is built per-platform into `FptnLib/build-*` then packaged as `fptn_native_lib.framework`. Each app/tunnel target has a **pre-build script** that runs `build_fptn_lib.sh` only when the framework is missing (`FPTN_NATIVE_BUILD_IF_MISSING=1`), so a normal Xcode build (`Cmd+B`) builds the native lib on demand.

**Initialize the submodule first:**
```bash
cd FptnLib/ && git submodule update --init --recursive
```

**Build the native lib manually** (target picks the Conan profile + output dir):
```bash
./build_fptn_lib.sh ios-device        # or: ios-simulator, tvos-device, tvos-simulator, macos
./build_fptn_lib.sh all-apple         # all Apple targets
```
When invoked from Xcode (no arg) it resolves the target from `PLATFORM_NAME`.

### App builds

Open `FptnVPN.xcodeproj` in Xcode, or use the `build.sh` wrapper (regenerates the project, builds the native lib if missing, then `xcodebuild`):
```bash
./build.sh                                          # iOS simulator, Debug (default)
./build.sh --release
./build.sh --scheme Fptn-macOS --sdk macosx --destination 'platform=macOS' --native-target macos
./build.sh --scheme Fptn-tvOS  --sdk appletvsimulator --destination 'generic/platform=tvOS Simulator' --native-target tvos-simulator
```
Derived data and temp output go under `.build/` (overridable via `FPTN_DERIVED_DATA_PATH` / `FPTN_TMPDIR`).

**Re-sign the framework if Xcode complains** (target post-build scripts normally handle signing):
```bash
codesign --force --sign - --timestamp=none FptnVPN/Cpp/fptn_native_lib.framework/fptn_native_lib
codesign --force --sign - --preserve-metadata=identifier,entitlements,flags --timestamp=none FptnVPN/Cpp/fptn_native_lib.framework
```

**Select Xcode command line tools if needed:**
```bash
sudo xcode-select -switch /Applications/Xcode.app/Contents/Developer
```

### Tests

Per-platform unit-test bundles use the **Swift Testing** framework: `FptnVPNTests` (iOS), `Fptn-macOSTests` (macOS), `Fptn-tvOSTests` (tvOS). UI test targets exist alongside each.

### Local secret bootstrap (signing / CI)

```bash
zsh ./scripts/bootstrap-ci-secrets.sh
source .env.local
```
`.env.local` holds local-only build/release values (including the login keychain password) and is not committed. The script can list local signing identities and base64-encode a `.p12`. Optional GitHub upload of a curated subset (no `KEYCHAIN_PASSWORD`):
```bash
zsh ./scripts/bootstrap-ci-secrets.sh --gh --gh-repo OWNER/REPO
```

### Localization (`.xcstrings`)

String catalogs live at `<App>/Resources/Localizable.xcstrings` (languages: `en`, `ru`). Edit them as TSV via the helper, which writes to `build/l10n/` (gitignored):
```bash
python3 scripts/l10n_xcstrings.py export --all          # export all catalogs to TSV
python3 scripts/l10n_xcstrings.py compare               # diff coverage across platforms
python3 scripts/l10n_xcstrings.py import --xcstrings FptnVPN/Resources/Localizable.xcstrings \
   --tsv build/l10n/ios.tsv --in-place --set-translated
```

## Architecture

### Targets (per platform: app + packet-tunnel extension)

Bundle-ID prefix is `net.mrmidi.*`; Swift 6, C++20, `SWIFT_CXX_INTEROPERABILITY_MODE: default`.

- **FptnVPN** / **FptnVPNTunnel** — iOS app + extension (`net.mrmidi.FptnVPN[.FptnVPNTunnel]`)
- **Fptn-macOS** / **Fptn-macOS-Tunnel** — macOS app + extension (sandboxed, hardened runtime)
- **Fptn-tvOS** / **Fptn-tvOS-Tunnel** — tvOS app + extension
- **FptnLib** — C++ framework source (`FptnLib/`), not an Xcode target; built by `build_fptn_lib.sh`.

The network extensions are real **`NEPacketTunnelProvider`s** (`PacketTunnelProvider.swift`); actual traffic tunneling (the WebSocket bridge) runs **inside the extension**, not the app. App↔extension communication uses `NETunnelProviderSession.sendProviderMessage` (e.g. log-level sync).

### Shared code

- **SharedTunnelRuntime/** — Swift sources compiled into both apps and tunnel extensions (`TunnelLifecycleRuntime.swift`, `TunnelDiagnosticsStore.swift`). Shared diagnostics/lifecycle live here, plus the `group.net.mrmidi.FptnVPN` App Group and keychain access group.
- **Swift package dependencies**: `FptnShared` (product `FptnSharedCore`) and apple/`swift-log` (`Logging`).

### Authentication & Token Format

Users receive a token from `@fptn_bot` (Telegram). Format: `fptn:<base64-encoded JSON>`, decoded into `FPTNToken` (version, service_name, username, password, servers array). `LoginView` parses it; `TokenService` persists it.

### VPN Connection Flow (`VPNService.swift`)

1. Select a server (auto vs. `.manual(VPNServer)`; latency probing via `ServerLatencyProbeService` / `ServerSelectionService`).
2. POST `/api/v1/login` with credentials → `access_token`.
3. GET `/api/v1/dns` → `dnsIPv4` / `dnsIPv6`.
4. Configure `NETunnelProviderManager` and save to preferences.
5. Start the tunnel; the extension runs the WebSocket bridge for traffic over HTTPS.

### C++ Bridge Layer

There is **no Obj-C++ (`.mm`) bridge** — the older `Bridges/*.mm` and `WrapperApiClientBridge` are gone. Two mechanisms remain:

- **HTTPS — direct Swift↔C++ interop.** `FptnLib/src/https/SwiftApiClient.{h,cpp}` exposes a C++ `SwiftApiClient` class (wrapping `fptn::protocol::https::ApiClient`). Swift instantiates it directly using `std.string` in `<App>/Cpp/Wrappers/ApiClientBridge.swift` (`get`/`post`/`testHandshake`). Used for login/DNS/handshake — app side only.
- **WebSocket — thin C++ wrapper.** `FptnLib/src/websocket/WrapperWebsocketClientBridge.{h,cpp}` is consumed by `<Target>/Cpp/Wrappers/WebScoketClientBridge.swift`. Present in both the app and the tunnel extension.
- **Bridging headers** (`<Target>/Cpp/*-Bridging-Header.h`) include the relevant `fptn_native_lib/src/...` headers. The tunnel header includes only the WebSocket wrapper; the app header includes both.

When changing the native C++ API, edit the sources under `FptnLib/src/`, rebuild the framework, and keep the per-target bridging headers in sync.

### Key Models & Services (`FptnVPN/Models`, `FptnVPN/Services`)

- `FPTNToken`, `VPNServer` (name, host, port, `md5_fingerprint` for TLS pinning), `VPNConnection` (observable: isConnected, selectedServer, connectionMode, speeds, timer).
- Services include `VPNService`, `TokenService`, `KeychainHelper`, `SettingsService`, `AppFilterService` (per-app routing), `ServerLatency*`, `SNIScanner` (Tools → SNI Checker), `MetricKitManager`.
- Logging is shared between app and tunnel (`Logging/`, severity filter, app↔tunnel level sync) and surfaced in a Logs screen.

### Notes

- `FptnClient-Android/` (Android client) and `FptnLib/fptn` (native submodule) are sibling projects in this tree; the Apple app code is in the `Fptn*` directories.
@ASC.md
