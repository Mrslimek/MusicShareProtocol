# Segue (segue-music/segue) — technical study

Studied 2026-10-30 from a shallow clone at `/tmp/segue-music-segue` (main @ `dc97249`,
2026-10-17 02:14 -0300). Citations are `path:line` inside that clone.

**Headline correction for our team:** Segue is NOT peer-to-peer and uses NO mDNS/Bonjour. It is a
hub-and-spoke protocol: every device dials a WebSocket hub that runs beside a self-hosted music
server (Navidrome/Subsonic/Jellyfin). Discovery is an HTTP probe of the media server's origin, not
service browsing. `grep -rni "mdns|bonjour|dns-sd|zeroconf|multicast"` matches nothing in the repo.
Its value to us is the **wire protocol and state/liveness semantics**, not the topology.

## 1. Repo overview

- Contents: `SPEC.md` (protocol, 495 lines), `README.md`, `IMPLEMENTING.md` (app-side guide),
  `CLAUDE.md` (agent guidance), and `hub/` — the reference hub in Go. The only client
  (Flutter/Dart, `lib/segue/`, ~850 lines of protocol code) lives in a separate repo
  `segue-music/segue-app` (SPEC.md:7-9, IMPLEMENTING.md:20-22).
- Language/stack: Go 1.27; single dependency `github.com/gorilla/websocket v1.5.3`
  (hub/go.mod:1-7). No SwiftNIO, no Vapor, no Swift anywhere.
- Status: public, **not archived** (GitHub page checked 2026-10-30), ~110 commits, MIT
  (README.md:184). Self-described "vibe-coded" — written by Claude Code with a human directing
  (README.md:21-24); commit messages are Portuguese (CLAUDE.md:99-100). Very young: protocol
  "draft 0" dated 2026-10-03 (SPEC.md:3); hub has run against real Navidrome/Jellyfin only since
  2026-10-03/04 (README.md:55-59).
- Platform support: hub is a static Go binary, Docker images for linux/amd64, arm64, armv7
  (README.md:76-92). Client platforms are whatever Flutter covers (iOS/Android/desktop) — nothing
  in this repo.

## 2. Architecture

- Topology: `phone/TV/desktop — WebSocket — hub — (credential checks, playback reports) — media
  server`. Audio never flows through the hub; devices stream from the media server directly
  (README.md:31-36, SPEC.md:47-54).
- Roles: each **device** is a `player`, `controller`, or both, declared in `hello`
  (SPEC.md:56-57, hub/protocol.go:23-31). Roles/capabilities the hub doesn't know are dropped,
  not rejected (protocol.go:157-183).
- **There is a hub by design** — the hub holds all state: `users map[user]map[deviceID]*entry`,
  one mutex over everything (`hub.go:67-81,138`). No coordinator election exists; the hub is the
  single authoritative coordinator.
- Arbitration rule the hub enforces: **one device plays at a time** — when a player's report
  transitions to `playing`, the hub sends `stop` (or `pause` if it has no `stop`) to the user's
  other playing players (`hub.go:537-565`, SPEC.md:230-234).
- Hub is embeddable: pluggable `Authenticate`/`Translate`/`Report` options, `Handler` serves it
  under `/connect/` or root (`hub.go:19-44`, README.md:169-173); SPEC §13 sketches a media server
  being the hub itself.
- Per-recipient message building: every relayed queue is translated into the recipient's API id
  space (`hub.go:815-861`).

## 3. Discovery (for us: the anti-pattern to note, and its rationale)

- Mechanism: probe `GET {mediaServerBase}/connect/v1/info`, then `/connect/v1/info` on the origin
  if the base had a path (SPEC.md:63-69). A `200` with `{"protocol": "segue", "versions": [1],
  ...}` identifies the hub (SPEC.md:71); fields set at hub/protocol.go... concretely
  `server.go:39` (`fields["protocol"], fields["versions"] = "segue", []int{1}`).
- Hub WebSocket URL is adjacent: `.../connect/v1/ws` (SPEC.md:72; routes registered both with and
  without the `/connect` prefix, `server.go:79-85`).
- Rules: probe once per sign-in, not per request (SPEC.md:78-79); reference app gives each probe
  URL 3 s (IMPLEMENTING.md:31); accept a user-typed hub URL as fallback (SPEC.md:78-79); browser
  probes must be credential-less so `Access-Control-Allow-Origin: *` works (SPEC.md:74-76,
  server.go:105-116). Segue is optional: "No hub: the app works as it did" (IMPLEMENTING.md:36).
- No DNS-SD service type string, no TXT records, no ports beyond default `127.0.0.1:8480`
  (`main.go:93`), no macOS entitlements / Android NSD permission code anywhere (client repo is
  Flutter and not in this clone). TLS is mandatory because `hello` carries credentials
  (`wss://`, SPEC.md:400-401, README.md:123-124).

## 4. Connections

- Transport: WebSocket, JSON **text** frames, exactly one message per frame, every message has a
  `type` string (SPEC.md:87-88). Max inbound frame 1 MiB (`server.go:21`). Client always
  initiates/dials; hub never dials devices.
- Handshake: connect → `hello` (must be first message, within **10 s** or closed `4002`;
  `hub.go:27,134,260`, SPEC.md:87-105) → hub validates credentials against the media server →
  `welcome{protocol, user, serverTime, devices[], lastPlayback?}` (SPEC.md:135-143,
  protocol.go:425-432). Wrong creds → `4001`; media server unreachable → `1011`;
  shutdown → `1001` (SPEC.md:151-159, protocol.go:86-92).
- Duplicate connections: device `id` is stable per installation (UUID string); the same id
  reconnecting **replaces** the old connection — old conn closed with `4003`, its pending commands
  failed `offline`, and the old copy must not auto-reconnect, or the two copies "take turns
  kicking each other out" (SPEC.md:121-123,157, hub.go:392-413, IMPLEMENTING.md:46-47, 200-201).
- Keepalive: hub pings every **30 s**; read deadline `pongWait = 60 s`, so a device that misses a
  ping is dropped at the next one (`server.go:16-17,127-128,254-258`, SPEC.md:363). Additionally,
  every command to a player triggers a **probe ping with a 5 s** pong deadline — a player out of
  reach fails the command `offline` immediately instead of waiting for the 10 s timeout
  (`server.go:24-25,235-243`; `hub.go:759-761`; SPEC.md:364-366).
- Write side: `writeWait=10 s` per frame; per-connection send queue of **64** frames — a device
  that stops reading is dropped rather than blocking the hub (`server.go:18-20,189-197`); close
  handshake waits `closeGrace=5 s` for the peer's close frame (`server.go:19,227-232`).
- Client side: no client pings needed — battery-conscious "request deadline" rule: hub answers a
  command within 10 s and a transfer within 20 s; no answer past that means a dead connection, so
  close and reconnect (SPEC.md:367-371). Reference app uses a 25 s watchdog (IMPLEMENTING.md:205-208).
- Reconnect: exponential backoff starting 1 s, doubling to a 30 s cap, reset after a successful
  `welcome` (IMPLEMENTING.md:198-199); same curve used server-side for media-server detection
  (`main.go:129-147`). After reconnect: resend `hello` + a **full state report** (queues resent in
  full since the hub may have restarted) (SPEC.md:372, IMPLEMENTING.md:93-94).
- Graceful shutdown: hub closes every connection with `1001` first and waits up to 2 s for drains,
  so clients reconnect the moment it returns instead of discovering on next write
  (`hub.go:84-85,177-225`).

## 5. Messages & state

- Serialization: plain JSON, camelCase fields, Go structs with `json` tags as the schema
  (protocol.go:311-326 `incoming` catch-all envelope). `type` is the only discriminator; there is
  **no sequence number, no state version, no idempotency key** beyond request `id`.
- Client→hub types: `hello`, `state`, `command`, `transfer`, `result` (`hub.go:479-492`).
  Hub→client types: `welcome`, `device`, `state`, `gone`, `command`, `result`, `error`,
  `lastPlayback` (SPEC.md:171-182, protocol.go:425-480).
- Request/reply: controller sends `{type:"command", id:"r1", target, command:{action, ...}}`; hub
  relays with its own 16-byte-hex id and `from`; player answers
  `{type:"result", re:"<id>", ok:true|false, error?}`; hub correlates back (`SPEC.md:241-248`;
  `hub.go:731-777,863-868`). Correlation field is `re`, not `id`.
- Identity: `device.id` = plain UUID string kept per installation, also across sign-outs
  (SPEC.md:97,121; IMPLEMENTING.md:46). **No key pairs, no CryptoKit/Ed25519, no trust-on-first-use
  pairing anywhere** — authentication is entirely delegated to media-server credentials carried in
  `hello.auth` with 3 schemes: `subsonic` (username+token+salt), `apiKey`, `jellyfin` (token)
  (protocol.go:107-124; SPEC.md:111-117). Hub caches successful checks 5 min, keyed by SHA-256 of
  the auth JSON (`main.go:78`; auth.go:139-143,199-233); credentials held in memory only, dropped
  on disconnect (`hub.go:98,470`).
- Units: all times/positions/durations are integer milliseconds; volume integer 0–100
  (SPEC.md:88-89).
- Playback state (`PlayerState`, protocol.go:199-212; SPEC.md:191-223):
  - Required in every report: `status` ∈ `playing|paused|stopped`, `positionMs`
    (protocol.go:34-41,334-340 — a missing `positionMs` is rejected; `stopped` means nothing loaded).
  - Optional, **omitted field = keep previous value** (patch-merge semantics; merge in Go at
    protocol.go:214-236, relay preserves only what the sender sent, hub.go:529-530): `queue`,
    `index`, `volume`, `repeat`(`off|all|one`), `shuffle`, `order`.
  - `queue` is the *post-shuffle play order*; `order` is the permutation back to unshuffled
    (SPEC.md:218-223; validated strictly in protocol.go:390-411).
  - `queue` items are self-describing display tuples: `{id?, title, artist, album, durationMs}` —
    no server lookup needed (protocol.go:188-197; id omitted only when cross-API translation failed).
- **The clock model (the crown jewel):** reports carry no device timestamp; the hub stamps `at` =
  hub epoch-ms on arrival (protocol.go:238-242) and relays `state+at`; `welcome.serverTime` lets
  each device learn a **hub-clock offset** (offset = serverTime − localTime, SPEC.md:135-143).
  Any device computes current position as `positionMs + (hubNow − at)` while `playing`, else
  `positionMs`, clamped ≥0 and ≤ track duration (SPEC.md:225-228; protocol.go:255-267;
  IMPLEMENTING.md:76-78: never let `hubNow − at` go negative). Nobody's clock must be right; no
  periodic reporting — report on every change only (SPEC.md:189-191).
- Device presence: `welcome.devices` = full snapshot of the user's other devices (sorted by id,
  hub.go:415-435); thereafter delta broadcasts: `device` (replace your record wholesale),
  `state` (merge), `gone` (delete) (SPEC.md:171-182). Offline players stay listed **paused at the
  position they had reached** — the clock is stopped at disconnect so nobody follows a ghost
  (SPEC.md:183-186; hub.go:453-457; protocol.go:244-252).
- Transfer (`{type:"transfer", id, from?, to, play?}`): hub recomputes source's live position,
  sends destination a `setQueue` (with repeat/shuffle/order), takes over "last playback", then
  stops the source best-effort; source may be offline; `from` empty = the hub's last-playback
  record (SPEC.md:271-304; hub.go:601-709).
- `lastPlayback`: hub's own per-user record of where the music last was (SPEC.md:306-341);
  optional disk persistence via `SEGUE_STATE`, atomic tmp+rename JSON file (SPEC.md:113;
  last.go:15-20,214-224). After restart the record's clock is stopped at last-known position
  (hub.go:143-149).

## 6. Disconnect / timeout / unavailable — exact numbers

| Event | Behavior | Citation |
|---|---|---|
| No `hello` in 10 s | close `4002` | hub.go:27,134,260 |
| Command unanswered | `timeout` after 10 s | hub.go:135,765-777; SPEC.md:266 |
| >32 commands pending to one player | new commands fail `timeout` at once | hub.go:92,744-746 |
| Ping miss | dropped at next ping (30 s cadence, 60 s read deadline) | server.go:16-17 |
| Command sent, no pong to probe in 5 s | connection dropped, command `offline` | server.go:24-25; hub.go:759-761 |
| Peer send queue full (64) | dropped ("isn't reading") | server.go:20,189-197 |
| Device disconnects | pending fail `offline`; state frozen to `paused`; `device` broadcast with `online:false`; last-playback released | hub.go:441-474 |
| Offline device age | `gone` after 24 h, swept every 10 min | SPEC.md:180-181; hub.go:136,308-326; main.go:103 |
| User with 50 devices signs in a 51st | longest-offline forgotten (`gone`) | SPEC.md:181-182; hub.go:89,335-353 |
| Hub unreachable > ~5 s (mobile) | client marks all peers offline w/ last states, resumes local control | SPEC.md:373-379 |
| Hub normal shutdown | close all `1001`, write state, clients reconnect w/ backoff | hub.go:177-225; SPEC.md:159 |
| iOS/Android background | paused app gets suspended, stays listed offline w/ last queue; must report pause before suspension | SPEC.md:380-384 |

- Errors that **don't** close: post-welcome bad messages get `{"type":"error","error":"badMessage"
  |"notPlayer"}` and no effect; unknown message types/fields/capabilities must be ignored for
  forward compatibility (SPEC.md:161-169,126-129; IMPLEMENTING.md:212-213). Hub-side error codes
  (also in `result`): `unknownDevice, offline, notPlayer, unsupported, timeout, badMessage,
  failed, nothingToTransfer` (protocol.go:96-105).

## 7. Platform / network configuration notes

- Nothing macOS/iOS/Android-specific in this repo (no entitlements, no Info.plist, no NSD service
  declarations — the client is Flutter, separate repo). Notes that exist: `wss://` required because
  `hello` carries credentials (SPEC.md:400-401); reverse proxy must pass WebSocket upgrades on
  `/connect/` and not duplicate CORS headers (README.md:120-153); browser pages: probe without
  credentials so `ACAO: *` works; hub takes WS from any origin *only* because auth rides in `hello`,
  never cookies (SPEC.md:74-76, SPEC.md:391-396, server.go:90-116). `SEGUE_AUTH=none` dev mode
  restricts browser origins to loopback (main.go:70-76). Mobile battery rule: no client-initiated
  pings (SPEC.md:369-371).

## 8. MVP takeaways (mDNS + WS + JSON, two peers, no hub)

### ADOPT

1. **Clock model** (SPEC.md:225-228; protocol.go:238-267): every state report carries the
   sender's send-time `at`; peers keep an offset learned at connect (their `serverTime`/`at`
   exchange, or WS ping RTT/2) and extrapolate `positionMs + (now − at)` only while `playing`,
   clamped ≥ 0 and ≤ duration. Eliminates periodic position ticks entirely — report on change only
   (SPEC.md:189-191). This is the single highest-value idea for coordinating music state.
2. **Patch-merge state** (protocol.go:199-236): required `status`+`positionMs` every report,
   everything else omitted-means-unchanged, but send `queue` in full after every (re)connect
   (IMPLEMENTING.md:93-94). Keeps two-peer messages tiny; the `device`-message counterpart says
   *replace*, `state` says *merge* — that distinction prevents lost queues (SPEC.md:176-179).
3. **Command/result envelope** with client-chosen `id`, reply correlating via `re`, and a short
   closed set of machine errors (`offline`, `timeout`, `unsupported`, …), everything else the
   player's own text (SPEC.md:241-269; protocol.go:96-105). For two peers, sender→receiver direct,
   skipping only the hub id-swap.
4. **`hello`/`welcome` handshake with a hello timeout** (10 s, hub.go:260): first message declares
   `roles`, `capabilities`, and a per-installation stable `device.id`; `welcome` returns a full
   `devices[]` snapshot. Unknown types/fields/capabilities ignored → forward compatible
   (SPEC.md:126-129; IMPLEMENTING.md:212-213).
5. **Duplicate-connection replacement** (hub.go:392-413): if the same `device.id` appears on a new
   socket, the new one wins, the old gets a dedicated close code (their `4003`), and the old copy
   must *not* auto-reconnect. Exactly what two flaky mDNS peers need when an app restarts.
6. **Close-code discipline** (SPEC.md:151-159): distinguish fatal (`auth bad` → stop; `protocol
   bad` → fix the app) from transient (`peer restarting` → backoff-reconnect). Map to ours e.g.
   `4001`-style app codes; graceful shutdown sends `1001` first (hub.go:177-225) so the peer
   reconnects instantly.
7. **Keepalive shape** (server.go:16-17,24-25): ping every 30 s, drop after one missed interval
   (read deadline 2×); additionally ping-on-command with a 5 s pong probe so "unreachable peer" is
   detected in ~5 s, not at timeout. Client-side watchdog instead of own pings on battery:
   "request unanswered past its deadline ⇒ connection is dead" (SPEC.md:367-371;
   IMPLEMENTING.md:205-208, 25 s).
8. **Backpressure + fairness**: per-connection bounded send queue, drop the peer that stops
   reading rather than block (64 frames, server.go:20,189-197); per-target pending-command cap
   (32, hub.go:92) so a hung peer fails fast instead of piling up 10 s timeouts.
9. **Offline-but-listed presence** (SPEC.md:183-186; hub.go:453-457): when a peer vanishes, keep
   its last state, freeze its clock to `paused` at the reached position, and let it be the source
   of a later handoff — never mark it `playing`. Prevents "ghost still playing" artifacts.
10. **One-device-at-a-time arbitration** (SPEC.md:230-234; hub.go:540-565): a `playing` report
    triggers `stop` (fallback `pause`) to other players, delivered *as a command from the starter*.
    In two-peer P2P, the starting peer sends that stop itself — same rule, no coordinator needed.
11. **Units & envelope conventions** (SPEC.md:87-89): JSON text frames, one message per frame,
    integer ms everywhere, volume 0–100 integers, frame size cap (1 MiB, server.go:21).
12. **Reconnect policy** (IMPLEMENTING.md:198-201): backoff 1 s → 30 s doubling, reset on accepted
    connection; resend hello + full state; fail all in-flight requests on socket close.
13. **Self-describing queue items** (protocol.go:188-197): id + title/artist/album/durationMs so
    the other peer renders your queue with zero extra lookups — ideal when the two peers may be
    different apps.
14. **Freshness/last-playback concept** (SPEC.md:306-341): the idea that "where the music was"
    outlives the device that played it is directly relevant to our long-term goal; adopt the
    *concept* (last state survives, clock stopped, loadable by either peer), not the hub's
    disk store.

### NOT ADOPT

- **Hub/server role and its single-lock authoritative state** (hub.go:67-81) — our MVP is
  explicitly hubless; Segue assumes it everywhere (no peer auth, no arbitration without hub).
- **HTTP-probe discovery** (SPEC.md:63-79) — gives us nothing for mDNS; we still must design the
  DNS-SD service type, TXT fields, and browse/announce lifecycle ourselves.
- **Credential-proxy auth schemes** (`subsonic`/`apiKey`/`jellyfin` in `hello.auth`,
  protocol.go:107-124; 5-min auth cache, auth.go:139-233) — no media server in our design.
- **No crypto identity at all** (plain UUID, IMPLEMENTING.md:46): on a LAN two-peer MVP that's
  acceptable trust-on-same-network, but Segue offers nothing to copy here; if we ever need it,
  look elsewhere. Also skip the browser-origin/CORS machinery built around that assumption
  (server.go:90-116; SPEC.md:391-397).
- **Cross-API id translation** (Navidrome base62 ↔ Jellyfin GUID, hub/ids.go, SPEC.md:349-358) —
  we have one shared library/namespace.
- **Media-server now-playing / scrobble reporting** (SPEC.md:410-447; hub/report.go, incl. the
  1-minute re-report ticker for Jellyfin) — no media server.
- **`lastPlayback` disk persistence + store goroutine + atomic writes** (last.go:15-230) — file
  durability is hub-operator scope; two peers can hold it in memory.
- **User grouping, 50-device eviction, 24 h offline TTL sweep** (hub.go:89,308-353;
  main.go:103) — housekeeping for multi-user servers; with two peers, presence is
  mDNS-service-exists, and TTL can be a simple constant if anything.
- **Per-recipient message rebuild fan-out** (hub.go:815-861) — hub-relay artifact; our two peers
  each send one socket's worth.
- **Go/gorilla-websocket/Docker stack** (go.mod) — our stacks are Swift (Starscream over
  URLSession) and Kotlin (Java-WebSocket); only the semantics port.
- **Multi-room/sample-accurate sync**: Segue explicitly disclaims it (SPEC.md:43-45) — do not
  treat its position math as a sync reference; it's UI-freshness only.

### Bottom line

Segue is a hub-relayed remote-control protocol; we are building its P2P special case with n=2.
Lift the state/clock/merge/error/liveness semantics (items 1-13 above), drop the hub, its
credential model, and all multi-user/fleet concerns, and supply from scratch the one thing Segue
never had to solve: DNS-SD-based discovery and the peer symmetry it breaks (both sides can be
player and controller; both dial each other or elect by stable-id ordering — Segue has no answer).
