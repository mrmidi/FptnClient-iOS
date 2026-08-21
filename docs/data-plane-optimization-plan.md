# Data plane optimization plan

Ranked strategy for the split-routing ingress path. Measurement method is in
[profiling-data-plane.md](profiling-data-plane.md); this document is what to do
with the numbers.

**Status: steps 1-3 implemented and committed 2026-08-21, confirmed on real
traffic.** Sections are in execution order.

---

## Measured traffic regimes

Taken from the `Split funnel` line on macOS during a speedtest plus ordinary
browsing. Batch size and tuple locality are properties of the traffic, not of
the compiler, so these hold regardless of build configuration.

| Phase | `mean_batch` | MRU hit rate |
|---|---|---|
| idle | 1.2–1.6 | 12–42% |
| light browsing | 2.4–3.9 | 83–87% |
| browsing (mail.ru, ya.ru) | 2.33 | 76.5% |
| **speedtest** | **12.8–16.0** | **90.6 / 91.7 / 92.6 / 93.8 / 95.6%** |

The loaded figure has now been confirmed five times across separate captures,
the last two against the live cache rather than the shadow counter.

**The workload is strongly bimodal, and the cumulative average (74.7%) is
misleading — it is the mean of two unrelated regimes.** Optimize for the loaded
one: it is the only regime where per-packet cost matters, and it is where tuple
locality is highest. A 1-entry MRU is worth ~90% under load and close to
nothing at idle, which is the right shape.

Split routing is confirmed working in the same capture: `direct:149`,
`drop:1`, `router_unknown=0`, and 1 603 of 4 065 packets to the stack while
browsing Russian domains.

---

## Corrected cost model

Apple M4 P-core at ~4.4 GHz, `-Oz` (the shipping config), measured as
composites with optimizer barriers. E-cores roughly double the absolute times;
ratios hold.

| Operation | Cost |
|---|---|
| **Full classifier hot path** (`now` + lock + `find` + `last_seen`) | **95 cyc** |
| ↳ `steady_clock::now()` | 57 cyc |
| ↳ `unordered_map::find` (hot key, incl. hash) | 45 cyc |
| ↳ uncontended `std::mutex` lock+unlock | 19 cyc |
| One 1400-byte `memcpy` | 98 cyc |
| `malloc` + `free` | 66 cyc |
| `FiveTuple` comparison (a 1-entry MRU probe) | 6 cyc |

Two corrections to the original analysis, both of which changed the ranking:

- **The path is 95 cycles, not ~350.** The higher figure matches a `-O0` build
  (measured: 571 cyc). Component estimates were also summed as if additive —
  `find()` already contains the hash, so "150 + 40" is really one 45-cycle
  operation.
- **There is no cross-core contention on this path.** `Classify` is called only
  from `SplitDataPlane::InputPackets`, driven by the packet-flow adapter's
  serially-reissued read. `LookupVerdict` runs once per flow at accept
  (`lwip_tcp.cpp:227`, `lwip_udp.cpp:191`), not per packet. The lock is
  uncontended; the cost is the atomic RMW, not cache-line bouncing.

The classifier remains a modest share of per-packet cost — one payload copy
alone costs more than the whole path.

---

## 1. Sweep-refreshed coarse clock — DONE, and it is not a speed win

Sample the clock **once per sweep** into a `std::uint32_t coarse_now_ms_`
member, plus once per new flow, and store that in the entry instead of a
`time_point`.

**Measured: no per-packet saving.** An A/B of the real `FlowClassifier` at
`-Oz` with the MRU forced to 0% — which isolates this change — gives 142 cyc
before and 146 cyc after, a ~2.7% *regression*. The isolated 57-cycle cost of
`steady_clock::now()` does not decompose out of the path: an out-of-order core
overlaps that latency with the surrounding work, so its marginal cost in
context is near zero.

This was the same error this document criticises the original analysis for —
treating a component measured in isolation as separable from the composite.
The correction is recorded rather than quietly edited out, because the mistake
is easy to repeat.

Kept anyway, for reasons that survive the measurement:

- `Entry` drops from **16 bytes to 8** (measured), halving the table's payload:
  64 KB → 32 KB at the 4096-entry cap.
- It makes the MRU's mandatory `last_seen` refresh a single 4-byte store, which
  is what makes hazard 1 in step 2 cheap enough to satisfy unconditionally.

Implementation notes worth keeping:

1. The clock re-anchors on the **new-flow path** as well as the sweep — once
   per flow, 0.55% of packets. Without it every entry created before the first
   sweep shares `coarse_now_ms_ == 0`, so a flow first seen at t=100s and one
   first seen at t=0 look equally idle and expire together.
2. **`uint32` milliseconds wrap at 49.7 days.** Unsigned subtraction stays
   correct for any interval shorter than that; the timeout is 120 s.
3. **Idle staleness.** The inline sweep is packet-count triggered, so with no
   traffic the clock freezes and nothing expires. `ExpireIdle(now)` re-anchors
   it and is still unwired — it needs a timer calling it.

Not related to dl/ul telemetry, which was considered as an alternative timing
source: that path already costs one `mach_continuous_time()` per second in
`updateTrafficRateTracking()` and never touches the classifier.

---

## 2. 1-entry MRU in front of the flow table — DONE, and it is the whole win

Gate satisfied five times independently: **90.6, 91.7, 92.6, 93.8, 95.6%**
under load, against 12–42% at idle. The last two are the live cache, not the
shadow counter, and the identity
`classified = table_hits + decisions + unclassifiable` was checked against each
capture.

A/B of the real classifier at `-Oz`, averaged over four runs:

| MRU rate | before | after | change |
|---|---|---|---|
| 100% | 116 cyc | 64 cyc | −45% |
| **92% (measured load)** | **122 cyc** | **72 cyc** | **−41%** |
| 74% (cumulative avg) | 132 cyc | 87 cyc | −34% |
| 0% (pathological) | 142 cyc | 146 cyc | +2.7% |

The win is skipping the hash and `find()`, not the clock. The worst case costs
~3% and requires every consecutive packet to belong to a different flow.

**Three hazards, all now covered by tests:**

1. **The MRU holds `Entry*`, not a copied verdict**, so the hit path refreshes
   `last_seen_ms`. A copied verdict would stop the refresh, the sweep would
   expire a *live* flow, and the re-decision on the next miss could flip a
   verdict mid-flow — the exact hazard the pinned-verdict design exists to
   prevent.
2. **Sweep accounting runs before the MRU check.** After it, a 92%-hit burst
   swallows most packets, stretching the sweep interval ~13× and stalling GC
   exactly under load. This was a real bug in the first draft.
3. **`mru_entry_` is cleared in every sweep and in `ExpireIdle`,** because
   `erase()` invalidates it. `std::unordered_map` keeps references stable
   across insert and rehash, so erase is the only case that matters.

Counter renamed `mru_would_hit` → `mru_hits` and kept: it is how a drop in
locality becomes visible. It is a subset of `table_hits`, so
`classified = table_hits + decisions + unclassifiable` still holds — asserted
in the tests.

---

## 3. Eliminate the per-batch allocations — DONE

Four heap allocations per batch across three layers, ~200-260 cycles per batch
regardless of size: ~19 cyc/packet at the measured loaded batch of ~14, which
is more than the classifier itself spends now that step 2 has landed.

| Layer | Was | Now |
|---|---|---|
| `FPTNApplePacketFlowAdapter.mm` | `std::vector<FPTNPacketDescriptor> descriptors(count)` | `_descriptors` ivar, `assign()` |
| `FPTNTunnelBridge.mm` | `std::vector<PacketLease> leases` | `_consumeLeases` ivar, `clear()` + `reserve()` |
| `split_data_plane.cpp` | three local vectors | three `scratch_*_` members |

Capacity survives `clear()`, so each settles at the high-water batch size and
then stops allocating entirely.

**Both hazards are handled explicitly:**

1. **The ownership contract.** `SplitDataPlane::InputPackets` has several early
   returns (two rollback paths, an invalid-packet path, a queue-full path), and
   on any of them the caller still owns every lease. A `PartitionGuard` RAII
   object clears all three scratch vectors on *every* exit, so no batch can
   observe leases left by the previous one — those point at storage the caller
   has since released. Clearing only on the success path would have left
   dangling `PacketLease::bytes` behind.
2. **Serial access.** Reuse is sound only because ingress never overlaps
   itself. `InputPackets` now takes an `atomic<bool> partition_in_progress_`;
   re-entry asserts in debug and returns `queue_full` in release, which is a
   safe degradation because the contract leaves the batch with the caller. The
   NE guarantees non-concurrency, not thread affinity, so this is checked
   rather than assumed.

**Confirmed safe, not yet confirmed faster.** A loaded capture on the shipping
build (`MinSizeRel`, 127k packets at `mean_batch=15.99`) reports
`reentries=0`, `dropped=0`, `router_unknown=0`, `lease_exhaustions=0` and
rollbacks at their pre-change ratio — so the scratch reuse and the serial-access
invariant hold under real traffic.

The ~19 cyc/packet remains arithmetic. Nothing in the funnel line can see
allocation cost, so confirming it needs either an A/B of the ingress path like
the one done for step 2, or the Allocations instrument on the macOS stand
showing transient allocations flat per batch instead of scaling with batch
count. **Open.**

---

## 4. The per-packet payload copy

The largest single cost on the path, and the least explored.

`CommitWebsocketBatch` (`websocket_batch.cpp:69`) does:

```cpp
fptn::common::network::IPPacketData storage(lease.bytes, lease.bytes + lease.length);
```

`IPPacketData` is a `std::vector<uint8_t>`, so this is a heap allocation plus a
full payload copy — **per tunnelled packet**, ~165 cycles. That single line
costs roughly twice the entire classifier path, and it is one of several copies
on the egress path (`SerializeBatchIPPacketOwned` performs another).

Placed last only because it is a design task, not a patch. Open questions:

- Can the `PacketLease` be carried through to serialization so the bytes are
  read once from NE-owned storage, rather than copied into an owning vector?
- Does the wire format permit scatter-gather, or does it require one contiguous
  buffer?
- Which copies are load-bearing for the server contract and which are
  incidental?

If the goal is throughput and CPU rather than shaving the classifier, this is
where the remaining effort belongs once 1–3 land.

---

## 5. Last, smallest

### Counters → relaxed atomics

**A prerequisite, not a win.** The mutex at `flow_classifier.cpp:182` guards
five things: `counters_`, `packets_since_sweep_`, `flows_`, and — inside
`DecideLocked` — `server_address_`, `tunnel_resolvers_`, `direct_resolvers_`.
Any plan to remove locking from the lookup must move the counters off the mutex
first, or the lock is still taken every packet for `++classified_packets`.

### `boost::concurrent_flat_map`

Only after the above, with expectations corrected:

- **Not lock-free.** Boost documents blocking operations executing
  sequentially; it is fine-grained internal locking.
- **No iterators at all.** `flows_.find(tuple)`, the `last_seen` mutation, and
  the `erase(it)` sweep loop must all be rewritten to `visit` / `erase_if`.
- The config vectors still need their own synchronisation.

Boost 1.90.0 is available and the header-only target is linked, so it would
compile — but this is a rewrite, not a typedef swap, for the smallest win here.

### `-Oz` → `-O2` for the hot translation units

The whole native lib is deliberately size-optimized
(`FptnLib/CMakeLists.txt:50`). Measured effect on this path: 95 → 82 cyc
overall (~14%), and `find()` 45 → 23 (~2×). Cheap to try, but a binary-size
tradeoff — scope it to the data plane sources rather than flipping the library.

---

## Deferred, not abandoned

| Item | Why it is open |
|---|---|
| Measure step 3 | Confirmed safe under load, never confirmed faster. Needs an ingress A/B or the Allocations instrument. |
| `ExpireIdle` has no caller | The inline sweep is packet-count triggered, so on a quiet link the coarse clock freezes and nothing expires. A timer calling `ExpireIdle(now)` re-anchors it. |
| `FPTN_BUILD_COMMIT` ignores a dirty tree | Stamped from `git rev-parse HEAD`, so a framework built with uncommitted changes is labelled with the previous commit — the one thing that line exists to prevent. Wants a `-dirty` marker. |
| `MIXED CONFIG` cries wolf | Compares config *names* (`Release` vs `MinSizeRel`) rather than optimisation intent, so it fires on every correctly built Release app. The case it should catch is already covered by `NOT REPRESENTATIVE`. |

---

## Explicitly not doing

| Item | Why not |
|---|---|
| Removing the mutex for "cache-line bouncing" | Ingress is single-threaded; `LookupVerdict` is per-flow. No contention exists to remove. |
| Optimizing the IPv4 tuple hash | 11.7 cyc. Not worth touching. IPv6 is 45 cyc — revisit only if v6 traffic proves significant. |
| Moving the GC sweep off-thread for jitter | Real but ~0.1% duty cycle. `ExpireIdle()` is already exposed for an external caller if it ever matters. |

---

## Method

Every claim here was produced against a `-Oz` build, measuring composite paths
rather than summing component estimates, with optimizer barriers on benchmark
inputs and outputs and a sanity check that implied throughput is physically
achievable. An early pass measured a 1400-byte `memcpy` at 1.1 cycles because
the optimizer had deleted it.

The traffic figures come from a Debug build, which is legitimate for batch size
and hit rate and would not be for anything measured in cycles.

Hold new claims to the same standard before they change this ranking.
