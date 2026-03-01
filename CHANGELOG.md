# Changelog

All notable changes to this repository will be documented in this file.

## 2026-03-01

### Added
- Added appearance preference support (`system`, `dark`, `light`) via `AppColorScheme` and persisted setting key `fptn.settings.colorScheme`.
- Added semantic adaptive color tokens for app-wide theming:
  - `appAccent`, `appBackground`, `appSurface`, `appElevatedSurface`
  - `appPrimaryText`, `appSecondaryText`, `appMutedControl`, `appSeparator`
  - `appSuccess`, `appError`
- Added `MetricKitManager` to subscribe to MetricKit payloads and log metrics/diagnostics (crash, hang, CPU exceptions, disk write exceptions).
- Added connection-progress and error state propagation to UI view models (`isConnecting`, `errorMessage`).
- Added light/dark SwiftUI previews for key settings/routing views.
- Added a new `Tools -> SNI Checker` flow to probe candidate SNI hostnames against `/api/v1/dns` and quickly apply a selected/best result.
- Added a dedicated `Logs` screen in Home navigation with release availability, source filter (`All/App/Tunnel`), severity filter (`Warning/Info/Debug`), follow/pause, clear, and copy-to-clipboard export for sharing diagnostics with developers.
- Added persisted logging level setting (`Warning` default) in Settings and wired it to both app logging and tunnel logging.
- Added app-to-tunnel log-level synchronization via `NETunnelProviderSession.sendProviderMessage` and extension-side command handling in `handleAppMessage`.

### Changed
- App startup now respects persisted appearance selection instead of forcing dark mode.
- `SettingsView` now includes an Appearance section and saves color scheme preference.
- `SettingsView`, `AppFilterView`, `HomeView`, and `LoginView` were migrated from hardcoded dark-only styling to adaptive semantic colors for improved light-mode readability.
- Removed forced dark toolbar/list assumptions in settings-related screens.
- VPN connect flow now updates user-facing error messages for common failures:
  - no servers available
  - missing token data
  - login failure
  - DNS lookup failure
  - VPN configuration failure
- VPN configuration startup now returns the active `NETunnelProviderManager` and wires status observation using the returned manager.

### Fixed
- Fixed unreadable text and low-contrast controls in light mode across main iOS screens.
- Fixed stale dark-only preview configuration in debug/settings-related views.
- Fixed disconnect/reset state to clear transient connecting/error states.
- Fixed misleading Logs view behavior where historical lines from previous days could look like current failures by adding a default `Recent only (24h)` filter.
- Fixed "tunnel looks silent" at default `Warning` level by adding warning-level tunnel lifecycle markers (start, websocket connected, network settings applied).

### User-reported issues addressed
- **"The app looks broken / all white after iOS update"** — users on devices with iOS set to Light Mode saw white text on a white background, making the app effectively unusable. Root cause: all text was `.white` hard-coded with no dark-mode guard. Fixed by migrating to adaptive semantic color tokens that respond correctly to the active color scheme.
- **"App freezes / hangs when I press Connect"** — users reported the UI becoming unresponsive for several seconds (or indefinitely) right after tapping the connect button, especially on first launch or after a cold start. Root cause: synchronous C++ networking calls (`loginToServer`, `getDNSInfo`) were executing on the `MainActor`, blocking the main thread. Fixed by making those calls `nonisolated` so they run off the main thread.
- **"I can't tell if the app is connecting or if it crashed"** — users had no visual feedback between tapping Connect and the VPN becoming active. Fixed by propagating `isConnecting` state to the UI, showing a spinner and "Connecting…" label during the handshake phase.
- **"When the connection fails, nothing happens — no error message"** — users reported silent failures with no indication of what went wrong (wrong credentials, no internet, server unreachable). Fixed by surfacing human-readable error messages for the most common failure modes: no servers in token, authentication failure, DNS lookup failure, and VPN profile configuration error.
- **"Auto-select picks a server and then freezes the selector"** — users who left the server selection on Auto found the server list UI unresponsive after a reconnect cycle. Root cause: a missing state reset left `isConnecting` stuck as `true`. Fixed by ensuring `isConnecting` is always cleared in the `defer` block of the connect flow.
- **"Settings I change don't survive a force-quit"** — users noticed that SNI hostname and bypass method changes were lost after the app was killed from the app switcher. Fixed by ensuring all settings are written to `UserDefaults` synchronously via the nonisolated setter path, which flushes before the app suspends.

### Notes
- Existing compatibility alias `Color.cian` now maps to `appAccent`.
- This release focuses on iOS UX/theming and connection observability without changing core server API contracts.
- The SNI checker is highly experimental and is not expected to work reliably in all environments yet; it is provided for exploratory testing only.
- Existing shared sink retention remains a rolling 1000 lines (`logs/fptn.log` in the app group container).
