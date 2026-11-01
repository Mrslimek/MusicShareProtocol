# Music Share MVP

A two-device peer-to-peer networking experiment: **discovery, connection, and state sync**
between one macOS peer and one Android peer on a single local network. No audio, no files,
no server, no relay — the payload is simulated playback state as JSON. The goal is to
measure how real platform service discovery (mDNS/Bonjour/NSD) and WebSockets behave under
failure, so the eventual music-sharing feature is built on evidence.

The authoritative wire contract is [`protocol/PROTOCOL.md`](protocol/PROTOCOL.md). Both
apps implement it field-for-field; that document wins every argument.

## Repo layout

| Path | Contents |
|---|---|
| `protocol/PROTOCOL.md` | v1 wire contract: discovery, handshake, keepalive, messages, logging vocabulary |
| `macos/` | Swift package `MusicShareMVP` — details in [`macos/README.md`](macos/README.md) |
| `android/` | Gradle/Kotlin app — details in [`android/README.md`](android/README.md) |
| `docs/ARCHITECTURE.md` | topology, peer state machine, design decisions, Segue study outcomes |
| `docs/TEST_PLAN.md` | the full two-device test protocol, step by step, with expected log events |
| `docs/REPORT.md` | results report — physical-device rows currently UNVERIFIED |
| `docs/SEGUE_STUDY.md` | study of the segue-music protocol that informed the design |

## Quickstart — macOS

Prerequisites: macOS 15+ (Local Network permission model), Xcode/Swift toolchain.

```sh
cd macos
swift build
./scripts/make-app.sh        # produces MusicShareMVP.app
open MusicShareMVP.app
```

On first announce/browse the app requests the **Local Network** permission. Approve it in
the prompt; if dismissed, grant manually via System Settings → Privacy & Security →
Local Network → MusicShareMVP, then relaunch. Without it, Bonjour is silently blocked.

Headless mode (two-instance loopback testing on one machine):

```sh
MusicShareMVP.app/Contents/MacOS/MusicShareMVP \
  --headless --name "peer-a" --id <uuid> --port <n> --log-dir <dir>
```

Optional `--connect host:port` forces a manual dial (see `docs/TEST_PLAN.md`).
`scripts/smoke_test.sh` runs the loopback scenario automatically.

## Quickstart — Android

Prerequisites: JDK 17+, Android SDK (an emulator image also works for build/boot smoke).

```sh
cd android
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

On first discovery use the app requests the **Nearby devices** runtime permission
(Android 13+). Grant it via the prompt, or Settings → Apps → MusicShareMVP →
Permissions → Nearby devices. Without it, NSD browse returns nothing and dials over the
LAN are unaffected only in name — treat discovery as dead.

## Two-device test — condensed checklist

Full protocol with expected log events per step: [`docs/TEST_PLAN.md`](docs/TEST_PLAN.md).

1. Both devices on the same Wi-Fi SSID; Local Network (macOS) and Nearby devices (Android) granted.
2. Launch both apps → each logs `app_start`, `discovery_start`, `announce`.
3. Mutual discovery → `peer_found` on both, with `elapsedDiscoveryMs`.
4. Exactly one side dials (the smaller device id, by contract) → `connect_attempt`, then
   `handshake_sent` / `handshake_ack` / `connect_ok` on both.
5. Fresh `state_update` snapshot each way; then change simulated playback on either side
   and watch `state_sent` / `state_recv` with increasing `seq`.
6. Send a `test` message → `msg_sent` / `msg_recv`.
7. Watch keepalive: `ping_sent` / `pong_recv` / `rtt` every ~5 s.
8. Kill one device without goodbye → the other logs `keepalive_timeout` within 10 s, then
   `reconnect_scheduled` with 1.5→30 s backoff, then `peer_lost` (gone) after 60 s silence,
   and reconnect stops. Restarting it resumes the cycle and exposes a `state_conflict`
   (seq reset — by design).

## Logs

- **macOS**: JSON lines in `~/Library/Application Support/MusicShareMVP/logs/`
  (headless: override with `--log-dir`). A live log panel is in the app UI.
- **Android**: in-app log view; use the **share/export** action to pull the JSONL off the
  device (system share sheet) for archiving.
- Event vocabulary and required measurements: contract §7.

## Results & honest status

Results live in [`docs/REPORT.md`](docs/REPORT.md). Current verification status:
**single-machine measurement only** — macOS↔macOS loopback plus macOS ↔ Android-emulator
cross tests (both directions, incl. failure injection: freeze/recovery, graceful shutdown,
permission denial, defect-fix re-verification), all on one host with the emulator's mDNS
bridged (environment-specific). No physical two-device Wi-Fi test has been run yet; every
physical-device result in `docs/REPORT.md` is marked as such. All measured numbers there
are labeled single-machine.

## Landing page

Curious what this project is aiming for? Check out the **vibe-coded landing page** — a visual introduction to the idea, the intended user experience, and the protocol architecture:

**[MusicShareProtocol — What if your music could follow you?](https://mrslimek.github.io/MusicShareProtocol/)**

It's an early visual concept, not a demo of working music handoff. The actual implementation status and test results are documented above.
