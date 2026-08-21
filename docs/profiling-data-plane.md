# Profiling the data plane

How to get a trustworthy number out of the packet path. macOS only — the
provider is shared with iOS, so it is the same code, and Instruments works
properly with no jetsam limit in the way.

Read this before optimizing anything in `flow_classifier`, `split_data_plane`,
or the websocket egress path.

---

## The rule that shapes everything below

`steady_clock::now()` costs ~57 cycles. The entire classifier hot path costs
~95. An `os_signpost` costs ~50–100 ns.

**You cannot time this path with a clock or a signpost — the probe is larger
than the signal.** Everything here is therefore counters (at packet rate) and
sampling (for attribution). Timers and signposts are legitimate only at batch
granularity or coarser.

---

## 1. Build the thing you actually mean to measure

This is the step that invalidates results silently, so it comes first.

| Xcode config | CMake type | Native flags | Debug info |
|---|---|---|---|
| `Debug` | `Debug` | `-O0` | full `-g` |
| `Release` | `MinSizeRel` | `-Oz -ffunction-sections -fdata-sections` | none |
| `Measurement` | `MinSizeRel` | same as Release | none |

Mapping lives in `build_fptn_lib.sh` (`resolve_build_type`); the `-Oz` line is
`FptnLib/CMakeLists.txt:50`. Invoking the script with no `$CONFIGURATION` set
defaults to **Debug**.

Why it matters — same benchmark, same machine, varying only the flag:

| Level | `FiveTupleHash` v4 | `find()` | Full classifier path |
|---|---|---|---|
| `-O0` | 91 cyc | 404 cyc | **571 cyc** |
| `-Oz` (ships) | 18 cyc | 45 cyc | **95 cyc** |
| `-Os` | 15 cyc | 25 cyc | 84 cyc |
| `-O2` | 12 cyc | 23 cyc | 82 cyc |

A Debug build makes this path look **6× more expensive than it is**. An
estimate taken against `-O0` will point you at the wrong bottleneck.

### Build it

```bash
CONFIGURATION=Release ./build_fptn_lib.sh macos
./build.sh --release --scheme Fptn-macOS --sdk macosx \
           --destination 'platform=macOS' --native-target macos
```

### Verify what actually loaded

Fastest check, and the only one that reports the framework the running process
really has: the extension prints its provenance on startup.

```bash
/usr/bin/log stream --process Fptn-macOS-Tunnel --info | grep 'Build:'
```

```
Build: native Debug -O0 · macos · assertions on · fptn f3f0e7c | swift Debug |
NOT REPRESENTATIVE: native framework is -O0 — profiles will misrank hot spots
```

`NOT REPRESENTATIVE` means stop and rebuild. Check the `fptn <sha>` too — if it
does not match `git -C FptnLib/fptn rev-parse --short HEAD`, the loaded
framework predates your source changes and any new counter will be missing.

Note `/usr/bin/log` rather than `log`: a shell function named `log` in the
profile shadows the real binary and fails with "too many arguments".

### Verify what you built

Do **not** read `FptnLib/build-macos/CMakeCache.txt` — build dirs are
per-configuration (`build-macos-Debug`, `build-macos-MinSizeRel`), and the
unsuffixed one is a stale leftover. The authoritative record is the manifest:

```bash
python3 -m json.tool < FptnLib/slices/macos/fptn_native_lib.build-manifest.json
# "configuration": "MinSizeRel"   <- what you want
```

Second check — confirm the optimizer actually ran, by looking for symbols that
should have been inlined away:

```bash
F=FptnLib/slices/macos/fptn_native_lib.framework/Versions/1.0.0/fptn_native_lib
nm "$F" | grep -c HashAddress   # 0 at -Oz, non-zero at -O0
nm "$F" | grep -c Classify      # 1 — survives, it is the frame you profile
```

That asymmetry is also your expectation for Instruments: `Classify` appears as
a frame, but `HashAddress`, `HashCombine` and `ReadBe16` are folded into it and
will never show up separately. Combined with no `-g` on the C++ side, you get
function-level attribution and no line numbers. That is enough to answer "which
function dominates"; it is not enough to answer "which line inside it".

---

## 2. Read the counters before opening Instruments

Two ratios are emitted on the periodic `Split funnel` line
(`FptnVPNTunnel/PacketTunnelProvider.swift`). Both are free and both can
redirect the whole investigation.

```bash
log stream --process Fptn-macOS-Tunnel --info
# or after the fact:
log show --process Fptn-macOS-Tunnel --last 5m --info | grep 'Split funnel'
```

Info-level needs the `--info` flag or the lines are dropped.

Three things silence this line entirely, all of which look identical to "no
data":

- **Wrong process.** Xcode's console for the app scheme shows `Fptn-macOS`
  only — login and DNS via `api_client.cpp`. The tunnel is a separate process
  and never appears there.
- **Session shorter than 15 s.** `logFlowCounters()` runs only on the durable
  tick (`telemetryIntervalSeconds = 15`). Connect, push real traffic, and leave
  it up for a minute or more; a quick connect/disconnect logs nothing.
- **Mode is not `split`.** The `Split funnel` line is gated on
  `mode == "split"`, and the default is `.l3Tunnel`, in which no classifier
  runs at all. Confirm with the `Tunnel started (level=…, mode=…)` line.

### `mean_batch` — decides per-packet vs per-batch

Mean packets per `InputPackets()` call. There are four per-batch heap
allocations on ingress (`descriptors` in the adapter, `leases` in the bridge,
`to_stack` and `to_transport` in the split plane) at ~66 cycles each, so
~260 cycles per batch regardless of size.

| `mean_batch` | Per-packet share of that | Meaning |
|---|---|---|
| 1–4 | 65–260 cyc | Batch overhead dwarfs the classifier. Fix allocation first. |
| ~10 | ~26 cyc | Comparable to the classifier. Both worth looking at. |
| 30+ | ~9 cyc | Negligible. Focus per-packet. |

### `mru_would_hit` — decides whether a 1-entry MRU is worth building

Shadow measurement: how often a packet's 5-tuple matched the immediately
preceding packet's. Affects no routing; records only that two consecutive
packets shared a flow, never which flow.

**Do not use `hits` for this.** `table_hits` is per-packet against a table of
every live flow, so it sits near 100% whenever traffic flows and tells you
nothing about consecutive-tuple locality. A depth-1 cache is evicted by a
single interleaved packet from any other flow.

Useful identity for sanity-checking the funnel:

```
classified = table_hits + decisions + unclassifiable
```

Every `Classify()` call increments `classified` exactly once and exactly one of
the other three.

---

## 3. Instruments

The tunnel is a **separate process** (`Fptn-macOS-Tunnel`). Hitting Record on
the app profiles the wrong thing. Connect the VPN first, then attach to the
running extension from the target chooser — it is spawned by the NE session
manager, so it is attach-only, never launch.

| Template | Answers |
|---|---|
| **Time Profiler** | Which function dominates. Sampling has no per-event cost, which is exactly why it suits an 18 ns operation. Invert Call Tree, hide system libraries. |
| **Allocations** | The per-packet `IPPacketData` allocation at `websocket_batch.cpp:69` and the four per-batch vectors. Watch *transient* allocation count, not bytes. |
| **CPU Counters** | Real cycles and instructions retired. macOS only. Converts "8% of samples" into a cycle budget. |

`Product ▸ Profile` on the `Fptn-macOS` scheme is the entry point.

---

## 4. Interpreting the trace

The question is always *what fraction of the packet path is this?* — never the
absolute number alone. Reference points on the same machine:

| Operation | Cost |
|---|---|
| One 1400-byte `memcpy` | ~98 cyc (63 GB/s) |
| `malloc` + `free` | ~66 cyc |
| Full classifier path (`-Oz`) | ~95 cyc |
| `steady_clock::now()` | ~57 cyc |
| `unordered_map::find` (`-Oz`, hot key) | ~45 cyc |
| Uncontended `std::mutex` lock+unlock | ~19 cyc |
| `FiveTuple` comparison | ~6 cyc |

`CommitWebsocketBatch` does `IPPacketData storage(bytes, bytes + length)` —
a heap allocation plus a full payload copy — **per tunnelled packet**. That one
line costs roughly twice the entire classifier path, and it is one of several
copies on the egress path. Weigh any classifier optimization against it before
starting.

---

## Traps

**Your harness will lie to you.** A first pass at these numbers measured a
1400-byte `memcpy` at 1.1 cycles, because the optimizer had deleted it — 2.8 GB
copied in 0.5 ms, which is physically impossible and is what gave it away.
Every benchmark loop needs barriers on inputs and outputs:

```cpp
template <typename T> inline void escape(T& v) { asm volatile("" : "+r,m"(v) : : "memory"); }
inline void clobber() { asm volatile("" : : : "memory"); }
```

and a sanity check that the implied throughput is achievable.

**Core assignment.** Network Extension work frequently lands on E-cores, where
absolute times roughly double. Every number in this document is an M4 P-core at
~4.4 GHz. System Trace's thread-state view shows which core each sample ran on;
don't compare across core types without saying so.

**Summing component estimates double-counts.** `find()` already includes the
hash — measuring them separately and adding gives a number that is
substantially too high. Measure the composite path, not the parts.

**Debug builds.** Covered above, repeated here because it is the one that
actually happened.

---

## What is instrumented today

- `ClassifierCounters::mru_would_hit` — shadow only, no routing effect
  (`flow_classifier.cpp`, guarded by the same mutex as the rest of the counters)
- `FPTNSplitCounters.classifiedPackets` / `.mruWouldHit` — surfaced through
  `FPTNTunnelBridge`
- `mean_batch` and the MRU percentage — derived on the `Split funnel` log line

Swift signposts were removed: they were lifecycle-only (startup, teardown,
reconnect, path change) and answered no performance question. If interval
questions come back — gaps between NE reads, write-callback stalls, pipeline
starvation — reintroduce them at batch granularity, never per packet.
