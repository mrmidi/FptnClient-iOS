# Implementation Plan — Optional lwIP Flow Data Plane for FPTN (Apple Platforms)

Status: approved planning pass. All design decisions below are locked.
Scope owner repos: `mrmidi/fptn` (submodule at `FptnLib/fptn`), `FptnClient-iOS` (this repo), `mrmidi/FptnShared`.

## 1. Goal

Add an optional **flow-proxy data plane** to the native FPTN library for Apple
Network Extension builds while preserving the existing raw-IP tunnel unchanged.

```text
DataPlaneMode::L3Tunnel
    NEPacketTunnelFlow
        → existing FPTN IP-packet protocol (WebSocket)
        → server TUN

DataPlaneMode::FlowProxy
    NEPacketTunnelFlow
        → lwIP (transparent, HEV fork)
        → TCP flows / UDP associations
        → routing action
            ├── DIRECT
            ├── FPTN_L4   (later)
            └── BLOCK     (later)
```

The existing wire protocol carries individual or batched complete IP packets,
so `L3Tunnel` remains a first-class mode, not legacy compatibility code.

The lwIP work is implemented primarily in `mrmidi/fptn`; `FptnLib` exposes it
to Swift as part of the same native tunnel engine.

## 2. Locked decisions

| # | Decision | Choice |
|---|----------|--------|
| D1 | Swift bridge transition | **Replace in place** — PR-LW6 delivers `TunnelSwiftBridge` as the only native tunnel ABI; L3 becomes `DataPlaneMode::L3Tunnel` inside `TunnelEngine`. macOS/tvOS tunnel targets (stale duplicates, old per-packet ABI) get a minimal compile-keep; their migration is a follow-up. |
| D2 | Mode selection plumbing | **FptnShared payload field now** — optional `dataPlaneMode` in `TunnelStartupConfigurationV1` via `decodeIfPresent`, `schemaVersion` stays 1; new FptnShared release + pin bump in `project.yml`. |
| D3 | Platform scope | **iOS tunnel only** (`FptnVPNTunnel`). macOS/tvOS keep L3 via the compile-keep. Host-macOS native build carries gtest/integration CI (tests only build when not `build_only_fptn_lib`). |
| D4 | lwIP acquisition | **FetchContent pinned by SHA** — `fptn/depends/cmake/FetchLwip.cmake` (`gitlab.com/hev/lwip`, `GIT_TAG <sha>`); patches in `fptn/depends/lwip/patches/` via `PATCH_COMMAND`; `PATCHES.md` records upstream repo, SHA, lwIP baseline, license. |
| D5 | Endpoint types | `IpEndpoint { boost::asio::ip::address; uint16_t port }` at the flow/router boundary. `tcp::endpoint` only inside `DirectTcpOutbound`, `udp::endpoint` only inside `DirectUdpOutbound`. No custom IP-address class. |
| D6 | Apple packet hot path | **Objective-C++ `FPTNApplePacketPump` in FptnLib** owns the packet path between `NEPacketTunnelFlow` and native. No Swift code executes per packet. Retained immutable `NSData` → custom lwIP pbufs (zero-copy ingress); pooled native buffers → `NSData(bytesNoCopy:deallocator:)` (no-copy egress). |
| D7 | Execution runtime | Flow mode uses one shared `TunnelRuntime` (`io_context` + `executor_work_guard` + thread) owning the lwIP strand, outbound sockets, and all timers. **L3 keeps its own io_context/thread for now** (WebsocketClient untouched); context unification is optional later work. |
| D8 | ARC | Enable ARC target-wide on `fptn_native_lib` (`CLANG_ENABLE_OBJC_ARC YES`); no existing ObjC sources to break. |
| D9 | Engine ingress ABI | Portable, Foundation-free: `PacketLease { bytes, length, ip_version, owner, release }` batch view. `NSData`/`CFDataRef` never cross into the engine, so a future desktop `TunFileDescriptorAdapter` plugs into the same `TunnelEngine`. |

## 3. Explicit scope

Included:

- optional lwIP dependency for Apple builds (Conan `with_lwip`, default False);
- IPv4 and IPv6 packet ingress;
- transparent TCP interception;
- UDP associations;
- packet output back to `NEPacketTunnelFlow`;
- native flow lifecycle;
- backpressure and bounded buffering;
- DIRECT outbound proof;
- interfaces for future FPTN L4 and routing integrations;
- mode selection between `L3Tunnel` and `FlowProxy`;
- diagnostics and performance validation.

Not included:

- `geosite.dat` / `geoip.dat`;
- route-list downloading or App Group storage;
- route UI;
- final FPTN L4 wire framing;
- per-packet switching between L3 and flow mode;
- TCP connection migration across network changes (path change may reset flows);
- macOS/tvOS tunnel migration to the new ABI;
- desktop TUN adapter (`TunFileDescriptorAdapter`) — ABI shape is preserved for it.

Routing for this milestone is trivial: `TCP/UDP → DIRECT`, unsupported protocol → reject.

## 4. Architecture

### 4.1 Component map

```text
PacketTunnelProvider.swift
    ├── start/stop lifecycle, generations
    ├── setTunnelNetworkSettings
    ├── reconnect policy
    ├── diagnostics / control messages / telemetry snapshots
    └── constructs FPTNApplePacketPump once per session
                │
FPTNApplePacketPump.mm  (FptnLib, Objective-C++, ARC)
    ├── owns NEPacketTunnelFlow read loop (exactly one pending read)
    ├── retains ingress NSData → pooled ApplePacketPbuf (PBUF_REF custom)
    ├── fallback: copy → PBUF_RAM (bounded, counted)
    ├── posts batches (portable PacketLease views) into the engine
    ├── wraps native output as NSData without copying
    ├── calls writePackets:withProtocols: directly
    └── generation-stamped stale-callback discard
                │
portable C++ FPTN core (fptn submodule)
    ├── TunnelEngine
    │     ├── L3TunnelDataPlane   (adapts existing WebsocketClient)
    │     └── FlowProxyDataPlane  (lwIP stack + router + outbounds)
    ├── lwIP — TCP/IP state machine only
    └── Boost.Asio — execution, sockets, timers, cancellation, buffers
```

### 4.2 Native engine seam

```cpp
enum class DataPlaneMode : std::uint8_t { L3Tunnel = 0, FlowProxy = 1 };

class IDataPlane {
public:
    virtual ~IDataPlane() = default;
    virtual std::expected<void, TunnelError> Start() = 0;
    virtual void Stop() noexcept = 0;
    virtual PacketInputResult InputPackets(PacketBatchView packets) noexcept = 0;
};

class TunnelEngine final {
public:
    static std::expected<std::unique_ptr<TunnelEngine>, TunnelError>
    Create(TunnelConfiguration config, TunnelCallbacks callbacks);
    std::expected<void, TunnelError> Start();
    void Stop() noexcept;
    PacketInputResult InputPackets(PacketBatchView packets) noexcept;
};
```

Portable ingress lease (D9), extending the existing
`FptnOwnedPacketDescriptor` / `fptn_release_owned_packet` pattern to ingress:

```cpp
struct PacketLease {
    const std::uint8_t* bytes;
    std::uint32_t length;
    std::uint8_t ip_version;   // AF_INET / AF_INET6
    void* owner;               // opaque; pump-side CFDataRef lease or pool slot
    void (*release)(void* owner) noexcept;
};
```

### 4.3 Flow types (D5)

```cpp
using FlowId = std::uint64_t;
enum class TransportProtocol : std::uint8_t { Tcp, Udp };

struct IpEndpoint {
    boost::asio::ip::address address;
    std::uint16_t port;
};

struct FlowMetadata {
    FlowId id;
    TransportProtocol protocol;   // carried separately; endpoint stays neutral
    IpEndpoint source;            // lwIP pcb remote (application side)
    IpEndpoint destination;       // lwIP pcb local (original internet destination)
};
```

Conversions live only at the two adapter edges:

```text
lwIP adapter edge:  ip_addr_t + port  ⇄  IpEndpoint
TCP outbound edge:  IpEndpoint → boost::asio::ip::tcp::endpoint
UDP outbound edge:  IpEndpoint → boost::asio::ip::udp::endpoint
```

Stack-neutral interfaces (no `tcp_pcb`/`udp_pcb`/`pbuf` outside the lwIP adapter):

```cpp
class INetworkStack {
public:
    virtual PacketInputResult InputPackets(PacketBatchView) noexcept = 0;
    virtual WriteResult WriteTcp(FlowId, BufferSequence) noexcept = 0;
    virtual void FinishTcp(FlowId) noexcept = 0;
    virtual void ResetTcp(FlowId) noexcept = 0;
    virtual WriteResult WriteUdp(FlowId, IpEndpoint source, BufferView) noexcept = 0;
};

class IFlowEventSink {
public:
    virtual void OnTcpOpen(FlowMetadata) = 0;
    virtual void OnTcpData(FlowId, OwnedBuffer) = 0;
    virtual void OnTcpHalfClose(FlowId) = 0;
    virtual void OnTcpReset(FlowId, FlowError) = 0;
    virtual void OnUdpDatagram(FlowMetadata, OwnedBuffer) = 0;
};

class IFlowRouter {
public:
    virtual RouteAction Match(const FlowMetadata&) = 0;   // DIRECT for this milestone
};
```

`IpEndpoint`/`FlowMetadata` live in a stack-neutral header
(`fptn-protocol-lib/tunnel/flow_types.h`) that includes
`<boost/asio/ip/address.hpp>` but not `tcp.hpp`/`udp.hpp`.

### 4.4 lwIP dependency and build

HEV lwIP fork (`gitlab.com/hev/lwip`, GitHub mirror `heiher/lwip`), BSD-style
license retained. Required fork features (verified): `NETIF_FLAG_PRETEND_TCP/
UDP/ICMP`, `tcp_bind_netif`, acceptance of connections not addressed to
localhost, original destination in `pcb->local_ip/local_port`, and
`udp_sendfrom` for source-addressed UDP replies.

Build chain:

```text
fptn/conanfile.py        option with_lwip [True, False], default False
                         → tc.variables["FPTN_WITH_LWIP"]
fptn/CMakeLists.txt      if(FPTN_WITH_LWIP): include(depends/cmake/FetchLwip.cmake)
fptn-protocol-lib/       flow/lwip/*.cpp sources; link fptn_lwip PRIVATE;
CMakeLists.txt           target_compile_definitions(... PUBLIC FPTN_HAS_LWIP=1)
FptnLib/conanfile.py     forwards "fptn/*:with_lwip"
build_fptn_lib.sh        FPTN_WITH_LWIP env → -o flag
                         + with_lwip added to build-manifest identity
                         (prevents stale-framework reuse)
```

lwIP is not linked directly from `FptnLib/CMakeLists.txt`; the capability is
absorbed by the fptn package (`fptn::fptn`).

lwIP configuration (`lwipopts.h`):

```text
NO_SYS 1, LWIP_SOCKET 0, LWIP_NETCONN 0
LWIP_TCP 1, LWIP_UDP 1, LWIP_IPV4 1, LWIP_IPV6 1
raw callback API only
netif MTU 1400 (matches provider mtu), TCP_MSS ≈ 1360
bounded MEMP/PBUF pools sized for the extension memory budget
```

Repo build rules that apply to new code: `-Wall -Werror -pedantic`, clang-tidy
20+ (`fptn/CMakeLists.txt`). lwIP sources get `SKIP_CLANG_TIDY` + `-Wno-error`
exemptions exactly like the YAFF/protobuf generated sources
(`fptn-protocol-lib/CMakeLists.txt:82-100`).

FptnLib build changes for the adapter: `LANGUAGES ... OBJCXX`,
`CLANG_ENABLE_OBJC_ARC YES`, `-framework NetworkExtension -framework Foundation`
(safe for both app and tunnel processes — the app already uses
NetworkExtension).

### 4.5 Apple packet pump (D6)

```objc
@interface FPTNApplePacketPump : NSObject
- (instancetype)initWithPacketFlow:(NEPacketTunnelFlow *)packetFlow
                      tunnelEngine:(FPTNTunnelEngineHandle *)engine;
- (BOOL)startWithGeneration:(uint64_t)generation;
- (void)stop;
@end
```

Ingress (zero-copy normal path):

```text
readPacketsWithCompletionHandler → NSArray<NSData *>
    → CFRetain before callback returns
    → pooled ApplePacketPbuf { pbuf_custom; CFDataRef owner; }
    → pbuf_alloced_custom(PBUF_RAW, len, PBUF_REF, ...)
    → post batch into engine strand (one post per batch)
    → re-arm next read
custom pbuf free → CFRelease(owner) → pool release
```

Egress:

```text
lwIP pbuf chain
    → one coalescing copy into pooled contiguous native buffer
      (writePackets requires one contiguous NSData per packet)
    → NSData initWithBytesNoCopy:length:deallocator: (block captures only the
      opaque lease pointer — no self capture, no retain cycle)
    → writePackets:withProtocols: (cached AF_INET/AF_INET6 NSNumbers)
```

Fallback (counted, correctness over optimization): copy into `PBUF_RAM` when
length unsupported, lease pool exhausted, unexpected/mutable NSData
representation, stack path requires writable storage, or shutdown in progress.

Pools and counters:

```cpp
struct ApplePacketPumpStatus {
    uint64_t borrowed_packets, borrowed_bytes;
    uint64_t fallback_copy_packets, fallback_copy_bytes;
    uint64_t live_nsdata_leases, peak_nsdata_leases;
    uint64_t output_no_copy_packets, output_coalesce_bytes;
    uint64_t live_native_packet_leases, peak_native_packet_leases;
    uint64_t lease_pool_exhaustions;
};
```

Division of labor with Swift — stays in `PacketTunnelProvider.swift`:
start/stop decisions and generations, backpressure policy (0.25s→2s read-delay
ladder), lifecycle gating, telemetry snapshots/flight recorder. Moves to the
pump: readPackets mechanics, one-pending-read invariant, per-packet dispatch,
writePackets calls, batch autoreleasepool handling. The pump reports admission
results so Swift policy keeps working.

### 4.6 lwIP execution model (D7)

lwIP provides only the packet-side TCP/IP state machine; Asio owns everything
around it:

| Responsibility | Implementation |
|---|---|
| Raw IPv4/IPv6 input, application-side TCP/UDP state | lwIP |
| Native execution runtime | one `TunnelRuntime` (`io_context` + work_guard + thread) |
| Serialized lwIP access | one `boost::asio::strand` — the lwIP lock |
| Flow coroutines | `awaitable`/`co_spawn` (existing codebase model) |
| DIRECT TCP | `tcp::socket` — raw TCP, no `ssl::stream` (app TLS rides inside the proxied stream); **no resolver** (destinations are always IP literals from packets) |
| DIRECT UDP | one connected `udp::socket` per association initially (bounded table); shared v4/v6 sockets are a later optimization |
| Deadlines/expiry | `steady_timer`; one deadline heap + single timer for UDP expiry (no per-association timers) |
| Cancellation | Asio cancellation + the existing stronger lifecycle barrier (first terminal reason wins → cancel → active-operation barrier → destroy) |
| pbuf scatter/gather writes | `PbufBufferSequence` adapter: pbuf chain → Asio `ConstBufferSequence` for `async_write` (bounded 16-64 KiB per write); designed in PR-LW3, not retrofitted |
| Socket read buffers | pooled fixed buffers, not per-read allocations |
| Wakeups/commands | `experimental::channel` (strand-confined) behind an FPTN `BoundedFlowQueue` type; `concurrent_channel` only at existing cross-thread seams; channel capacity is never the byte-accounting — FPTN byte reservation is |
| Small op allocations | associated/recycling allocators only after Instruments proves the need |

Subsystem interfaces take `boost::asio::any_io_executor`, not `io_context&`.

lwIP raw callbacks stay short and synchronous: update flow state → admit/retain
buffer → start/wake Asio operation → return. Never block; outbound completions
post back to the lwIP strand. `sys_check_timeouts()` runs on a recurring
strand timer plus on-demand pokes; `sys_now()` implemented against the steady
clock.

L3 mode: `L3TunnelDataPlane` keeps `WebsocketClient` self-contained (own
io_context/thread) — zero behavioral risk until flow mode is proven (D7).

### 4.7 Transparent TCP

```text
tcp_new_ip_type(IPADDR_TYPE_ANY)
    → tcp_bind_netif(listener, &netif)
    → tcp_bind(listener, IP_ANY_TYPE, 0)
    → tcp_listen_with_backlog
    → tcp_accept
```

Accepted PCBs preserve `remote_ip/port` = application source,
`local_ip/port` = original internet destination → `FlowMetadata` → router.

Backpressure contract:

```text
app → outbound:  tcp_recv → retain pbuf → async write over pbuf segments
                 → completion → tcp_recved(consumed) → pbuf_free
                 (never ack bytes before the outbound admits them)
outbound → app:  pooled socket read → tcp_write(TCP_WRITE_FLAG_COPY) → tcp_output
                 → tcp_sent → release accounting
```

Required behaviours: SYN/accept, ordered data, partial writes, app FIN, remote
FIN, simultaneous close, RST propagation, connect failure, idle timeout,
bounded pending bytes, cancellation in every state.

### 4.8 UDP

```cpp
struct UdpFlowKey { IpEndpoint source; IpEndpoint destination; };
struct LwipUdpFlow { FlowId id; udp_pcb* pcb; FlowMetadata metadata;
                     TimePoint last_activity; };
```

Transparent UDP acceptance via the HEV fork; replies use `udp_sendfrom(pcb, p,
real_src_ip, real_src_port)`. Rules: one association per five-tuple, fixed max
association count, fixed max queued datagram bytes, idle expiry (deadline
heap + one timer), oversized datagram rejection, IPv4+IPv6, direct outbound
only, DNS treated as normal UDP. QUIC needs no special stack path.

### 4.9 Mode selection (D2)

- `mrmidi/FptnShared`: add optional `dataPlaneMode: TunnelDataPlaneMode?`
  (`l3Tunnel`/`flowProxy`) to `TunnelStartupConfigurationV1` with
  `decodeIfPresent` + default `.l3Tunnel`; `schemaVersion` stays 1
  (additive, back-compat); new package release; pin bump in `project.yml`.
- App side: coordinators/`NETunnelController` write the field.
- Tunnel side: `TunnelConfiguration.init?(providerConfiguration:)` maps it into
  the native `TunnelBridgeConfiguration`; `.l3Tunnel` is the compatibility
  default everywhere.

### 4.10 Lifecycle and teardown invariants

Stop sequence:

```text
reject new packet ingress → cancel timeout scheduler → stop accepting flows
→ cancel all outbounds → post resets/closes onto lwIP strand → drain callbacks
→ verify counts zero → destroy netif and stack → return from stop
```

Required final invariants (asserted in debug, exposed in status in release):

```text
active_tcp_flows == 0          active_udp_flows == 0
retained_pbufs == 0            retained_pbuf_bytes == 0
pending_stack_tasks == 0       pending_outbound_ops == 0
timeout_timer_armed == false
live_nsdata_leases == 0        live_native_packet_leases == 0
```

No lwIP object may outlive `TunnelEngine::Stop()`. Network-path change may
reset active flows; migration is out of scope.

### 4.11 Diagnostics

```cpp
struct FlowProxyStatus {
    uint64_t input_packets, input_bytes, output_packets, output_bytes;
    uint64_t active_tcp_flows, peak_tcp_flows;
    uint64_t active_udp_flows, peak_udp_flows;
    uint64_t retained_pbufs, retained_pbuf_bytes, peak_retained_pbuf_bytes;
    uint64_t tcp_backpressure_events, tcp_resets, udp_drops;
    LwipCopyCounters copies;   // ingress copy/egress coalesce packets+bytes
};
```

No per-packet logs. Gauges, lifetime counters, coarse state events, signposts
for stack lifetime/shutdown, debug-only assertions. Pump and flow counters
fold into the existing `TunnelStatusSnapshotV1` polling and lifecycle snapshot
plumbing.

## 5. Repo seams (verified)

- Submodule: `FptnLib/fptn` (mrmidi/fptn); `fptn-protocol-lib_static` is the
  exported static lib consumed as `fptn::fptn`.
- New native dirs: `fptn/src/fptn-protocol-lib/tunnel/` (seam + flow types),
  `fptn/src/fptn-protocol-lib/flow/lwip/` (stack adapter),
  `fptn/src/fptn-protocol-lib/flow/outbound/` (DIRECT),
  `fptn/depends/cmake/FetchLwip.cmake` + `fptn/depends/lwip/patches/`.
- Wrapper: `FptnLib/src/tunnel/` — `WrapperTunnelSwiftBridge.{h,cpp}`,
  `ApplePacketPump.{h,mm}`; added to the explicit source list in
  `FptnLib/CMakeLists.txt` (headers auto-picked by the PUBLIC_HEADER glob).
- Tests: `fptn/tests/fptnlib/tunnel/` + `fptn/tests/fptnlib/flow/` (gtest;
  built only in full host builds, i.e. host macOS CI).
- Swift: `FptnVPNTunnel/Cpp/` bridge wrapper + bridging header include;
  `FptnVPNTunnel/PacketTunnelProvider.swift` rewiring; FptnShared payload
  field; `FptnVPN` coordinators/`NETunnelController` write the mode.
- Build staleness guard: `build_fptn_lib.sh` manifest must gain `with_lwip`
  identity.

## 6. Known hazards and mitigations

| Hazard | Mitigation |
|---|---|
| lwIP input path may write into borrowed immutable pbufs (header fixups, RST generation) | LW2 **ingress writability audit** (debug canaries); affected packet classes use the counted copy fallback until proven read-only. Zero-copy is an optimization, never a correctness dependency. Hev's tun2socks products use this borrow pattern in production, but we verify per packet class. |
| Stale read callbacks after stop/reconnect | Generation stamp captured at read-issue time; stale batches release packets without forwarding (existing `PacketReadToken` invariant moved into the pump). |
| NSData representation surprises (mutable, discontiguous, oversized) | Fallback copy path + `fallback_copy_*` counters. |
| Provider-own socket capture loop (DIRECT outbound) | Non-issue: provider-own traffic bypasses the tunnel (proven daily by the WebSocket transport). Re-verified for raw TCP/UDP at PR-LW4 exit. |
| Extension memory ceiling | Bounded pools/watermarks (retained-pbuf watermark ≈ existing 2 MiB inbound budget); byte-reservation before copy (existing PR1B admission pattern). |
| Stale framework reuse when toggling `with_lwip` | Manifest identity field in `build_fptn_lib.sh`. |
| `-Werror`/clang-tidy vs third-party lwIP | Per-source `SKIP_CLANG_TIDY` + `-Wno-error`, matching the generated-code precedent. |
| macOS/tvOS compile break from in-place ABI replacement | Minimal compile-keep in PR-LW6; migration tracked as follow-up. |

## 7. PR sequence

| PR | Scope | Exit gate |
|---|---|---|
| **LW0** seam | `DataPlaneMode`, `IDataPlane`, `TunnelEngine`, `L3TunnelDataPlane` over existing `WebsocketClient`; `IpEndpoint`/`FlowMetadata`/flow interfaces; portable `PacketLease` ingress types. Production untouched | Host gtest green in `tests/fptnlib/tunnel/`; existing tests green |
| **LW1** dep + build | FetchContent pinned-SHA lwIP + patches + `PATCHES.md`; `with_lwip` option chain; `fptn_lwip` target; `FPTN_HAS_LWIP`; `lwipopts.h`; build-manifest field; license inventory | arm64 + simulator frameworks link; `with_lwip=False` behavior unchanged |
| **LW1A** Apple packet pump | FptnLib OBJCXX + ARC + NetworkExtension; `FPTNApplePacketPump.mm` owns read/write loops; NSData leases + bounded pools + no-copy egress wrappers; portable lease handoff to the existing L3 bridge; counters; Swift keeps policy/telemetry | L3 behavior unchanged; no Swift packet payload transformation; egress stays no-copy; all leases return to zero after stop; start/stop + stale-callback stress passes |
| **LW2** netif + packet pump | `LwipExecutor` strand + `sys_check_timeouts` timer + `sys_now()`; IP-only `LwipNetif` (IP input path, not `ethernet_input`); pbuf lease wiring from the pump; **ingress writability audit**; egress coalesce → owned batch; copy counters | Synthetic IPv4/IPv6 packets in → valid native output |
| **LW3** transparent TCP frontend | Pretend-TCP listener; `LwipTcpFlow` state; router/sink wiring; **`PbufBufferSequence` (pbuf chain → ConstBufferSequence) designed here**; `FakeOutbound` | Deterministic synthetic TCP connection end-to-end (unit tests) |
| **LW4** DIRECT TCP + backpressure | `ITcpOutbound` + `DirectTcpOutbound` (Asio coroutine, raw TCP, no resolver); pooled rx buffers; bounded writes; `tcp_recved`-after-admission; FIN/RST/idle/cancel; byte-reserved queues | Real HTTP/TLS through the harness on host; provider-socket bypass re-proven |
| **LW5** UDP | Transparent UDP; bounded association table; connected `udp::socket` per association; deadline-heap + single timer expiry; `udp_sendfrom` replies; IPv4+IPv6 | UDP round trips + bounded teardown; DNS/QUIC validation |
| **LW6** NE integration | In-place bridge replacement: `TunnelSwiftBridge` (pump-facing batch ingress ABI, lease output ABI); FptnShared `dataPlaneMode` field + pin bump; provider + coordinators + `NETunnelController` wiring; `.l3Tunnel` default; macOS/tvOS compile-keep | Both modes run on physical iOS hardware |
| **LW7** hardening | Fuzzing; memory ceilings; start/stop stress; path changes; teardown invariants all zero; Instruments (Allocations/VM Tracker); L3-vs-flow throughput/CPU; release size delta | No leaked PCBs, pbufs, flows, tasks or sockets after stop |

Later independent work: `FptnL4TcpOutbound`/`FptnL4UdpOutbound` + server-side
proxy sockets + flow protocol credit windows; geo routing (geosite/geoip,
policy profile, route matcher, runtime snapshot updates); macOS/tvOS tunnel
migration; desktop `TunFileDescriptorAdapter`; zero-copy egress/ingress
refinements only after counters prove copies matter.

## 8. Testing strategy

Native unit tests (host macOS gtest, synthetic packet harness):

1. IPv4 TCP handshake + data; 2. IPv6 TCP handshake + data;
3. partial outbound admission; 4. backpressure delays `tcp_recved`;
5. FIN from application; 6. FIN from outbound; 7. RST from either side;
8. connect failure → application reset; 9. UDP IPv4 round trip;
10. UDP IPv6 round trip; 11. UDP association expiry; 12. malformed packet
rejection; 13. shutdown with active TCP+UDP flows; 14. repeated start/stop;
15. resource counters return to zero.

Integration (local echo server + synthetic TUN client): HTTP request, TLS
stream, large upload/download, bidirectional, slow reader/writer, abrupt peer
closure.

Apple end-to-end (on device): Safari HTTPS, IPv4-only site, IPv6-capable site,
DNS, QUIC/HTTP3, Wi-Fi→cellular, airplane-mode interruption, repeated
connect/disconnect, Instruments Allocations + VM Tracker, throughput/CPU vs L3.

## 9. Definition of done

1. Existing `L3Tunnel` behaviour unchanged.
2. `FlowProxy` selectable at startup via the versioned payload.
3. Flow mode supports IPv4/IPv6 TCP and UDP.
4. DIRECT HTTPS, DNS and QUIC work on physical iOS hardware.
5. No local SOCKS server.
6. All lwIP access confined to one native execution context (strand).
7. Buffers and flow counts strictly bounded.
8. Backpressure reaches the application-side TCP stream.
9. `Stop()` returns only after every PCB, pbuf, outbound op, timer, NSData
   lease and native lease is gone.
10. Route and outbound abstractions ready for GeoDB and FPTN L4 without
    exposing lwIP types.
11. No Swift code executes per packet; no Foundation types cross into the
    portable engine.

Central decision:

> FPTN keeps its current packet tunnel as one data plane, while an optional
> pinned transparent-lwIP component converts Apple Network Extension packets
> into native TCP/UDP flows behind a stack-neutral FPTN interface, with an
> Objective-C++ adapter owning the zero-copy Foundation boundary.
