# Plan: CLI Hardening + Manual/Auto Boundary Decomposition

## Two core principles

1. **CLI is the reference implementation and release gate.** iOS is only an adapter after the algorithm is proven.
2. **Manual and Auto are separate policy domains.** They share transport primitives, never policy.

---

## Architectural boundary

```
FptnSharedCore                    (domain models, contracts, shared types)
        ↓
FptnServerSelection               (Auto ordering, race, health policy, outcomes)
        ↓
FptnConnectionOrchestration       (Manual + Auto coordinators, states, recovery, reconnect)
        ↓
FptnNativeTransport               (real C++ bootstrap bridge; workspace-level)
```

Manual ≠ Auto is enforced by **module boundaries + absent dependencies**, not scattered conditionals.

---

## 1. Module split

- **`FptnSharedCore`** — models, contracts, `ServerBootstrapping`, `BootstrapPolicy`, `BootstrapContext`
- **`FptnServerSelection`** — `AutoServerSelector`, `SlidingWindowRace`, `CandidateOrderer`, `ServerHealthStore`, `SelectionRun`, `AutoSelectionResult`
- **`FptnConnectionOrchestration`** — `ManualConnectionCoordinator`, `AutoConnectionCoordinator`, state enums, `ConnectionCoordinating`, `ConnectionIntent`, `TunnelRecoveryPolicy`, `ReconnectCoordinator`, episode identity

Clarity rule: orchestration knows about selection; selection does **not** know about coordination or tunnel IPC.

---

## 2. Rename the shared bootstrap abstraction

```swift
// BEFORE
protocol ServerBootstrapProbing { func probe(...) async -> ServerBootstrapAttempt }

// AFTER
public protocol ServerBootstrapping: Sendable {
    func bootstrap(
        server: VPNServer,
        credentials: Credentials,
        context: BootstrapContext,
        policy: BootstrapPolicy
    ) async -> ServerBootstrappingResult   // .success / .failure(ServerBootstrapFailure)
}
```

- "Bootstrap" (not "probe") — Manual Mode is not probing, it is bootstrapping one server.
- `BootstrapContext` replaces `ProbeContext` for clarity (or keep `ProbeContext` inside, re-exported).
- Single primitive shared by both paths.

---

## 3. Typed contract for coordinators

```swift
public enum ConnectionStartResult: Sendable {
    case started(ConnectionEpisodeID)
    case failed(ConnectionStartFailure)
    case cancelled
}

public enum ConnectionStartFailure: Sendable {
    case noNetwork
    case noServers
    case bootstrap(ServerBootstrapFailure)
    case tunnelRefused(String)
}

public enum ConnectionEvent: Sendable {
    case tunnelStatusChanged(NEVPNStatus)
    case tunnelFailed(TunnelStopReason)
    case networkBecameSatisfied
    case networkBecameUnsatisfied
}

public protocol ConnectionCoordinating: Sendable {
    func connect() async -> ConnectionStartResult
    func disconnect(reason: DisconnectReason) async
    func handle(_ event: ConnectionEvent) async
    func stateSnapshot() async -> ConnectionStateSnapshot
}
```

Or expose `AsyncStream<ConnectionStateSnapshot>` (preferred for CLI assertions — the test drives transitions exactly).

CLI tests assert real transitions, not log scraping.

---

## 4. Factory, not dispatch table

```swift
func makeCoordinator(
    for intent: ConnectionIntent,
    deps: ConnectionDependencies
) -> any ConnectionCoordinating {
    switch intent {
    case .manual(let server):
        ManualConnectionCoordinator(
            server: server,
            bootstrapper: deps.nativeBootstrap,
            tunnelController: deps.tunnelController,
            clock: deps.clock
        )
    case .auto:
        AutoConnectionCoordinator(
            selector: deps.autoSelector,
            reconnectCoordinator: deps.reconnectCoordinator,
            tunnelController: deps.tunnelController,
            clock: deps.clock
        )
    }
}
```

Mode is switched **once**, at construction. No policy branching inside either coordinator.

---

## 5. Auto coordinator does not own the health store

```swift
actor AutoConnectionCoordinator {
    private let selector: AutoServerSelector     // already owns health store
    private let reconnectCoordinator: ReconnectCoordinator
    private let tunnelController: TunnelControlling
    private let clock: any Clock
}
```

Health-policy responsibility belongs entirely to `AutoServerSelector`. The coordinator asks it to `select(...)` and acts on the typed outcome. No back-channel.

---

## 6. Explicit bootstrap policy — "one attempt" enforced structurally

```swift
public struct BootstrapPolicy: Sendable, Codable {
    let loginAttempts: Int
    let dnsAttempts: Int
    let stageTimeout: Duration
    let candidateDeadline: Duration

    static let production = BootstrapPolicy(
        loginAttempts: 1,
        dnsAttempts: 1,
        stageTimeout: .seconds(5),
        candidateDeadline: .seconds(8)
    )
}
```

Manual: `loginAttempts: 1, dnsAttempts: 1`.
Auto (per raced candidate): also `1`. Retrying a candidate mid-race blocks a slot and distorts selection — any retry belongs to the **Auto recovery policy**, not invisibly inside HTTP helpers.

---

## 7. One reconnect authority + episode ID

### Reconnect split

| Layer | Can do | Cannot do |
|-------|--------|-----------|
| Packet tunnel | bounded immediate same-server transport recovery | select another server, rerace |
| Auto app coordinator | wait for terminal extension failure → cooldown → rerace → replacement tunnel | double-schedule same-server retry |
| Manual | nothing (recovery policy `.none`) | schedule anything |

```swift
struct ConnectionEpisodeID: Hashable, Codable, Sendable {
    let rawValue: UUID
}
```

Every tunnel startup gets a fresh episode ID. Events from a previous episode are discarded. Prevents late extension retries from mutating a new session.

---

## 8. Manual cancellation generation gate

```swift
actor ManualConnectionCoordinator {
    private var generation: UInt64 = 0

    func connect() async -> ConnectionStartResult {
        generation &+= 1
        let attempt = generation

        let result = await bootstrapper.bootstrap(...)

        guard attempt == generation, !Task.isCancelled else {
            return .cancelled
        }
        // Only now may the tunnel start.
    }

    func disconnect(reason: DisconnectReason) async {
        generation &+= 1
        await tunnelController.stop()
    }
}
```

Late native completion checks `attempt == generation` — if the user disconnected meanwhile, it's discarded. Valid even before native C++ cancellation exists.

---

## 9. Versioned IPC payload for tunnel config

```swift
struct TunnelStartupConfiguration: Codable, Sendable {
    let schemaVersion: Int          // current = 1
    let episodeID: UUID
    let recoveryPolicy: TunnelRecoveryPolicy
    let server: TunnelServerPayload
    let accessToken: String
    let dnsIPv4: String
    let dnsIPv6: String?
    // ... remaining fields
}

enum TunnelRecoveryPolicy: Codable, Sendable {
    case none
    case automatic(AutoTunnelRecoveryPolicy)
}

struct AutoTunnelRecoveryPolicy: Codable, Sendable {
    let sameServerAttempts: Int
    let reconnectDelaySeconds: Int
}
```

Provider configuration carries `Data` under key `tunnelStartupV1`. Contract tests prove:

- `.none` round-trips correctly
- `.automatic` round-trips correctly
- unknown future schema fails safely
- **missing / malformed policy defaults to `.none`** (no reconnect), never unlimited

---

## 10. Test-target split

| Target | What it contains |
|--------|-----------------|
| `FptnSharedCoreTests` | token decoding, codable round-trips, domain models |
| `FptnServerSelectionTests` | race invariants, ordering, health policy, typed errors, auth quorum |
| `FptnConnectionOrchestrationTests` | manual coordinator invariants, auto coordinator invariants, boundary tests, reconnect state machine, episode ID, generation gate |
| `FptnNativeTransportIntegrationTests` | real C++ bootstrap (manual `test`, not CI-gated unless hardware present) |

Core never becomes a dumping ground for selection/lifecycle logic.

---

## 11. What the CLI can and cannot prove

**Can prove:** selection logic, manual vs Auto coordinator behavior, bootstrap behavior, cache behavior, retry budgets, late-result rejection, simulated tunnel state transitions, generation gates.

**Cannot prove:** actual NEPacketTunnelProvider lifecycle (requires device/simulator).

Therefore the CLI uses a **fake or local tunnel-controller adapter**. Real iOS tunnel lifecycle is validated later. The acceptance document must not claim the CLI proved actual tunnel behavior.

---

## 12. Manual disconnect state — separate reason from failure

```swift
enum ManualConnectionState: Sendable {
    case idle
    case bootstrapping
    case startingTunnel
    case connected
    case disconnecting
    case disconnected(ManualDisconnectReason)
    case failed(ManualConnectionFailure)
}

enum ManualDisconnectReason: Sendable {
    case userInitiated
    case remoteClosed
    case networkLost
    case appBackgroundedTooLong
}
```

An unexpected remote closure is `.disconnected(.remoteClosed)`, **not** `.failed(.tunnelFailed(...))`.

---

## M1 Review Fixes Applied

### Blocking fixes
1. **Request types** — `ManualConnectionRequest` / `AutoConnectionRequest` / `ConnectionRequest` replace empty no-arg `connect()`
2. **Auto generation gate** — `guard attempt == generation` after every `await` in `AutoConnectionCoordinator`
3. **Manual state preservation** — stale completion returns `.cancelled` without overwriting newer state
4. **Episode-scoped stop** — `TunnelControlling.stop(episodeID:)` only stops own episode
5. **Auto stop classification** — `.userInitiated` → idle, `.authenticationFailed` → terminal, `.networkLost` → waiting, others → replacement
6. **Full state exposure** — `ConnectionStateSnapshot` has selecting/waitingForRoom/retry/selectingReplacement/stabilizing/exhausted
7. **Reuse typed model** — `ServerBootstrapping.bootstrap()` returns `ServerBootstrapAttempt` (not stringly-typed duplicate)
8. **Concurrent-safe fakes** — moved `FakeServerBootstrapping`, `FakeAutoSelector`, `FakeTunnelController` to `FptnSharedTestSupport` as actors
9. **Safe default decode** — missing `recoveryPolicy` → `.none`, unknown schema → error
10. **Split dependency containers** — `ManualConnectionDependencies` / `AutoConnectionDependencies`

### New types added
- `ServerHealthObservation` — strips token from attempts before health store storage
- `TunnelStartupConfiguration` versioned decoding

### Tests: 29 passing across 5 suites

## Milestone sequence

| Milestone | Deliverable | iOS? |
|-----------|-------------|:---:|
| **M1** ✅ | `FptnConnectionOrchestration` + boundary types + 29 deterministic tests | No |
| **M2** | CLI: real native bootstrap, 100% candidate coverage, both modes | No |
| **M3** | Health learning, typed failures, deadlines, reconnect sims | No |
| **M4** | `manual-connect` proves runtime boundary + stability matrices | No |
| **M5** | Native cancellation proven OR limitation explicitly accepted | No |
| **M6** | Freeze/tag engine + acceptance report | No |
| **M7** | iOS: factory-based coordinator dispatch, versioned IPC, feature flag, adapters only | **Yes** |

---

## Final M1 scope

1. Create `FptnConnectionOrchestration` target
2. Define `ConnectionIntent`, `ConnectionDependencies`
3. Define `ServerBootstrapping` (replaces `ServerBootstrapProbing`), `BootstrapPolicy`, `BootstrapContext`
4. Define `ConnectionCoordinating` with `ConnectionStartResult`, `ConnectionEvent`, `stateSnapshot`
5. Define separate Manual and Auto state enums (with `ManualDisconnectReason`)
6. Implement `ManualConnectionCoordinator` fully — with fake bootstrap + fake tunnel controller + generation gate
7. Scaffold `AutoConnectionCoordinator` around a fake selector
8. Add `ConnectionEpisodeID` and episode-based stale-event rejection
9. Add `TunnelRecoveryPolicy` (`.none` / `.automatic`) + versioned `TunnelStartupConfiguration`
10. Boundary tests: Manual = exactly one attempt, zero health-store reads/writes, zero reconnect logic, generation gate discards late completions
11. Do **not** touch `VPNService`, the real tunnel extension, or the Swift native bridge yet

---

## Dependency graph (final)

```
FptnSharedCore                    (models, contracts, ServerBootstrapping, BootstrapPolicy)
        ↓
FptnServerSelection               (AutoServerSelector, SlidingWindowRace, ServerHealthStore)
        ↓
FptnConnectionOrchestration       (Manual + Auto coordinators, states, recovery, reconnect, episode)
        ↓
FptnNativeTransport               (workspace-level; wraps fptn_native_lib.framework)

FptnSelectionCLI
 ├── FptnSharedCore
 ├── FptnServerSelection
 ├── FptnConnectionOrchestration
 ├── FptnSharedTestSupport
 └── FptnNativeTransport

FptnVPN (future, M7)
 ├── FptnSharedCore
 ├── FptnServerSelection
 ├── FptnConnectionOrchestration
 └── FptnNativeTransport
```

---

## Hard rules summary

1. Mode switched **once** at coordinator construction — no internal branching
2. Manual coordinator holds **no** `ServerHealthStore`, `SlidingWindowRace`, or `AutoServerSelector`
3. Bootstrap primitive is invoked **one time** per manual connection; retries belong to Auto recovery policy
4. Late native completions are discarded via generation gate
5. Stale tunnel events are discarded via episode ID
6. Missing/malformed `TunnelRecoveryPolicy` → `.none` (never unlimited)
7. Reconnect authority is singular: tunnel (same-server) **or** app (replacement), never both independently
8. CLI is reference; iOS is downstream adapter
9. Separate test targets per layer
