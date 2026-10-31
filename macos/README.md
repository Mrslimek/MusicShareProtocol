# Music Share MVP — macOS app

Minimal peer-to-peer discovery + simulated-playback sync over mDNS + WebSocket,
implementing `protocol/PROTOCOL.md` v1 exactly. SwiftUI/AppKit GUI with a full
headless mode; a from-scratch RFC 6455 WS server (Starscream 4.0.8 is used only as
the client — its server cannot report the bound port of a port-0 listener, which
discovery advertisement and the headless `READY` line require).

## Prerequisites

- Apple silicon Mac, macOS 13+ (built and verified on macOS 27.0.1, arm64).
- Xcode 27.1 with Swift 6.4 compiler. The package pins `swift-tools-version:5.10`
  and compiles in Swift 5 language mode; a newer toolchain is fine, Swift 6 mode
  is not used.
- Network access on first resolve for the Starscream dependency (already vendored
  in `.build/checkouts` on this machine; after that `swift build` works offline).

## Build

```sh
cd macos
swift build                      # debug
bash scripts/make-app.sh        # release + build/MusicShareMVP.app (ad-hoc signed)
```

## Run

GUI:

```sh
open build/MusicShareMVP.app     # from make-app.sh
swift run MusicShareMVP          # or straight from the package
```

Headless (no UI; JSONL log to stdout and file; prints `READY id=<id> port=<port>`
once the WS listener is up; `STATUS discovered=<n> connected=<m> last_rtt=<ms|->`
every 30 s; SIGINT/SIGTERM send `goodbye` to all peers, log `app_stop`, exit 0):

```sh
swift run MusicShareMVP --headless
swift run MusicShareMVP --headless --name Box --id <uuid> --port 0 \
    --connect 192.168.1.10:54321 --log-dir /tmp/mslogs
```

`--id` / `--name` override only for that run; the persisted identity in
`~/Library/Application Support/MusicShareMVP/device.json` is untouched. The GUI
name field persists on change and re-announces via mDNS.

End-to-end self-test (two headless instances on this machine, discovery-first,
manual-connect fallback, keepalive-death detection, reconnect):

```sh
bash scripts/smoke_test.sh       # exits 0 on PASS, prints all measurements
```

## Local Network permission (macOS 15+ / 27) and firewall

First GUI launch triggers (or silently depends on) the system **Local Network**
prompt. Decline → mDNS publish/browse fail; the app shows a banner pointing at
System Settings → Privacy & Security → Local Network, logs `permission_denied`
(dns_sd codes -65563/-65555/-65550/-65570/-65571 are classified as
permission-related), and **manual connect keeps working** (plain TCP).

Headless runs launched from a terminal inherit the terminal app's Local Network
permission; the bundled .app gets its own prompt. If you never see a prompt,
check System Settings → Privacy & Security → Local Network and enable the entry
(Terminal / Music Share).

Firewall: allow incoming connections for the app (System Settings → Network →
Firewall). The WS server listens on a dynamic port — a per-app allow rule, not a
port rule, is what matters.

Logs: JSONL per run in `~/Library/Application Support/MusicShareMVP/logs/`
(`--log-dir` to override), file name `session-<ISO>-<id8>.jsonl`. GUI: scrolling
in-app log with Copy / Show in Finder buttons.

## Troubleshooting

- **Never READY** — port pinned and busy? Use `--port 0` or another port
  (`listenFailed` logs the bind error).
- **Peers discovered but never connect** — Local Network permission missing, or
  firewall dropping the inbound dial. Check `permission_denied` /
  `connect_timeout` in the log; try manual connect (`host:port` in the GUI or
  `--connect`).
- **Peers flap to `unreachable` then recover** — normal after keepalive timeout
  (pong missing for 10 s); reconnect backoff runs 1.5→30 s ±20 %.
- **Two instances on one machine** — handled: mDNS instance name conflict
  triggers automatic re-publish with a suffixed name; TXT `id` still distinguishes
  them.
- **`state_conflict` in logs** — by design after a peer restarts (its `seq`
  restarts at 1): the newest arrival is still displayed, the anomaly is recorded.

## VERIFIED in this environment (macOS 27.0.1, two headless instances on one
machine, mDNS allowed — smoke_test.sh, repeated twice, PASS both times)

Discovery-driven connection (mode=discovery, no manual connect):
- listener up: app_start→discovery live = **3–12 ms**; first `peer_found` =
  **1.5–2.0 s** after Alpha app_start (Beta saw Alpha at 36 ms — cached browse).
- total connection establishment (`connect_attempt`→`connect_ok`) = **7–16 ms**;
  `peer_found`→`connect_attempt` = **53–533 ms** (dial scheduler tick granularity).
- handshake both sides, post-handshake `state_update` snapshots both sides,
  `smoke-hello from <name>` test message delivered both ways, `state_recv` +
  ≥2 `pong_recv` per side.
- RTT loopback (`pong_recv.rttMs`): **0.42 ms**.

Failure detection and recovery:
- Beta hung (SIGSTOP — simulates a silent/dead peer; a local `kill -9` would
  tear down TCP and produce an immediate `disconnect` instead, see
  smoke_test.sh header): Alpha logged `keepalive_timeout` **15.8–16.6 s** after
  the hang (app-internal last-pong→timeout: **16.0–17.0 s** — ping period 5 s
  plus pong timeout 10 s plus scheduler tick, within the 25 s assertion).
- Beta restarted: `connect_ok` on both sides after **15–24 s** (assertion ≤ 90 s;
  driven by Alpha's reconnect backoff after failed dials to the old port plus a
  45 s mDNS re-browse cycle refreshing the peer's advertised host:port).
- clean shutdown: both sides logged `goodbye` sent+received and `app_stop`, exit 0.

App packaging:
- `swift build`, `swift build -c release`, `scripts/make-app.sh`, bundled
  binary headless run, `swift run`, and GUI launch via `open` (window, persisted
  identity, advertised service, graceful quit) — all pass, zero warnings.

## NOT VERIFIED (needs a second physical device / real network)

- Multi-machine mDNS across a real Wi-Fi LAN (loopback/mDNSResponder on one Mac
  cannot prove this), and the actual first-run **Local Network permission
  prompt/denial behavior** for the GUI app — denial/fallback paths were only
  verified structurally (the smoke's manual-connect fallback path) and by
  simulating a dead peer, not by revoking the TCC grant.
- Firewall-blocked inbound on a foreign subnet; IPv6-only networks.
- Cross-platform interop with the Android app (`hello`/TXT field-for-field
  matching was verified against the contract text, not against a second
  implementation).
- GUI interaction itself (buttons, selection) — code-reviewed only; no UI
  automation was run.
- Peer expiry (`gone` after 60 s of no re-announcement) end-to-end — the timer
  is implemented and visible in logs from the pre-fix run, but the smoke test
  does not wait 60 s.

## Known limitations

- WS server handles unfragmented text/close/ping frames only (protocol §6 uses
  one JSON text frame per message); oversized (>1 MiB) or fragmented frames close
  with 1011.
- `RTT = pong.ts − ping.ts` compares remote clocks as the contract prescribes;
  on different machines with clock drift it is meaningless — the local
  send→receive delta (`localDeltaMs` in `pong_recv`) is logged alongside and is
  the trustworthy number.
- Headless STATUS `last_rtt` reports the max recent RTT across peers.
