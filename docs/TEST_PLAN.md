# Test Plan

How to run the experiment and what to look for. Event names in backticks are the
contract §7 vocabulary ([`../protocol/PROTOCOL.md`](../protocol/PROTOCOL.md)); every
expectation below is derived from §2–§7, never from the UI.

## 1. Environment prep

- Both devices joined to the **same Wi-Fi SSID** and subnet. If the network uses
  client isolation or blocks multicast/broadcast, mDNS fails by design — use the
  manual-connect fallback and note the network in the report.
- **macOS (15+ model, current machine macOS 27)**: launch the bundled app
  (`scripts/make-app.sh` → `MusicShareMVP.app`); the Local Network prompt appears on
  first announce. Verify/force via **System Settings → Privacy & Security → Local
  Network → MusicShareMVP**. A bare `swift run` binary may not trigger the prompt at
  all — that is why the `.app` exists.
- **Android 13+**: grant **Settings → Apps → MusicShareMVP → Permissions → Nearby
  devices**. Denial makes NSD browse silently return nothing; the app must log
  `permission_denied` and stay usable via manual connect.

## 2. Where evidence lives

| Platform | Live | Exported |
|---|---|---|
| macOS | UI log panel | `~/Library/Application Support/MusicShareMVP/logs/` (JSONL; headless override: `--log-dir`) |
| Android | UI log panel | in-app share/export of the JSON log (attach via system share sheet) |

Pull both logs after every run; the report quotes exported lines, not screenshots.

## 3. Core two-device scenario (14 steps)

Device A = macOS, device B = Android. Record the wall-clock start so `elapsed*` fields
can be sanity-checked.

1. **Launch A.** Expect `app_start`, `discovery_start`, `announce` (first run also
   `permission_request` → `permission_granted`). Check: `announce` follows the WS
   server binding — its port should be dynamic, not fixed.
2. **Launch B.** Same event set as step 1 on B.
3. **Mutual discovery.** `peer_found` on both sides with `remoteId`, `remoteAddr` and
   `elapsedDiscoveryMs`. Note the id ordering — it decides step 4.
4. **Tie-break verification.** Exactly one side logs `connect_attempt`: the peer whose
   id is byte-wise smaller. The larger-id peer must log **no** `connect_attempt`.
   If both dial, that is a bug — capture both logs.
5. **Handshake.** Caller: `handshake_sent` → `handshake_ack` → `connect_ok`
   (`elapsedConnMs` = dial to connected). Callee: `connect_ok` after sending
   `hello_ack`. Both peers now show `connected`.
6. **Post-handshake snapshot.** Both sides log `state_sent` and `state_recv` with the
   sender's **current** `seq` (no increment) — contract §3.
7. **State updates.** Change simulated playback on A → A `state_sent`, B `state_recv`
   (`seq` +1 per change); then change on B → mirrored. UI on each side shows the
   latest arrival per peer.
8. **Test message.** Send `test` from each side: `msg_sent` on sender, `msg_recv` on
   receiver.
9. **Steady keepalive (≥60 s).** `ping_sent`/`pong_recv` pairs every ~5 s on both
   sides, `rtt` lines with `rttMs`. No `keepalive_timeout` may appear.
10. **Hard kill B** (force-stop the app / swipe away — no `goodbye`). A must log
    `keepalive_timeout` within 10 s of B's last answered ping and mark the peer
    `unreachable (keepalive timeout; remote state unknown)`.
11. **Backoff observation.** While B stays dead, A logs `reconnect_scheduled` /
    `connect_attempt` / `connect_failed` at ~1.5, 3, 6, 12 s (±20 % jitter, capped
    30 s). Timing gaps should match the schedule, not a tight retry loop.
12. **Gone expiry.** ~60 s after B's last announcement, A logs `peer_lost` and the
    reconnect schedule must **stop** (no more `reconnect_scheduled`).
13. **Restart B.** A logs `peer_found` (schedule resumes), then `connect_attempt` →
    `connect_ok` per steps 4–5.
14. **Seq-conflict evidence (intentional).** B's `seq` restarts at 1, so A's first
    `state_recv` after restart has `seq` ≤ last seen: A must ALSO log
    `state_conflict` (both seqs + receipt times) while displaying the newest arrival —
    no resolution applied. This is data, not a defect.

## 4. Additional cases

- **Graceful restart.** Quit B from the UI: `goodbye` (`reason=app_shutdown` or
  `user_close`) then close 1000 on both sides; A logs `disconnect` immediately (not
  after 10 s) and reconnects as soon as B is back. Contrast with step 10 — this is
  the detection-latency delta the report needs.
- **Wi-Fi toggle (B).** Turn Wi-Fi off 20 s, on: `net_change` on B, `peer_lost` and/or
  `keepalive_timeout` on A, re-`peer_found` and reconnect after. Distinguish which
  failure signal fired first (L2 loss vs mDNS expiry).
- **Network change.** Join both devices to a *different* SSID together: old peers must
  go `gone` (service removed), new ones `peer_found`; nothing reconnects across
  subnets — a negative control for "discovery ≠ connectivity".
- **Simultaneous launch.** Start both apps within the same second: after discovery,
  still exactly one `connect_attempt` side (tie-break under race). Then, with both
  connected, **both** enter manual connect to each other: two sockets form and each
  side must log the replacement and close the old with 4003, converging to one
  connection. Newest wins on both sides is the assertion.
- **Permission denial run.** Deny Local Network (macOS) or Nearby devices (Android),
  restart: expect `permission_denied`, zero `peer_found`, and a working
  manual-connect path (steps 5–9 run unchanged over it).

## 5. Emulator / loopback verification (no second device required)

Evidence-generating runs that work on one laptop:

- **macOS ↔ macOS loopback.** Two headless instances on one machine:
  `…MacOS/MusicShareMVP --headless --name peer-a --id <uuidA> --port <portA> --log-dir /tmp/ms-a`
  and a second with `--id <uuidB> --port <portB> --log-dir /tmp/ms-b`. Same-host Bonjour
  discovers both; if multicast is suppressed, pair them with
  `--connect <host:port>` (read the port from the other instance's `announce` line —
  dynamic ports are what makes this trivial). `macos/scripts/smoke_test.sh` automates
  this pair and is the current source of all loopback numbers.
- **Android emulator ↔ macOS.** mDNS traversal in the emulator is host-dependent: on the
  development host used for this experiment multicast bridged in both directions and the
  discovery path worked directly (measured). On hosts where the emulator's multicast is
  isolated, manual connect is the designed path:
  - *emulator → mac:* from the emulator dial `10.0.2.2:<mac-port>` (the mac peer's
    announced port). Exercises callee/caller handshake from the Kotlin side
    (Java-WebSocket) against the Swift server.
  - *mac → emulator:* `adb forward tcp:<P> tcp:<P>` (forwarding to the emulator's WS
    server port), then manual-connect from the mac app to `127.0.0.1:<P>`. Exercises
    the Swift client against the Kotlin server.
- **Handshake-timeout staging (contract §3, 5 s → 4002).** A plain TCP listener
  (`nc -l -p <P>`) that never completes the WS upgrade should produce
  `connect_failed` quickly at the transport layer. To hit the *hello-level* timeout
  precisely, run a throwaway WS stub that completes the WS upgrade and then stays
  silent: the dialer must close 4002 at ~5 s, log the attempt as `failed (handshake
  timeout)` — and must NOT claim the remote is down.

## 6. Recording table — the ten report questions

| # | Question | Measurement (contract §7) | Log evidence | Covered by |
|---|---|---|---|---|
| 1 | How fast is discovery after launch? | `app_start` → first `peer_found` | `elapsedDiscoveryMs` | Core 1–3 |
| 2 | Is discovery stable (no phantom `gone`)? | `peer_found`/`peer_lost` rate over ≥1 h idle | absence of spurious `peer_lost` at 60 s expiry | Core 9, network-change case |
| 3 | Does the tie-break elect exactly one dialer? | `connect_attempt` on one side only | both logs, step-by-step | Core 4; simultaneous launch |
| 4 | How long is full connection establishment? | `peer_found` → `connect_attempt` → `connect_ok` | `elapsedConnMs` | Core 3–5 |
| 5 | Does handshake timeout behave as specified? | dial to close ≈5 s, code 4002 | `connect_failed`/`handshake_timeout` lines | Handshake-staging run (§5) |
| 6 | What is application-level RTT on a healthy LAN? | `ping_sent` → `pong_recv` | `rtt` / `rttMs` distribution | Core 9 (≥12 samples) |
| 7 | How fast is silent-peer failure detected? | last `pong_recv` → `keepalive_timeout` | ≤10 s delta on A | Core 10; graceful-restart contrast |
| 8 | Does reconnect follow the schedule and stop at `gone`? | attempt gaps vs 1.5→30 s ±20 % | `reconnect_scheduled`, `peer_lost`, resume on `peer_found` | Core 11–13 |
| 9 | Is state sync correct, incl. conflict evidence? | snapshot seq unchanged; `seq` monotonic in-run | `state_sent`/`state_recv`/`state_conflict` | Core 6–7, 14 |
| 10 | What is the permission-model cost? | `permission_request`→`granted`/`denied`; manual fallback works | first-run logs + denial run | Core 1–2; denial run (§4) |

## 7. Interpretation caveats (stress points)

- **Discovery ≠ connectivity.** `peer_found` only proves an mDNS record resolved; the
  TCP path can still fail (isolation, firewall). Report discovery and connection
  timings as separate series — the UI does the same, per contract §2.
- **Timeout ≠ dead remote.** A 4002 or `keepalive_timeout` proves *our local attempt to
  make progress* failed; the contract deliberately words state as "remote state
  unknown". Never write "peer was down" in results unless logs from *that peer* show
  it was alive or gone at the same wall-clock moment.
