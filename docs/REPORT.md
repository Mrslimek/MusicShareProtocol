# Report — Music Share MVP peer experiment

Status document for the current verification stage. Companion docs:
[`TEST_PLAN.md`](TEST_PLAN.md) (protocol), [`ARCHITECTURE.md`](ARCHITECTURE.md)
(design), [`../protocol/PROTOCOL.md`](../protocol/PROTOCOL.md) (contract).

## Summary

A macOS and an Android app implement the v1 contract (mDNS discovery, WebSocket +
JSON control messages, keepalive, backoff reconnect, per-device `seq` state) to
measure real-world P2P behavior on one LAN: discovery latency, connection
establishment, failure detection, and state-sync anomalies.

**All numbers in this report were produced on a single machine** — two headless
macOS instances plus an Android API 37 emulator (whose mDNS happened to bridge to
the host network in both directions on this development host; environment-specific,
see below). They are real measurements of the two implementations, but they are
**not** measurements of a physical two-device Wi-Fi deployment. Everything that
still requires real devices is marked explicitly.

The experiment also found ten defects (three of them protocol-contract
violations users would have hit within the first minute of flying the app); all
ten are fixed and independently re-verified, and are listed in
[Defects found & fixed](#defects-found--fixed).

## Environment

- Development/test host: macOS 27.0.1 (arm64), Xcode 27.1.
- Android tooling: Android SDK; **API 37 arm64 emulator** (`Medium_Phone_API_37.0`),
  Gradle 8.14.2 / AGP 8.13.0 / Kotlin 2.1.20, minSdk 26, targetSdk 35.
- macOS app: SwiftPM package, Swift 5 mode, Starscream 4.0.8; headless CLI mode
  (`--headless --name --id --port --connect --log-dir`) for scripted runs.
- Android app: Kotlin, sole third-party dep Java-WebSocket 1.6.0; JSONL logs via
  `logcat` tag `MShare`.
- **Emulator mDNS is environment-specific:** on this host, multicast bridged in
  both directions (the host's Bonjour found the app's `_musicshare._tcp` service
  and the app's NSD found the host's, both measured). Do **not** rely on this
  elsewhere. Two further host quirks measured here: **discovery bridging does not
  imply TCP reachability** — every direct dial from the host to the emulator's
  virtual NIC (`Android_*.local:port`) timed out at 5-6 s (SYN blackholed), so
  `adb forward` + manual connect is the working mac→app path on this host; and the
  emulator's NSD re-browse sometimes delivers no re-found for live services for
  ~20 s while a late `onServiceLost` still arrives (see defect 6). App→mac TCP
  (to the host's LAN address) worked directly throughout.
- **No physical Android device and no second physical macOS machine** were
  available; the two-device Wi-Fi matrix remains unexecuted.

## Method (what was and was not done)

Performed on the single machine:

- **macOS two-instance loopback** — headless `MusicShareMVP` instances with distinct
  ids/ports/log dirs (`macos/scripts/smoke_test.sh`), exercising announce,
  discovery, tie-break election, handshake, state exchange, keepalive, SIGSTOP
  freeze detection and reconnect.
- **macOS ↔ Android emulator, both directions, every transport path** — the app
  discovered and dialed a headless mac peer over bridged mDNS; the app was dialed
  over `adb forward`; manual-connect dials exercised in both directions. Includes
  a three-node mesh (two mac instances + the app) with tie-break observed.
- **Failure injection** — SIGSTOP/SIGCONT freeze of a peer (process state verified
  as `T` before each test), SIGTERM graceful-shutdown runs, dialing dead ports and
  a frozen peer, same-id relaunch, kill-without-goodbye.
- **Permission experiments** — bare macOS binary vs bundled app; Android NSD with
  and without runtime grants on API 37.
- **Code/protocol consistency review** — both implementations checked against
  contract §2–§7 (TXT keys, tie-break, handshake deadlines, close codes, message
  envelope, receiver rules, event vocabulary), plus static grep-proof of every
  defect fix before live re-verification.
- **Defect-fix loop** — every defect found during measurement was fixed by coder
  subagents and independently re-verified by live runs (evidence in
  [Defects found & fixed](#defects-found--fixed)).

Not performed: every test in `TEST_PLAN.md` §3–§4 requiring two physical devices on
a real Wi-Fi network / real AP; first-launch permission UX on real devices.

## Results — the ten questions

All figures measured on the single machine described above; **where a cell says
"physical device" the question is not answerable in this environment** and the
cell records only what could be learned.

| # | Question | Result (measured, single-machine) | Method | Notes |
|---|---|---|---|---|
| 1 | Discovery latency after launch | macOS: 1.47–1.95 s app-start→first peer_found (loopback smoke); 38–44 ms discovery-start→peer_found. Android: **variable** — ~1 s in good runs, ~46 s in one run where the first NSD browse missed everything (a later browse found peers), ~2 s re-discovery of a relaunched same-id peer. | `elapsedDiscoveryMs` in both logs; repeated cold starts | NsdManager first-browse behavior is the dominant variable — real-device figures still required. |
| 2 | Discovery stability (no phantom `gone`) | Pre-fix: healthy peer killed by a 60 s expiry bug (see defect 1). Post-fix: 6.4 min soak crossing six 60 s thresholds with zero false `peer_lost`. Then a subtler churn, measured in two shapes: (a) each 45 s re-browse cycle emitted a spurious `service_removed` right at browse start (API 37 NSD teardown artifact) — the round-3 2.5 s debounce fixed this fast shape; (b) the deeper shape on this image: after a cycle tick the new browse delivers **no re-found for ~20 s** and a late removal arrives that no event-keyed debounce can survive — measured `peer_lost` + death of a healthy socket at 22:34:28.791/851 with a ~2 s blackout per cycle, and again 22:41:34. Fix in acceptance: a 30 s quiet period after each browse start (removals ignored inside it; the 60 s expiry remains the backstop — it correctly fired `peer_lost expired_60s` for a genuinely dead peer at 22:41:33). Final soak below the table. | ≥1 h idle soak; soak memos; cycle-tick forensics | Pre-D4 phantom *advertisements* persisted 15+ min (zombie-held registrations, fixed). Physical-device soak on a real AP still required. |
| 3 | Tie-break elects exactly one dialer | Verified in every mac↔app run: the smaller device id always dialed, the other side stayed callee; in the three-node mesh each pair had exactly one dialer. Under the post-fix flap, one window showed two connect_oks 52 ms apart (both paired with a 4003 supersede) — covered by the no-double-dial guard. | Both logs compared step-by-step; `disconnect superseded` lines | Election itself is deterministic and correct; the flap created the duplicate-dial case worth the guard. |
| 4 | Connection establishment time | Loopback: 7–16 ms dial→connect_ok. app→mac: 96 ms (first), 532 ms (post-fix build). mac→app via `adb forward`: 31 ms. Dial into a SIGSTOP-frozen peer **parked indefinitely pre-HTTP-101** (elapsedConnMs 6537 ms, completed only on SIGCONT) — fixed by a 5 s dial timeout (defect 6). | `elapsedConnMs`, `connect_attempt`→`connect_ok` | Cross numbers include emulator/forward overhead; Wi-Fi figures need real devices. |
| 5 | Handshake timeout = 5 s → 4002, no death claim | macOS caller against dead/stale ports: close at 5000/5003 ms with `connect_failed (connect timeout)` and no "remote down" claim. Android hello-level path (4002 at 5 s) verified by code path + the frozen-peer test exercising its dial timeout; the explicit 4002 staging run on Android was not separately performed. | WS-stub staging (TEST_PLAN §5), mac-side; static check android-side | Mac-side is fully evidenced; android-side 4002 remains a code-inspection result. |
| 6 | Application-level RTT on healthy LAN | Loopback: 0.28–0.42 ms. mac↔app: local send→receive delta 1–19 ms (typical 1–14; one 104 ms outlier in an early build). **Cross-clock `pong.ts−ping.ts` is meaningless across devices**: Android's clock lags the host 0.845 s (measured drift −361→−849 ms over ~2 h, ~67 ppm). | `rttMs`/`localDeltaMs` in both logs | Field semantics differ: Android puts the *local* delta in `rttMs`, mac puts the *raw cross-clock* value there — both log both numbers; contract §4 permits this but the inconsistency is worth documenting (see defect 9). |
| 7 | Silent-peer detection latency ≤10 s | macOS: freeze detected 15.8–16.6 s after the last pong (5 s ping + 10 s pong budget + tick). Android pre-fix: app-layer watchdog **never fired** (defect 2); the library's LostTCPPinger then closed 1006 at ~22.4 s. Android final build (independent runs): the watchdog **intent** fires at ~11 s after the loss (22:41:30 vs freeze 22:41:19 — matches the ping+10 s budget); pre-round-4 the close itself re-fired every tick and only the library teardown (1006) delivered the `keepalive_timeout` event, at +20.6–23.4 s — fixed in round 4 (defect 10): single intent event at +10.99 s with the app's own hard close 6 ms later. | SIGSTOP with `ps -o stat` `T`-state verification; last-pong→event deltas | Detection speed is currently event-limited by the close path, not by the deadline logic. |
| 8 | Reconnect schedule / stop at `gone` / resume | Ladder observed: attempts at 1.5/2.8/5.7/14.4 s (delays ±20 % jitter), escalating to the ~21-26 s cap during a 69 s freeze (each frozen dial bounded at 5 s by the dial timeout — defect 5 fix working). **Recovery leg**: SIGCONT 22:42:28 → next ladder dial 22:42:48.886 → connect_ok **96 ms** 22:42:48.982 → state exchange both ways → rtt resumed 3-15 ms. **Stop at gone**: after the goodbye fix (defect 3), zero `reconnect_scheduled` after `goodbye app_shutdown` — re-verified on the final build with the app as caller (22:43:14, again zero). **Resume**: same-id relaunch rediscovered ~2 s, connect_ok ~240 ms after `peer_found`. | gap analysis of `reconnect_scheduled`; freeze+CONT runs; goodbye runs; relaunch runs | One design consequence: an intervening spurious `peer_lost` re-creates the peer entry, so the reconnect skips `state_conflict` (seq memory reset with the entry) — see row 9. |
| 9 | State sync correctness + conflict evidence | Post-handshake snapshots exchanged in both directions in every pairing; `state_conflict` captured on **both** sides when the sender restarted (seq reset → arriving seq ≤ last seen), exactly as the contract wants. Contract note: seq resets on app restart by design, so reconnect always emits one conflict — intended noise. Implementation note (measured): if the peer entry is re-created in between (e.g. by a spurious `peer_lost` + re-find), the seq memory resets with it and the conflict is skipped — the anomaly machinery is per peer-entry, not per device id. | `state_sent`/`state_recv`/`state_conflict` lines | Loopback+emulator cover the logic path fully; multi-peer conflict behavior needs >2 real devices. |
| 10 | Permission-model cost on first launch | macOS: the bare binary announces/browses **silently failing** with no prompt — the prompt only surfaces for the bundled app (`scripts/make-app.sh`); recovery after denial is a manual Settings toggle. Android: on this API 37 image `ACCESS_LOCAL_NETWORK` is enforced **at runtime** (SecurityException) despite targetSdk 35, requiring grants for both it and Nearby devices; without grants NSD fails silently-adjacent (app logs `permission_denied` and offers manual connect). | denial runs + first-launch logs + `pm grant` re-grants | First-launch UX on real devices (prompt text/timing) unobserved — emulator is not permission-truthful for UX. |

<!-- FINAL-ACCEPTANCE: post-round-3b soak (rows 2/7) gets pasted above this marker -->

Final acceptance note (all on the build with the round-3 debounce, independent runs):

- **Freeze** (FreezeMac SIGSTOP 22:41:19, `T` verified): watchdog intent
  `connect_failed keepalive_timeout` at +11.1 s; teardown only via library
  LostTCPPinger (1006) at +20.6 s with 4-5 spurious re-fires and a `tick`
  exception in between (defect 10). Second run (CrossMac, 22:38:00): event at
  +23.4 s, 5 re-fires. **Recovery**: SIGCONT 22:42:28 → dial 22:42:48.886 →
  connect_ok 96 ms → state both ways → rtt 3-15 ms. **Goodbye**: TERM 22:43:15 →
  `disconnect goodbye reason=app_shutdown` → `peer_lost goodbye_received` →
  onClose 1000 → zero reconnect_scheduled; mac exited ≤1 s.
- **Zero-churn soak after the round-3 fixes: PASS (aggregator-independent).** The union
  build (30 s browse quiet period + healthy-socket guard; APK 22:41, installed 22:49:41,
  app pid 11838) ran 22:49:43→23:08:24 with **zero** `connect_failed`/`disconnect`/
  `keepalive_timeout`/`error` events across ~12 re-browse cycles. A booked 124.1 s window
  (23:06:20→23:08:24) covered 2 full 45.4 s cycles with **0 churn events**, 48 `pong_recv`
  (24 per connected peer, 5.0 s median cadence, max gap 6.0 s), and the quiet-period debug
  line firing twice per cycle for every discovered peer. The layered removal path was
  witnessed at 22:51:53: a late spurious-removal batch arriving outside the quiet window was
  blocked by the healthy-socket guard for both CONNECTED peers (`dns_hint_ignored:
  socket_healthy`), while the socket-less peer produced one clean `peer_lost
  service_removed` (single detail — the doubled form is gone from this build) and was
  re-found ("reappeared") the next cycle. All the earlier churn (22 keepalive re-fires,
  tick exceptions, doubled details) belongs to the replaced pre-fix app process and does
  not count against this build; the coder's own acceptance run (164 s, 4 cycles, 30 pongs,
  zero churn) corroborates.
- **End state (all ten defects closed).** The two defects found after that note — the
  Android keepalive close path (defect 10) and the macOS watchdog reject-loop (defect 11) —
  were fixed in rounds 4-5 and re-verified: freeze detection is now a single intent event
  at +10.99 s with the app's own disconnect 6 ms later, a silent app replacement no longer
  triggers the mac reject-loop, and the final mesh (app + three mac peers) ran 7 m 45 s
  with zero error events and a booked 109 s capstone window at zero churn.

Loopback and emulator figures above are single-machine numbers; every cell that
still needs physical Wi-Fi devices says so explicitly.

## First physical-device session (2026-10-31)

Mac app on the development MacBook Air + the Android app on a real phone, same
Wi-Fi. Mac-side numbers below are from the mac's own JSONL log (measured); the
phone-side observations are user-reported and marked as such.

- **Discovery on real Wi-Fi**: phone found **1.9 s** after mac app launch;
  tie-break correct (mac `07f0…` < phone `ee2f…` → mac dialed
  `ws://Android_….local.:45519`); first handshake 280 ms.
- **Keepalive on real Wi-Fi**: 96 ping/pong exchanges over 8+ min, connection
  continuously stable; RTT (mac's cross-clock `rttMs`) 118-331 ms, median 166 ms
  — an order of magnitude above the single-machine 1-16 ms, as expected for
  phone Wi-Fi power-save. Clean local RTT needs the phone log (defect 9
  semantics).
- **Doze kills the socket (the session's headline finding).** Two early
  disconnects (phone closed TCP, seq reset after rehandshake) were caused by the
  phone's screen turning off: Android battery optimization/doze tore the socket
  down. With battery optimizations disabled for the app, minimizing it no longer
  disconnects (user-verified). Integration consequence: a mobile peer needs a
  foreground service / disabled optimizations to hold the connection while
  backgrounded, and the 5 s ping budget must be revisited for that deployment.
- **Scenarios verified on real hardware** (mac-side log or user report):
  quit-mac-app → goodbye → phone stopped at gone; quit-phone-app → disconnect
  (expected); Wi-Fi off → disconnect, Wi-Fi on → rediscovery and reconnect
  (user-verified); laptop lid close → connection ends (accepted semantics);
  silent screen-off death → detected and reconnected after recovery.
- **Not yet testable**: the Android share-sheet log export failed on the phone
  (nothing shared) — phone-side log analysis is pending; clamshell mode untested
  (user assessment: powered lid-closed operation should behave like lid-open).

## Defects found & fixed

Each was found by measurement, fixed by a coder subagent, and independently
re-verified — mostly with live reproductions of the original failure.

1. **Android 60 s expiry killed healthy peers (P0).** The peer's `lastSeenAt` was
   written once at `peer_found` and never refreshed, so expiry fired exactly 60 s
   after discovery **while the socket was live** — last pong 16:45:00.799, close
   with `goodbye reason=expired_60s` at 16:45:02.816 (a goodbye reason that also
   violated the contract). Fix: refresh on every valid message, exclude connected
   peers from expiry, no goodbye on expiry, add the 45 s re-browse cycle. Verified:
   6.4 min continuous connection (69 pongs) across six 60 s thresholds.
2. **Android keepalive watchdog structurally dead (P0).** The timeout compared
   against pings *sent* (refreshed every ≤6 s), so the 10 s condition could never
   hold; app-layer detection never fired, and only Java-WebSocket's internal
   LostTCPPinger (1006, ~22.4 s) caught a frozen peer. Fix: key the watchdog on
   `lastPongAt`. Verified: 11.0 s detection in a clean SIGSTOP freeze.
3. **Reconnect after goodbye (contract violation, P0).** `reconnect_scheduled in
   1555ms` was logged 160 ms after receiving `goodbye app_shutdown`; §5 says stop
   at gone. Fix: mark gone *before* close processing. Verified: zero
   reconnect_scheduled after goodbye on the fixed build (retested on the final
   round-3 build too, see acceptance note).
4. **macOS SIGTERM zombie + publish "Code=0" (P0+P1).** After a graceful SIGTERM
   the process ran its shutdown log lines but never exited: `shutdown()` blocked on
   the main queue before the unregister hop ran, so the mDNS registration was never
   released and `exit(0)` was unreachable. Two consequences: a same-id relaunch
   failed to publish (reported masked as `Code=0` because the handler read the
   wrong NSNetServices error dictionary keys — singular vs plural), and zombies
   kept advertising 15+ min. Fix: off-main-queue shutdown + correct key extraction.
   Verified: exit ≤3 s after TERM; 5/5 same-id republish cycles; forced conflict
   now surfaces as `Code=-72001` ("name already registered").
5. **Dial into a frozen peer parks pre-HTTP-101 (P2).** TCP established into the
   frozen kernel backlog, no WS upgrade, no hello sent, and the 5 s app handshake
   timer (armed at `onOpen`) never armed — the dial completed only when the peer
   unfroze (elapsedConnMs 6537 ms). Fix: `connectBlocking(5 s)` + stale-generation
   guards. Verified: dials now fail at ~5 s and escalate the reconnect ladder.
6. **45 s rediscovery cycle flap (P2)** — see row 2: each re-browse tick produced
   a spurious `service_removed` (the generation-based suppression failed because on
   this API 37 image the removal arrives on the *current* generation), closing a
   healthy connection and re-dialing every ~45.4 s. Round 3 added a 2.5 s
   gone-grace debounce + heal-on-refound + no double dial; independent acceptance
   showed it fixes only the FAST flap (lost→found 3 ms apart). The deeper shape —
   a late (~20 s post-browse-start) removal with **no re-found in that
   generation** — still killed healthy sockets every cycle (22:34:28.791/851,
   22:41:34.446). Round-3b supersedes the debounce with a **30 s quiet period**
   after each browse start during which removals are ignored; real departures are
   still caught by the 60 s expiry (verified: `peer_lost expired_60s` fired for a
   genuinely dead peer at 22:41:33). Acceptance at the time of writing: in
   progress; final soak below the table.
7. **Close-reason string hygiene (P3).** Android's close frame leaked the internal
   joiner `service_removed:service_removed` onto the wire (mac logged it as the
   1000 reason); wired reasons are now cleaned to the contract values (verified:
   `onClose code=1000 reason=service_removed`). The same doubling survived in the
   `peer_lost` **event** detail until the round-3b fix (in acceptance).
8. **Phantom advertisements ≥15 min (environment artifact, root-caused).** mDNS
   responders kept announcing deregistered services — traced to zombies never
   releasing their registration (defect 4). After the zombie fix unregister
   actually executes; residual responder/NSD caching can still echo for a while on
   this host, so the 60 s expiry + gone-grace design stays the defense.
9. **Cross-clock RTT field semantics.** Android's `rttMs` = local send→receive
   delta; mac's = raw `pong.ts−ping.ts` (≈ −840 ms here due to clock drift). Both
   log both numbers, so no data is lost, but scripts comparing `rttMs` across
   platforms will read garbage until this is normalized.
10. **Android keepalive close-path re-fires (P1, found in final acceptance —
    FIXED & verified, round 4).** When the watchdog deadline hit a frozen peer,
    the tick kept re-firing the keepalive branch every 1 s (4-5 spurious
    `connect_failed keepalive_timeout` events), threw a `tick` exception
    (double-close on the already-closing socket), and the app's `safeClose` could
    not tear the connection down — only Java-WebSocket's LostTCPPinger (1006)
    closed it, ~20.6-23.4 s after the freeze. Round 4 added a per-peer teardown
    latch (`ConnState.CLOSING` + `closeCause` one-shot) and an idempotent
    library-hard close (`closeConnection`), plus benign-race catches in
    `sendPing`/`broadcastState`. Verified: exactly one `connect_failed
    keepalive_timeout` at +10.99 s after the last pong, exactly one disconnect
    6 ms later via the app's own close (`code=1000 reason=keepalive timeout`,
    remote=false), zero re-fires, zero tick errors, recovery on SIGCONT 512 ms.
11. **macOS watchdog reject-loop after a silent app replacement (mac-side twin
    of defect 2's stale-liveness class; found in the round-4 acceptance pass —
    FIXED & verified, round 5).** When the app process is killed without goodbye
    and stays down longer than the mac's 10 s pong budget, every subsequent
    redial was accepted, handshook — and was then closed by the mac 80-400 ms
    later with `close(1000, "keepalive timeout")`: the mac's watchdog fires on
    the *oldest outstanding unanswered ping*, and the outstanding-ping maps were
    only cleared in `socketDied` — which never runs for sockets the watchdog
    itself closed (nor for newest-wins-superseded sockets), so every fresh
    handshake inherited stale >10 s pings and was judged dead on its first tick
    (measured `lastPongToTimeoutMs=360`/`196`/`60` on brand-new connections).
    The app's reconnect ladder fed the loop indefinitely (132 + 116 closes over
    5.5 min without settling; the 60 s expiry can't fire because every connect
    refreshes `lastSeenAt`). Fix: the outstanding-ping bookkeeping now dies with
    its transport — cleared at both handshake completions (caller + callee), on
    newest-wins adoption, and when the watchdog itself fires. Verified: on the
    old binary the silent-replacement scenario reproduced 14 + 15 fresh-socket
    closes in 45 s; on the fixed binary the same scenario shows zero closes for
    115 s+, the app session ran 7 m 45 s with zero error events and zero mesh
    disconnects, the mac watchdog fired exactly once per genuinely dead socket
    (the frozen regression peer) and never on a fresh socket, the Android-side
    freeze regression still lands a single intent at +10.99 s with a single
    disconnect 6 ms later, and a booked 109 s capstone window showed zero churn
    across 3 re-browse cycles with 42 pongs at exact 5 s cadence.

## Permission difficulties observed

- **macOS**: the Local Network prompt only surfaces for a properly bundled app;
  running the bare built binary can announce/browse *silently failing* with no
  prompt — fixed by shipping `MusicShareMVP.app` via `scripts/make-app.sh`. Once
  denied, recovery is a manual System Settings → Privacy & Security → Local
  Network toggle plus app restart; there is no in-app path.
- **Android 13+**: NSD discovery needs the **Nearby devices** runtime grant, and
  its absence produces no usable error (browse returns nothing) — the app must not
  confuse this with "no peers on the network"; `permission_denied` logging plus the
  manual-connect fallback is the mitigation.
- **Android API 37 runtime surprise**: this image enforces `ACCESS_LOCAL_NETWORK`
  at runtime even with targetSdk 35 — NSD threw SecurityException until both grants
  were set via `pm grant`. Plan for the local-network grant on 16+/35+ regardless
  of targetSdk.
- **Emulator limitation (corrected)**: on THIS host the emulator's mDNS bridged to
  the host network in both directions, so the permission-granted discovery path
  was testable here; on hosts where the emulator network is isolated, `10.0.2.2` /
  `adb forward` manual connects remain the fallback (TEST_PLAN §5).
- First-launch physical behavior of both prompts: not yet observed (no device).

## Lessons from Segue

Detailed study: [`SEGUE_STUDY.md`](SEGUE_STUDY.md). Material outcomes:

- **Duplicate-connection replacement lifted nearly verbatim** (study §4, §8.5):
  newest socket wins per stable device id, old socket closed with a dedicated code
  (4003), superseded side must not auto-reconnect — designed for exactly the
  app-restart flap two mDNS peers produce.
- **Their liveness budget informed ours** (study §4, §6): 30 s cadence/60 s deadline
  plus a 5 s probe-on-command shows detection speed is a *product* choice, not a
  protocol constant; we standardized on the fast path (5 s ping, 10 s deadline).
- **The missing `seq` became our experimental variable** (study §5 notes Segue has
  no sequence/state version): we added per-device monotonic `seq` + `state_conflict`
  logging specifically to observe stale-update behavior that Segue hides.
- **Wire semantics port cleanly without the hub** (study §8): one JSON message per
  text frame, `type` discriminator, ignore-unknown forward compatibility,
  errors-that-don't-disconnect — zero topology coupling.
- **Deferred on purpose**: Segue's clock model (study §5, §8.1) needs sync/offset
  validation we cannot yet do; v1 keeps `ts` informational only.

## Decisions to reconsider before expanding

- **Id-ordering tie-break** gives symmetry with zero negotiation but assumes ids are
  honest and collision-free; any future identity layer must keep the election
  deterministic under new credential schemes.
- **Flat 60 s gone-expiry** (contract §2) is calibrated against typical re-announce
  intervals; real APs with suppressed multicast or heavy traffic may make `peer_lost`
  noisy — measure before touching the constant. (The measured NSD re-browse
  teardown flap — defect 6 — is why the expiry must be paired with a removal
  *grace*, not honored instantly.)
- **"Newest arrival displayed, conflict only logged"** is the correct v1 experiment
  stance but not a product policy; >2 peers or real audio will force a resolution
  decision.
- **Manual connect as the only permission-denial fallback** — consider a guided
  re-permission flow instead of leaving users in a silent-zero-discovery state.
- **Normalize `rttMs` semantics across platforms** (defect 9) before anyone scripts
  cross-platform RTT comparisons.

## Known limitations & unresolved issues

- **No second physical device yet** — every cell above marked "physical device" is
  blocked on hardware; single-machine numbers will not substitute for Wi-Fi results.
- **mDNS in the wild is unknown**: reliability across routers, VLANs, client
  isolation and captive portals is unmeasured; only this host's responder and the
  emulator bridge are proven, and phantom echoes (defect 8) show how environment-
  dependent the responder behavior is.
- **Android 16+ may move discovery behind an opt-in**; unconfirmed, but the
  API 37 runtime enforcement of `ACCESS_LOCAL_NETWORK` (measured) suggests
  designing for stricter models.
- **Clock sync between peers is unvalidated**: `ts` comparisons across devices
  (RTT is intra-peer by design, §4) and any future offset estimation are untested;
  measured drift here was ~67 ppm (~0.48 s over ~2 h).
- **`seq` resets on app restart by design**, so the reconnect path always emits
  `state_conflict` first — correct per contract §6, but it will look like noise in
  logs; keep it as the intended conflict-evidence trigger, and revisit only when a
  persistence question is separately decided.