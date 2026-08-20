# Implementation Plan — Connect Hardening + Token UX

Driven by TestFlight feedback on builds 24/25 (Aug 10–18 2026) plus direct
Telegram reports. Two tracks: **H** kills the connect-path hangs, **U** rebuilds
token entry and makes connection state honest.

## 1. The reports

| # | Report | Track |
|---|--------|-------|
| R1 | Scan sticks at `53 / 54`, best already found (Poland-Premium, 1966 ms), spinner never resolves. Reporter notes it is **not** split-related. | H |
| R2 | "If you don't connect for a long time, the first connection almost always hangs on infinite reconnect in auto. Manual stop, second attempt connects." Reproduced on a second device. | H |
| R3 | Connecting from the system VPN toggle instead of the app button leaves the app showing **Connected**, 00:09:08 uptime, empty server card, 0.0 KB/s both ways. | U |
| R4 | "Token won't add. Pressing Login does nothing." Reinstall did not help. Single report, no other user has hit it. | U |

## 2. Findings

Everything below is read off the current tree, not inferred from the reports.

**F1 — The selection deadline is disarmed by the first success.**
`FptnShared/Sources/FptnServerSelection/SlidingWindowRace.swift:104`

```swift
if record.serverID == "deadline_timer_sentinel" {
    if winner != nil || !successfulAttempts.isEmpty { continue }
    deadlineTriggered = true
    group.cancelAll()
    break
}
```

`SelectionPolicy.production` sets `scanAllCandidates: true`, so `winner` stays
`nil` for the whole loop — but `successfulAttempts` becomes non-empty the moment
*one* server answers. From then on the 60 s `liveRaceDeadline` sentinel is
swallowed by `continue` and **never re-armed**. This is R1 exactly: a best
server was already found, so the deadline that should have ended the scan was
discarded.

**F2 — `overallSelectionDeadline` never bounds the race.**
`SelectionPolicy.swift:19` — `selectionDeadline` returns `liveRaceDeadline`
only. `SlidingWindowRace.run` opens with `_ = selectionPolicy.selectionDeadline`
and a comment claiming a soft-deadline timer handles it.
The 65 s `overallSelectionDeadline` *is* read — `AutoServerSelector.swift:52`
uses it to budget the cached-fallback bootstrap — but **no timer is ever armed
for it**, so it bounds the fallback and not the race. There is no hard backstop
inside the race itself.

**F3 — Termination depends on every probe returning.**
With the deadline gone, the loop can only exit via
`activeCount == 0 && index >= candidates.count`. A single probe that never
returns keeps `activeCount > 0` forever, the `TaskGroup` never drains,
`coordinator.connect()` never returns, and the UI spins with no timeout above
it. Nothing on this path touches split routing — R1's reporter is right.

**F4 — Per-candidate deadlines are advisory.**
`BootstrapPolicy.production` = `stageTimeout: 5s`, `candidateDeadline: 8s`.
`Packages/FptnNativeBootstrap/.../NativeServerBootstrapper.swift:29-31` converts
them to `timeoutSeconds` and hands them to the native `ApiClient`. That is the
*only* enforcement. There is no Swift-side wall clock, so if a native call fails
to return, the 8 s budget is enforced by nobody and the slot is held forever.

F1–F4 also explain R2: after a long idle, DNS and TCP are cold and a wedged
probe is far more likely; the second attempt succeeds because the health store
and latency cache reorder candidates so a known-good server is probed early.

**F5 — Auto-login failures are silent.**
`LoginViewModel.loginIfValidPastedToken` funnels every error into
`logger.debug("Ignoring pasted token candidate:")` and never touches
`errorMessage`. It also stamps `lastAutoLoginCandidate` *before* attempting, so
the same paste is never auto-retried. A paste that fails to decode produces no
user-visible signal at all.

**F6 — Token sanitization is already thorough; the gap is reporting.**
`LoginViewModel.decodeToken` already strips `fptnb://`, `fptnb:`, `fptn://`,
`fptn:` (in the correct order), collapses whitespace, normalizes URL-safe base64
(`-`→`+`, `_`→`/`), re-pads, and strips backticks. It distinguishes `fptnb:`
(brotli) from `fptn:` (plain) and has typed errors for empty / bad base64 /
brotli failure / JSON failure. **Do not rebuild this.** What is missing is that
those typed errors only reach the user on the manual `login()` path.

**F7 — "Login does nothing" has two invisible mechanisms.**
`isLoginButtonEnabled = !token.isEmpty` — an empty or failed paste leaves a dead
button with no explanation, which matches R4's wording precisely.
Separately, `TokenService.saveTokenData` writes UserDefaults + iCloud Keychain +
`NSUbiquitousKeyValueStore` synchronously; `KeychainHelper.savePassword`'s result
is discarded and there is no timeout. A blocked iCloud Keychain write would hang
`login()` with no error and no busy indicator. Both are consistent with R4; only
instrumentation will tell us which.

**F8 — An adopted tunnel leaves the UI half-populated.**
`connection.selectedServer` is set only by the in-app connect path
(`VPNService.swift:279`/`339`); `adoptSystemManager()` restores the manager and
status but never the server identity, so the card renders empty. Uptime is
correct because it comes from `tunnelConnection.connectedDate`.
Note the 0.0 KB/s is **not** explained by this: `startTrafficPollingIfNeeded()`
runs on `.connected` regardless of origin (`VPNService.swift:414`). That needs a
repro before it gets a fix.

## 3. Track H — hardening

> **Status 2026-08-20:** H1, H2 and H5 are **implemented and green**
> (`RaceDeadlineTests`, 6 cases; full FptnShared suite 50/50). H3 and H4 remain
> open. Implementation notes are inline below.

**H1 — Re-arm the deadline instead of swallowing it.** ✅ done
When the sentinel fires with successes in hand, the race should *finish with the
best result so far*, not discard its only timer. Replace the `continue` with a
graceful close: `group.cancelAll()`, break, and let the existing
`winner = successfulAttempts.min(by:)` fallback pick the winner.

*As built:* when the soft deadline fires with successes banked, termination is
`.winner` — not `.selectionDeadline` as this plan originally said. `.winner` is
the more honest answer (the run did produce one); the fact that the race was cut
short is recorded separately in `RaceStatistics.softDeadlineTriggered`. With no
successes the termination is `.selectionDeadline`, which is what
`AutoServerSelector` needs to trigger its cached-candidate fallback.

**H2 — Enforce `overallSelectionDeadline` as a hard backstop.** ✅ done
Add a second sentinel at `overallSelectionDeadline` that is *unconditional* —
it cancels and returns whatever exists, including nothing. H1 is the soft stop
(finish early with a good answer), H2 is the guarantee that `run()` always
returns. Delete the misleading `_ = selectionPolicy.selectionDeadline` line.

*Implementation trap, worth remembering:* the first cut clamped the backstop with
`max(overallSelectionDeadline, liveRaceDeadline)`, reasoning that a backstop
earlier than the soft deadline was nonsense. It silently disabled H2 in exactly
the configuration where a backstop matters most, and it was `RaceDeadlineTests`
that caught it — both hard-deadline cases hung. Both timers are now armed as
configured; whichever fires first wins. Termination gains a distinct
`.overallDeadline` case, and `RaceTermination.isDeadline` covers both so the
cached fallback still runs.

**H3 — Wall-clock guard per probe.** ⬜ open
Wrap each `bootstrapper.bootstrap(...)` in a Swift-side timeout of
`policy.candidateDeadline` + small grace, so a wedged native call cannot hold a
slot. This makes F4's budget real independent of native behaviour, and keeps the
sliding window sliding.

**H4 — A ceiling on the whole connect call.** ⬜ open
Even with H1–H3, `VPNService.performConnect` should never be able to await
forever. Put an explicit budget around `coordinator.connect(request)` and drive
it to a `.failed` with a distinct reason on expiry. This is the last line of
defence: no future bug in selection should be able to produce an infinite
spinner again.

**H5 — Make the outcome legible.** ✅ done
Log `RaceTermination` plus started/completed/neverStarted counts. Today a stuck
scan produces no log line saying *why* it stopped — which is why R1 needed a
screenshot to diagnose.

*As built:* a new `SelectionOutcomeSummary` is emitted once per run through an
`onOutcome` callback that mirrors the existing `onProgress` plumbing
(`SelectionRequest` → `AutoConnectionRequest` → coordinator). `VPNService` logs
`summary.logLine` at info on success and warning on failure. FptnShared has no
logging dependency by design, so the summary travels out rather than the package
logging for itself. The line carries server *names* only — no hosts, no
credentials.

**Tests.** ✅ `Tests/FptnServerSelectionTests/RaceDeadlineTests.swift`, 6 cases:
the R1 shape (one success + one hang), all-probes-hang on each deadline, the
hard backstop in isolation, a healthy race tripping neither timer, and a guard
that timer sentinels never leak into `attempts` (they would otherwise become
bogus server-health observations). Each asserts bounded wall-clock time, so a
regression hangs the suite rather than passing quietly.

## 4. Track U — token UX and connection honesty

**U1 — Paste-first token entry.** ✅ done (2026-08-20)
Replace the primary text field + Login button with a single **Paste** action
that reads the clipboard, sanitizes, decodes, and logs in — with an info card
above it explaining where the token comes from.

*As built, and the earlier caveat withdrawn:* this plan argued for keeping a
collapsed manual field, because a denied paste prompt would be a dead end. The
text field is now gone entirely — the keyboard could never enter a token anyway,
so it only ever occupied the screen and made the field look like something you
were supposed to type into.

The dead-end risk was real, though, and is handled at the source instead:
`TokenPasteboard` checks `UIPasteboard.hasStrings` (a detection API that does
*not* raise the paste prompt) before reading, so "clipboard is empty" and "you
tapped Don't Allow" become two different messages. Without that split, the one
screen a user cannot get past would have told them to go copy a token they had
already copied.

`LoginViewModel` lost `token`, `isLoginButtonEnabled`,
`shouldAutoLoginAfterTokenChange` and `loginIfValidPastedToken` along with the
field; errors render inline on the screen rather than in an alert, so the advice
stays readable while the user switches to Telegram to re-copy.

**U2 — Update token without logging out.** ✅ done (2026-08-20)
A "Update token" action in Settings that reads the clipboard, validates, and
replaces the stored token in place — preserving connection state and not
dropping the user back to the login screen. This is the highest-value item in
the track: it is the fix for every "my token expired" support thread.

*As built:* **Paste New Token** sits in the Account section above Clear Keychain
and Log Out, with the result reported inline on the row the user just tapped
rather than in an alert. Success shows the new server count; failure shows the
specific U3 message. It deliberately does not disconnect an active tunnel —
servers and credentials are swapped underneath and apply on the next connect,
which the section footer states.

Prerequisite done along the way: `TokenDecoder` (`FptnVPN/Services/`) was
extracted from `LoginViewModel`, so login and the refresh share one parser. Two
copies of that sanitisation would have drifted, and the sanitisation is the part
that makes real-world tokens work.

**U3 — Surface the errors that already exist.** ✅ done (2026-08-20)
`decodeToken`'s typed errors (F6) are good; route them to the UI on *every*
path, including auto-login (F5). Map each to a specific hint:

| Condition | Message |
|---|---|
| Clipboard empty | "Clipboard is empty — copy the token from @fptn_bot first" |
| No `fptn:`/`fptnb:` prefix | "That doesn't look like an FPTN token" |
| `.invalidBase64` | "Token looks truncated — copy the whole message" |
| `.brotliFailed` | "Token format not recognized — request a fresh one" |
| `.jsonDecodeFailed` | "Token is damaged — request a fresh one from @fptn_bot" |
| Decoded, `servers.isEmpty` | "Token has no servers — contact support" |

Also stop stamping `lastAutoLoginCandidate` before the attempt, so a transient
failure does not permanently suppress retry of the same paste.

*As built:* the table above is now `TokenParseError` in `TokenDecoder`, localized
en/ru, and surfaced on **both** paths — `loginIfValidPastedToken` sets
`errorMessage` instead of swallowing the failure into a debug log (F5), and
Settings shows it inline. `lastAutoLoginCandidate` is stamped only on success.
The `noServers` case is enforced in the decoder itself, so a token that parses
but carries nothing to connect to fails at paste time rather than at connect
time. Covered by `FptnVPNTests/TokenDecoderTests.swift` (15 cases, green).

**U4 — Make the login action observable.** (targets R4)
Add a busy state, a timeout around `saveTokenData`, and check
`KeychainHelper.savePassword`'s result instead of discarding it. A dead button
should say *why* it is dead. Log each stage at info so the next R4 report is
diagnosable from the Logs screen rather than needing a reinstall.

**U6 — Token freshness.** ✅ Settings surface done (2026-08-20)
Record `tokenUpdatedAt` whenever a token is stored (`TokenService.saveTokenData`
already writes UserDefaults + KVS, so this is a one-line addition) and surface
the age in Settings next to U2's "Update token" action.

*As built:* the timestamp is stamped in `saveTokenData`, so every path that
persists a token — manual login, paste auto-login, and any future in-place
refresh — updates it without having to remember to. It is mirrored to iCloud KVS
and carried across on adoption (`getTokenData`'s cloud path and
`handleCloudChange`), so a second device reports the token's real age instead of
"just now". A token saved before this existed reads as **Unknown** and is
explicitly *not* treated as stale — otherwise every existing install would be
flagged on first launch after the update. The Account section shows the relative
age, the absolute date, and an amber refresh hint once past the threshold.

`SettingsViewModel.tokenStalenessThreshold` is the single constant holding the
7-day guess (Q3). No alert and no launch-time prompt was built — Settings only,
per the decision to keep this passive for now.

On *how* to prompt, a caveat worth weighing before building it: age alone is a
weak signal, and a launch-time modal is the most intrusive surface available for
a maybe-problem. A user whose token still works would be nagged weekly for
nothing. The app already has far stronger evidence available —
`SelectionPolicy.authenticationQuorum` (2) yields `.authenticationRejected`, and
`.allCandidatesFailed` carries a per-kind failure breakdown. Those mean the
token *is* bad, not that it might be.

Recommended escalation:

| Signal | Surface |
|---|---|
| Always | Token age shown in Settings |
| Age > threshold | Passive banner on the home screen, dismissible |
| `.authenticationRejected` quorum reached | Modal: "Your token is no longer accepted — update it" |
| `.allCandidatesFailed`, all network-class | Banner suggesting refresh, since a stale server list looks identical |

The freshness question is not cosmetic: the token carries the **server list**, so
a stale one races against hosts that may no longer exist — dead hosts are
exactly the slow/hanging probes that Track H is bounding. U6 and H1–H4 attack
the same symptom from opposite ends.

**U5 — Honest card for adopted tunnels.** (targets R3)
Persist the last connected server and restore it in `adoptSystemManager()`, or
have the provider report its current server back over
`sendProviderMessage`. Until it is known, render "Connected (started outside the
app)" rather than an empty card. Separately, reproduce the 0.0 KB/s (F8) —
connect from the Settings toggle, then watch whether the traffic poll gets a
reply; do not fix blind.

## 5. Sequencing

> **Progress 2026-08-20:** H1, H2, H5 done (step 1). U1, U2, U3, U6 done — U6 as
> the Settings surface only, no alert. Remaining: H3, H4 (step 2), and U4/U5
> (step 5), both of which need a repro first.

1. **H1 + H2 + H5** — small, contained in `SlidingWindowRace`, fixes R1 and most
   of R2. Ship first.
2. **H3 + H4** — the defence in depth; touches the app and the bootstrap package.
3. **U2 + U3** — highest support-load relief, no redesign required.
4. **U1** — the screen redesign, once U3's error vocabulary exists.
5. **U4 + U5** — needs a repro first; U5's 0.0 KB/s half is investigation, not
   a known fix.

## 6. Open questions

- **Q1** — Should the soft deadline finish the scan (H1) or extend once when
  probes are still making progress? Finishing is simpler and matches what R1's
  user wanted; extending is friendlier on very slow networks. Recommend
  finishing.
- **Q2** — `scanAllCandidates: true` means a full 54-server scan on every auto
  connect. With H1/H2 that becomes bounded, but is scanning all of them what we
  want, or should a good-enough winner short-circuit? This is a product call.
- **Q3** — What is the right staleness threshold for U6? One week is a guess;
  the answer depends on how often `@fptn_bot` rotates tokens and how often the
  server list actually changes. Needs your call, not a default.
- **Q4** — R4 is one report. U4 is instrumentation, not a fix; we should not
  guess at a mechanism until a second report or a log confirms F7's branch.
