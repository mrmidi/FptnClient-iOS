# Implementation Plan — Split Routing (DIRECT / FPTN / BLOCK) on the lwIP Flow Plane

Follow-on to `docs/lwip-flow-plan.md` (LW0–LW7), which delivered a working
DIRECT-only flow data plane. This plan covers turning it into a per-flow router.

## 1. Goal

Route each flow to one of three verdicts, decided by destination domain:

| Verdict  | Test policy      | Meaning                                          |
|----------|------------------|--------------------------------------------------|
| `direct` | `2ip.ru`         | Leaves via the device's own interface, real IP    |
| `fptn`   | everything else  | Leaves via the FPTN server, server IP             |
| `reject` | `mail.ru`        | Never leaves; app fails **immediately**           |
| `drop`   | (none yet)       | Never leaves; silent black hole                   |

`2ip.ru` is the verification target on purpose: it echoes the public IP, so a
single page load proves which plane carried the flow.

Long term the static lists are replaced by Xray-compatible `geosite.dat` /
`geoip.dat` behind the same interface. That loader is **not** in this plan.

## 2. The finding that shapes everything

**`IFlowRouter::Match()` is called too late to honour an `fptn` verdict.**

Verified in the vendored lwIP:

- `tcp_in.c:728` — `tcp_listen_input()` enqueues `TCP_SYN | TCP_ACK` immediately
  on receiving a SYN.
- `tcp_in.c:962` — `TCP_EVENT_ACCEPT` fires from `tcp_process()`, i.e. only once
  the connection reaches ESTABLISHED.

So by the time `flow/lwip_tcp.cpp:227` asks the router, we have already sent the
SYN-ACK, received the app's ACK, and become its TCP peer. A flow cannot be
un-terminated. `direct` and `block` are still expressible there (both end with
us owning the connection), but `fptn` is not.

**Therefore the verdict must be decided at packet ingress, before `ip_input()`.**

## 3. Locked decisions

**D1 — FPTN is raw pass-through, not a new `ITcpOutbound`.**
The FPTN protocol carries **IP packets** over the websocket (`WebsocketClient`
consumes `IPPacketPtr`, returns `BatchIPPacketPtr`). Implementing
`FptnTcpOutbound : ITcpOutbound` would mean re-originating a TCP connection as
synthesized IP packets — a *second* TCP state machine producing segments almost
identical to the ones lwIP just tore apart. Double the state, double the
per-flow memory, zero benefit. FPTN-verdict packets are forwarded **unmodified**
to the existing, already-hardened L3 path.

Consequence — a clean division of labour:

```
                         ┌─ direct → lwIP (terminate) → local socket → real IP
                         ├─ reject → lwIP (terminate) → RST
packetFlow ─ classifier ─┼─ drop   → discarded here; never enters lwIP
                         └─ fptn   → websocket (raw L3, untouched) → server IP
```

Only `direct` and `reject` flows ever get a pcb. lwIP's memory and CPU cost now
scales with *split-out* traffic, not with all traffic.

**D2 — blocking is two verdicts, `reject` and `drop`, not one.**
Adopted from sing-box, which exposes `PreMatchReject` and `PreMatchDrop` as
separate actions rather than choosing between them (§9.4). Fast failure is right
for a blocked site — the user should see it fail, not watch a spinner. A silent
black hole is right for ad and telemetry endpoints, where an RST is itself a
signal and a timeout costs the caller nothing.

`RouteAction` (`tunnel/flow_types.h:26`) becomes:

```cpp
enum class RouteAction : std::uint8_t {
  direct = 0,
  fptn_l4 = 1,
  reject  = 2,   // was `block`
  drop    = 3,
};
```

Renaming `block` → `reject` costs nothing: `grep RouteAction` finds the value
referenced nowhere outside the declaration, since the only implemented verdict
today is `direct`.

**The split falls out of what already exists.** Terminating a TCP flow naturally
yields reject (a RST); dropping a UDP datagram naturally yields drop. The
current code already does both — it just conflates them under one enum value:

| Verdict  | TCP | UDP |
|----------|-----|-----|
| `reject` | lwIP accepts, then RSTs — exists at `lwip_tcp.cpp:229` | ICMP port unreachable — **not implemented**, see below |
| `drop`   | classifier drops the packet; never enters lwIP | classifier drops the packet; never enters lwIP |

So `drop` never reaches lwIP at all — uniform across both protocols and free (no
pcb). `reject` enters lwIP and reuses the existing, reentrancy-hardened reset
path. Only `direct` and `reject` are ever visible to `IFlowRouter::Match()`.

**Known degradation, stated rather than hidden: UDP `reject` behaves as `drop`
in the first pass.** Generating ICMP port-unreachable is new work and is not
worth blocking R1 on. The existing `lwip_udp.cpp:192-197` path (count + abandon)
stays as a defensive fallback for any non-direct verdict that reaches the stack.

Cost of `reject`: one transient pcb per blocked TCP connection. Accepted;
revisit only if profiling shows it matters.

**D3 — three engine modes; the release switch exposes two of them.**
See §3.1. `flow_proxy` (direct-only) is **development/profiling only** and must
never be reachable in a release build. Add `DataPlaneMode::split`.
`l3_tunnel` is unchanged and *is* the "FPTN only" product mode.

### 3.1 Mode taxonomy

| `DataPlaneMode` | Product meaning | lwIP? | Websocket? | Availability |
|-----------------|-----------------|-------|------------|--------------|
| `l3_tunnel`     | **FPTN only** — all traffic via the server | no | yes | Release + debug |
| `split`         | **Split** — direct + FPTN per policy | yes | yes | Release + debug |
| `flow_proxy`    | Direct only, no server | yes | no | **Debug only** |

**"FPTN only" is the existing `l3_tunnel`, not split-with-an-all-FPTN-policy.**
Building it as a degenerate split would drag lwIP and the per-packet classifier
into every session for nothing, and would throw away the one path that is
already shipping and hardened. Keeping a genuinely lwIP-free mode is also what
lets us answer "is lwIP at fault?" by flipping one switch.

Two consequences worth having in mind:

- **The network settings are identical in both product modes.** Split routing
  happens *inside* our process — we still need iOS to hand us every packet, so
  `NEPacketTunnelNetworkSettings` keeps the same default route and the same
  resolvers. Only the internal handling differs. Changing modes still needs a
  tunnel restart (lwIP has to come up or go away), but not a settings redesign.
- **Split degrades safely into FPTN-only.** The default verdict is `fptn`, so an
  empty policy, a failed DNS observation, or an unattributable destination all
  fall back to tunnelling. Split with an empty policy ≡ FPTN-only in observable
  behaviour, which is also a free end-to-end test.

### 3.2 Swift-side switch

`TunnelRuntimeOptions.dataPlaneMode` already carries the mode. What changes is
the selector at `VPNService.swift:762-786`, currently a `Bool`
(`settings.flowDataPlaneEnabled`) mapped to `.flowProxy : .l3Tunnel`. It becomes
a persisted **enum** with the release switch offering FPTN-only vs Split.

**Carry the existing defensive clamp forward.** The comment at
`VPNService.swift:768-772` records a real hazard: a value persisted in
`UserDefaults` by a debug build must not select a debug-only mode after the user
moves to release. Hiding the UI is not sufficient. In release, any persisted
`flow_proxy` must be clamped to `l3_tunnel` — the safest mode, not `split`.

**D4 — one policy engine, two consult points, one source of truth.**
The classifier decides and records the verdict in a flow table. lwIP's existing
`IFlowRouter::Match()` is kept, but its implementation *reads the recorded
verdict* rather than deciding again. `fptn` never reaches it. This keeps the
`IFlowRouter` seam intact and guarantees the two points cannot disagree.

**D5 — the verdict is decided once per flow and never re-evaluated.**
If the DNS map updated mid-flow and flipped a verdict, packets of an established
connection would change planes and the connection would break. Decide on the
first packet, cache, expire on idle.

**D6 — composition, not inheritance.** `SplitDataPlane` owns an
`L3TunnelDataPlane` and an `LwipStack` + direct outbounds. Neither existing
class is modified structurally.

## 4. How the DNS problem dissolves

Today flow mode requires a custom DNS: `/api/v1/dns` returns tunnel-internal
resolvers, flow mode routes everything `direct`, so there is no path to them.
`PacketTunnelProvider.swift:1233-1234` filters them out via
`isFlowReachableResolver` and fails fast.

In split mode this fixes itself, and the fix *is* the classification mechanism:

1. Advertise the FPTN server's resolvers to iOS via `NEDNSSettings`, exactly as
   L3 mode does.
2. A pinned classifier rule sends **all traffic to those resolver addresses** to
   `fptn`. They are reachable through the tunnel, so resolution works.
3. Responses come back as IP packets through the L3 ingress callback
   (`on_packet_batch`) — which is precisely where we can read them.

**The DNS path and the classification path are the same path.** A `DnsObserver`
taps the L3 ingress, parses response answer sections, and records
`IP → domain` with the record's TTL. When a SYN to that IP arrives, the
classifier resolves IP → domain → policy verdict.

`isFlowReachableResolver` and its call site should be **removed** when split mode
lands — it exists only to paper over the missing tunnel.

### Known limits of DNS snooping (accept for now, document)

- **Answers are resolved server-side.** A CDN may hand back a PoP near the
  server while we then connect directly to it. Harmless for `2ip.ru`; worth
  remembering before trusting it for latency-sensitive direct routes.
- **Encrypted DNS is invisible.** An app using DoH/DoT bypasses the observer and
  falls to the default verdict. `NEDNSSettings` covers the system resolver,
  which is the common case.
- **IP-literal connections have no domain** → default verdict (`fptn`). Correct
  and safe.
- **First connection race.** Traffic can in principle arrive before the mapping
  is recorded; the DNS response necessarily precedes the SYN for name-based
  connections, so this is theoretical rather than practical.

## 5. Components to build

### 5.1 `FlowClassifier` (new)

Sits in `SplitDataPlane::InputPackets`, ahead of both planes.

- Non-allocating header peek over `PacketLease{bytes, length}` → 5-tuple
  (proto, src ip/port, dst ip/port). Do **not** use
  `IPPacket::Parse` here — it allocates, and this runs per packet.
- `unordered_map<FiveTuple, Entry>` where `Entry = {RouteAction, last_seen}`.
  Idle expiry sweep on the existing runtime executor.
- First packet of a flow → consult pinned rules, then `IRoutingPolicy`. Cache.
- Subsequent packets → table lookup only.

Pinned rules, evaluated before policy:

1. Destination == FPTN server IP:port → never tunnel (loop guard).
2. Destination ∈ advertised resolvers → `fptn`.
3. Otherwise → policy.

### 5.2 `DnsObserver` (new)

Taps the L3 ingress batch. Parses DNS responses (A/AAAA/CNAME) and maintains
`IP → domain` with TTL expiry. Read-only: it never modifies or delays a packet.

### 5.3 `IRoutingPolicy` + `StaticDomainPolicy` (new)

```cpp
class IRoutingPolicy {
 public:
  virtual ~IRoutingPolicy() = default;
  // `domain` is empty when the destination could not be attributed.
  virtual RouteAction Decide(
      const FlowMetadata& flow, std::string_view domain) const = 0;
};
```

`StaticDomainPolicy` holds one suffix list per non-default verdict — direct,
reject, drop — plus the default verdict (`fptn`). Later `GeositePolicy`
implements the same interface; the geosite categories map naturally onto the
four verdicts (Russian services → `direct`, blocked → `fptn`, ads → `drop`,
with `reject` reserved for user-blocked sites that should fail visibly).

**Suffix matching must be label-aware.** `notmail.ru` must not match `mail.ru`;
compare from the right at label boundaries only.

### 5.4 `SplitDataPlane` (new)

Owns `L3TunnelDataPlane`, `LwipStack` + direct outbounds, `FlowClassifier`,
`DnsObserver`. Implements `IDataPlane`. Fans out `InputPackets`; merges both
egress sources into the packet-flow writer.

### 5.5 `TableBackedRouter` (replaces `DirectRouter`)

`FlowProxyDataPlane::DirectRouter` is currently a private nested struct held as
`unique_ptr<DirectRouter>` — not injectable. Change the member to
`unique_ptr<IFlowRouter>` and inject. In `split` mode inject a router that reads
the classifier's table; in `flow_proxy` mode keep today's always-`direct` one so
the macOS stand is unaffected.

Per D2 the table-backed router can only ever return `direct` or `reject` —
`drop` and `fptn` are resolved before the stack. Treat anything else reaching
`Match()` as a bug and assert in debug builds rather than silently rejecting.

## 6. Hazards

**H1 — batch lease ownership across the fan-out. Highest risk.**
The `InputPackets` contract (`packet_types.h`) is all-or-nothing: on `accepted`
the plane owns every lease and releases each exactly once; on any other result
the caller still owns every lease and no release has happened. Splitting one
batch across two planes breaks that atomicity — if lwIP accepts its half and the
websocket returns `queue_full`, there is no result value that describes the
state.

Resolution: **two-phase commit.** `WebsocketClient` already exposes exactly this
(`TryReserveBatch` / `ForgetPacket` / `Commit`, used in
`l3_tunnel_data_plane.cpp`), and the lwIP side has `max_ingress_inflight_bytes`
to gate against. Reserve on both sub-batches, commit both, or roll back both and
return `queue_full`. Design this before writing the fan-out, not after.

**H2 — startup ordering: the tun IP is server-assigned.**
`ipAssignedCallback` (`PacketTunnelProvider.swift:751`) delivers the address at
websocket-connect time, and `clientIPv4 = assignedIPv4 ?? configuration.tunIPv4`
falls back to `10.8.0.2` only if the server assigns nothing. Today's flow mode
brings lwIP up immediately with the static value.

Split-mode startup must therefore be: **start L3 → await connect + assignment →
bring up lwIP with the assigned address → `applyNetworkSettings`**. This also
means start can now fail at a new point (connected but no assignment), which
needs an explicit error path rather than a hang.

**H3 — flow-table growth.** The classifier table duplicates a little state per
flow. Keep `Entry` to a verdict plus a timestamp, bound the table, and expire on
idle. Do not let it grow with the DNS map's lifetime.

**H4 — no memory conclusions without fresh measurement.** The previously
recorded "42 MB peak" was Instruments overhead, not the tunnel. Any claim about
split mode's footprint needs a new measurement on the macOS stand
(`FPTN_LOAD_FLOWS` sweep, `phys_footprint` via `TASK_VM_INFO`).

**H5 — `max_udp_associations = 32`** (`flow/lwip_stack.h`). In split mode only
DIRECT UDP reaches lwIP, so pressure drops — but confirm the cap is still right
once real policy is in play.

## 7. PR sequence

| PR   | Content                                                              | Verify |
|------|----------------------------------------------------------------------|--------|
| R1   | `RouteAction` split (`block` → `reject` + `drop`, D2); `IRoutingPolicy` + `StaticDomainPolicy` + label-aware suffix match | Unit tests only; no wiring |
| R2   | `FlowClassifier` + 5-tuple peek + flow table + pinned rules           | Unit tests over synthetic leases |
| R3   | `DnsObserver` (parse, TTL map)                                       | Unit tests over captured DNS responses |
| R4   | `DataPlaneMode::split`, `SplitDataPlane` skeleton, two-phase fan-out (H1) | macOS stand, both planes stubbed |
| R5   | Inject `IFlowRouter`; `TableBackedRouter`; keep `flow_proxy` behaviour | macOS stand unchanged |
| R6   | Startup sequencing (H2) + remove `isFlowReachableResolver`            | Device |
| R7   | Swift mode switch: `Bool` → enum, release UI (FPTN-only / Split), debug-only `flow_proxy` + release clamp (§3.2) | Device, both modes |
| R8   | End-to-end policy test on device                                     | See §8 |

R1–R3 are pure, testable units with no device dependency — build them on the
macOS stand first.

## 8. Definition of done

### 8.0 Bring-up order before the end-to-end tests

Per Apple DTS guidance on debugging NE providers, do not start with a browser —
it is too much machinery to localise a failure. Escalate with a tiny test app,
and note that each rung exercises a *different* classifier path:

1. **TCP to an IP literal** — no domain available, so this tests the
   unattributable-destination path and the default verdict (`fptn`).
2. **TCP to a DNS name** — tests the `DnsObserver` mapping and attribution;
   the first rung where a `direct`/`reject` verdict can be reached at all.
3. **UDP** — tests the separate UDP classifier path and idle expiry.

Only then move to real sites. On the macOS stand `nc`, `dig` and `netstat`
cover rungs 1–3 directly.

**Use `tcpdump` to make the `reject`/`drop` distinction objective.** Points 3–4
below are otherwise judged by feel ("failed fast" vs "hung"); the real assertion
is whether an RST appears on the wire. `reject` must produce one, `drop` must
produce nothing.

**Install the Network Diagnostics and VPN (Network Extension) profiles** from
Apple's Bug Reporting > Profiles and Logs page before any log-based debugging.
They enable extra logging and, critically, **recording of `%{private}` data** —
without them the interesting fields in our own `os_log` output are redacted to
`<private>`.

**Caveat on lldb in the extension:** stopping at a breakpoint times out
in-flight network requests, so counters read at a breakpoint can reflect flows
that died *because* you stopped. Prefer logging and the macOS stand for anything
timing-sensitive.

### 8.1 Acceptance

On device, with the test policy loaded and server-supplied DNS (no custom DNS):

1. `2ip.ru` reports the **device's own** public IP.
2. Any other IP-echo site reports the **FPTN server's** IP.
3. `mail.ru` (verdict `reject`) fails **immediately**, not after a timeout —
   this is what distinguishes `reject` from `drop` and is the whole reason D2
   keeps both.
4. A domain moved to `drop` instead hangs until the app's own timeout, with no
   RST on the wire. Test by reclassifying `mail.ru`, not by adding a second
   site — the contrast is the assertion.
5. Name resolution works throughout without a custom resolver.
6. Counters show non-zero `active_tcp_flows` **and** non-zero websocket traffic
   simultaneously — proving both planes are live in one session.

Point 6 is the real acceptance test: it is the one thing that cannot be faked by
either plane working alone.

Then, on the switch itself:

7. **FPTN only** carries all traffic via the server, including `2ip.ru`, and
   brings up **no lwIP** at all (`active_tcp_flows` stays zero).
8. Toggling the switch while connected restarts the tunnel cleanly and lands in
   the selected mode.
9. A release build with `flow_proxy` persisted in `UserDefaults` from a debug
   build starts in `l3_tunnel`, never direct-only (§3.2).

Point 9 is a leak-of-debug-state test, not a routing test — but it is the one
that would silently expose a user's real IP if it regressed.

## 9. Prior art: sing-box-for-apple

Read from a local clone. **Scope caveat:** that repo is only the Apple shell —
`Libbox.xcframework` is referenced by the pbxproj but built separately from the
Go core, so the routing engine is *not* in it. Everything in §9.1–9.3 is
verified from the clone; §9.4 is from general knowledge of sing-box and is
**unverified here**.

### 9.1 The Apple layer does almost nothing (verified)

`Extension/PacketTunnelProvider.swift` is four lines. All of
`ExtensionPlatformInterface.openTun0()` does is translate options *supplied by
the Go core* into `NEPacketTunnelNetworkSettings`, apply them, and hand back a
file descriptor. Route selection, DNS, sniffing and the network stack are all
Go-side.

### 9.2 They bypass `NEPacketTunnelFlow` entirely (verified)

`ExtensionPlatformInterface.swift:212`:

```swift
if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
```

with a fallback scan at :217 (`LibboxGetTunnelFileDescriptor()`).
`readPackets`/`writePackets` appear **nowhere in the repo** — that line is the
only `packetFlow` reference at all. Go then does raw reads/writes on the utun fd.

This removes the entire batch/lease/callback layer that our per-packet cost
lives in. It is also KVC against an undocumented key path on a private ivar —
App Store risk, and the fallback exists precisely because it is fragile.

**Explicitly out of scope for this plan.** It is a data-path performance
question, not a routing one; evaluate separately and do not let it derail R1–R8.

### 9.3 A third split mechanism we had not considered (verified)

`getInet4RouteAddress()` / `getInet4RouteExcludeAddress()` feed
`ipv4Settings.includedRoutes` / `excludedRoutes` — the Go core tells iOS which
prefixes to hand over and which to leave alone. Split routing *before* any
packet reaches the process: zero per-packet cost, but CIDR granularity only,
fixed at connect time, no domain awareness. Insufficient for `2ip.ru`, but the
right tool for coarse exclusions.

Three practical NE tricks worth stealing regardless of routing architecture:

- **`excludeAPNsRoute`** — excludes `17.0.0.0/8` and bypasses `push.apple.com`.
  APNs through a VPN is a known problem.
- **`excludeDefaultRoute`** — appends `0.0.0.0/31` + `::/127` to the exclusions,
  labelled in their UI as **"Hide VPN Icon"**: with no literal default route iOS
  stops showing the VPN badge.
- **`autoRouteUseSubRangesByDefault`** — a `1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6 …
  128.0.0.0/1` ladder that covers `0.0.0.0/0` without *being* the default route.
  Their note says it fixes HomeKit compatibility.

### 9.4 The Go core (verified against sing-box v1.14.0-beta.9)

An earlier draft of this section claimed sing-box terminates every flow. **That
is wrong for v1.14**, which has a pre-stack verdict layer that is structurally
the same as the classifier designed here. The claims about FakeIP and sniffing
survive and are now *verified* rather than inferred.

**They arrived at our architecture.** `adapter.JudgeFlow(...)`
(`adapter/router.go:52`) is called from sing-tun with the 5-tuple **and the
first packet**, before anything is terminated, and returns a `tun.FlowVerdict`.
`adapter.PreMatchAction` (`adapter/router.go:33`):

| Action | Meaning | Our equivalent |
|---|---|---|
| `PreMatchContinue` | fall through and terminate in the userspace stack | lwIP `direct` |
| `PreMatchFlow` | hand packets to a packet-level outbound (`tun.Port`) | `fptn` pass-through |
| `PreMatchReject` | reject — fast failure | `block` (via lwIP RST) |
| `PreMatchDrop` | silent drop | `block` (drop at classifier) |
| `PreMatchBypass` | don't touch the flow at all | — |
| `PreMatchHijackDNS` | intercept DNS | our pinned DNS rule |

**Note they expose reject *and* drop as distinct actions.** That is the exact
trade-off weighed in D2, and their answer is to offer both rather than choose.
Worth copying: fast-fail is right for a blocked page, silent drop is right for
ad/telemetry endpoints that should look like a black hole.

**`FlowOutbound` implementers are exactly the L3-shaped protocols** — grep for
`func .*PreMatchFlow`: `direct`, `bridge`, `openvpn` (client + server),
`tailscale`, `openconnect`, `wireguard`. Conspicuously absent: shadowsocks,
vmess, trojan, vless, socks, hysteria, tuic — the stream protocols, which still
must terminate because they consume a `net.Conn` (`adapter.Outbound` embeds
`N.Dialer`, `adapter/outbound.go:15`).

**That is the strongest available validation of D1.** The protocols that get the
packet-level fast path are precisely the ones that carry IP packets, like FPTN.
The rule generalises: *L3-shaped outbounds get pass-through; L4/L7 outbounds must
terminate.* We are L3-shaped.

#### FakeIP is incompatible with pass-through — now proven, not inferred

`PreMatch` calls `prepareMatchMetadata` (`route/route.go:313`), which on a
FakeIP hit rewrites `metadata.Destination` into the FQDN and stashes the
original in `OriginDestination` (`route/route.go:545-558`). Then the bypass
action guards on it (`route/route.go:379-386`):

```go
if action.Outbound == "" {
    if metadata.Destination.IsDomain() || metadata.Destination != packetDestination {
        return continueResult   // ← refuse to bypass; fall through to terminate
    }
    return adapter.PreMatchResult{Action: adapter.PreMatchBypass}
}
```

If the destination became a domain (FakeIP) or was otherwise rewritten, **bypass
is refused** and the flow is terminated — because a packet addressed to a
fictional IP cannot be forwarded. sing-box enforces exactly the incompatibility
this plan assumed. **Adopting FakeIP is a decision to terminate everything.**

#### Pre-stack sniffing is UDP-only

`route/route.go:333-335` bails out of the sniff action unless the network is UDP
and a first packet exists. Stream sniffers (`TLSClientHello`, `HTTPHost`, `SSH`,
`RDP` …) run only in `actionSniff` (`route/route.go:690`), which takes a live
`inputConn` and calls `sniff.PeekStream`. A TCP SYN carries no payload, so SNI
is unreachable before termination — as assumed. Packet sniffers
(`QUICClientHello`, `DomainNameQuery`, `STUN`, `DTLS`, `NTP`) *do* work
pre-stack.

#### Our DNS-snooping approach is first-class in sing-box

When the destination is not a FakeIP, `prepareMatchMetadata` falls back to
`r.dns.LookupReverseMapping(addr)` (`route/route.go:559`, implemented at
`dns/router.go:1339`) — recovering the domain from previously observed DNS
answers. That is precisely the `DnsObserver` in §5.2. It is the attribution
mechanism that *coexists with* pass-through, which is why §4 is the right choice
and not a compromise.
