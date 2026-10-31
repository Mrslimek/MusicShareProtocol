# Architecture

Design rationale for the two-peer MVP. The wire contract itself is authoritative in
[`../protocol/PROTOCOL.md`](../protocol/PROTOCOL.md); nothing here overrides it.

## Topology

```
            local network only — no hub, no relay, no server

  ┌────────────────────────┐                    ┌────────────────────────┐
  │        Peer A          │   mDNS browse /    │        Peer B          │
  │  NSD/Bonjour advertiser│◄──announce────────►│  NSD/Bonjour advertiser│
  │  NSD/Bonjour browser   │  (_musicshare.    │  NSD/Bonjour browser   │
  │                        │   _tcp, TXT:       │                        │
  │  WS server :<dyn port> │   id,name,v)       │  WS server :<dyn port> │
  │  WS client(s)          │◄══════════════════►│  WS client(s)          │
  │  peer state machine    │  at most ONE WS    │  peer state machine    │
  │  log pipeline          │  conn per peer id  │  log pipeline          │
  └────────────────────────┘                    └────────────────────────┘
        ╲  exactly one side dials: the one whose device id is
          ╲ byte-wise smaller (manual connect overrides this)
```

Symmetric by design: every peer advertises, browses, listens, and may dial. Both platforms
run the identical logic; `hello`/`hello_ack` differ only in who sends first.

## Per-peer components

- **Advertiser** — registers `_musicshare._tcp` with TXT `id`, `name`, `v=1` once the WS
  server is listening; unregisters on clean shutdown (contract §2).
- **Browser** — resolves announcements to host+port; emits `peer_found` / `peer_lost`;
  expires peers with no re-announcement for 60 s.
- **WS server** — accepts dials, answers `hello_ack`, enforces one-connection-per-peer-id
  (newest wins, old closed with 4003).
- **WS client** — one dial in flight per peer; sends `hello`; drives the reconnect
  backoff schedule.
- **Peer state machine** — per remote id: `discovered` / `connecting` / `connected` /
  `unreachable` / `gone`. Discovery and connection state are tracked separately (a peer
  can be discovered and unreachable at once).
- **Log pipeline** — structured JSONL per contract §7 (event vocabulary, `elapsedDiscoveryMs`,
  `elapsedConnMs`, `rttMs`), mirrored to the UI, to disk, and to Android share-export.

## Dial tie-break

After resolving a peer, both sides compare device ids **byte-wise** (contract §3):
the smaller id dials, the larger id waits. This elects a caller with zero negotiation —
ids are stable per installation and visible to both via TXT, so both compute the same
verdict and simultaneous-dial churn cannot happen from automatic discovery.

Example: peer A id `a1b2c3…`, peer B id `f00d9e…`. `'a'` (0x61) < `'f'` (0x66), so A dials
`ws://B-host:B-port` and B only accepts. If both users enter manual connect at the same
moment, the rule is overridden twice (both are callers), two sockets exist briefly, and
each side's newest-wins replacement closes the older one with 4003 — converging to one.

## Messages

One JSON text frame per message; envelope `v`, `type`, `id`, `from`, `ts` (+ optional
`replyTo`) on every message (contract §6).

| type | extra fields | purpose |
|---|---|---|
| `hello` | `name`, `platform`, `appVersion` | caller opens handshake; `connected` for callee begins here |
| `hello_ack` | `name`, `platform`, `appVersion`, `replyTo` = hello.id | callee completes handshake |
| `ping` | — | liveness probe, every 5 s |
| `pong` | `replyTo` = ping.id | liveness answer; `pong.ts − ping.ts` → `rttMs` |
| `state_update` | `track`, `status`, `positionSec`, `seq` | simulated playback state; `seq` is per-device monotonic, exists to expose conflicts |
| `test` | `text` | user-triggered arbitrary message for connectivity demo |
| `goodbye` | `reason` ∈ `app_shutdown`/`user_close`/`manual` | best-effort pre-close notice, then close 1000 |

Receiver rules: unknown type → `message_unknown` (keep open); bad fields →
`message_malformed`; id within the last 128 from that peer → `message_duplicate`.

## Peer state machine

```
                     peer_found                dial won / manual
          ┌──────────────────────┐    ┌─────────────────────────┐
 app_start│                      ▼    ▼                         │
          ├───────►   DISCOVERED  ─────────►   CONNECTING        │
          │           ▲    │  ▲                  │    │          │
          │           │    │  │ peer_found        │    │ 5 s no   │
   announce           │    │  │ (reappear)        │    │ hello /  │
          │    peer_found  │  │                   │    │ hello_ack│
          │           │    │  │                   ▼    ▼          │
          │           │    │  │            handshake ok           │
          │           │    │  │           (caller: hello_ack,     │
          │           │    │  │            callee: sent hello_ack)│
          │           │    │  │                   │               │
          │           │    │  │                   ▼               │
          │           │    │  └───────────  CONNECTED  ◄──────────┘
          │           │    │            │        │
          │   60 s silence / service │        │ close seen (goodbye+1000,
          │        removed         │        │ 10 s no pong, socket error)
          │           │            │        ▼
          │           │            │   UNREACHABLE ── backoff retry ──► CONNECTING
          │           ▼            │   (1.5 s→30 s ±20 %; stop when peer goes GONE,
          │           GONE ◄───────┘    resume schedule if it reappears)
          └───────────┘
```

Transitions and the timers that drive them:

| Transition | Trigger | Timer / number |
|---|---|---|
| → `discovered` | mDNS service resolved (`peer_found`) | `elapsedDiscoveryMs` measured from `discovery_start` |
| `discovered` → `connecting` | I hold the smaller id (auto-dial) or user entered `host:port` (manual, overrides rule) | one dial in flight per peer |
| `connecting` → `connected` | caller: `hello_ack` received; callee: `hello_ack` sent | — |
| `connecting` → failed | handshake timeout; close **4002** | **5 s** from socket open, both roles |
| `connected` → `unreachable` | keepalive timeout (`remote state unknown`), socket error, or remote close | ping every **5 s**; pong deadline **10 s** |
| `unreachable` → `connecting` | reconnect backoff retries | **1.5, 3, 6, 12, 24 → cap 30 s, ±20 % jitter**; reset after success |
| any → `gone` | OS reports service removed, or no re-announcement for **60 s** | 60 s expiry; reconnect schedule stops |
| `gone` → `discovered` | peer reappears (`peer_found`) | schedule resumes |
| same-peer new socket | newest wins; old socket closed **4003**, logged both sides | at most one connection per peer id |

## Decisions and rationale

- **mDNS + WebSocket + JSON survived as the starting hypotheses.** Both platforms ship
  first-class system APIs for discovery (Bonjour / NSD) and mature, protocol-visible
  WebSocket libraries (Starscream / Java-WebSocket), so the experiment tests platform
  behavior, not library quality. JSON text frames are human debuggable and identical on
  both stacks. The contract is platform-neutral, so a Linux peer can join later without
  protocol changes (contract §1).
- **Dynamic ports.** The WS server binds an OS-assigned ephemeral port and publishes it in
  the SRV record. No port conflicts with other apps, multiple instances on one machine
  become trivially testable (the loopback harness relies on this), and there is no
  firewall pre-configuration or well-known port to be blocked by network policies.
- **Smaller-id dials.** A symmetric mesh needs exactly one caller per pair. Byte-wise id
  comparison is a zero-round-trip election: both peers see both ids in TXT and reach the
  same verdict deterministically. It also makes duplicate-connection bugs *observable*
  rather than merely harmful — see 4003 replacement logging.
- **Manual connect exists as a fallback and a test seam.** When Local Network / Nearby
  devices permission is denied, discovery is dead but direct `host:port` dialing still
  exercises the handshake and keepalive paths. On the Android emulator, mDNS multicast
  traversal is host-environment-dependent: on this experiment's development host the
  emulator bridged multicast in both directions (the host found the app's service and
  the app found the host's, both measured), so the discovery path itself was testable.
  On hosts whose network stack isolates the emulator (common on VPNs and some Wi-Fi
  setups), `adb forward` + manual connect is the fallback — the contract's "manual
  overrides the rule" clause exists for exactly this.
- **Keepalive is JSON `ping`/`pong`, not WS protocol pings.** Control-frame ping/pong APIs
  and their timing semantics differ between Starscream and Java-WebSocket, and answers
  are generated inside the socket layer, invisible to app code. A JSON ping rides the
  same path as every message, so both stacks run identical logic, RTT is measurable
  at the application level (`pong.ts − ping.ts`), and both platforms emit the same
  `ping_sent` / `pong_recv` events. Contract §4 notes the clock caveat: timestamps are
  only comparable within one peer.

## Segue study outcomes

From [`SEGUE_STUDY.md`](SEGUE_STUDY.md) — what we took from a hub-and-spoke protocol for
a hubless two-peer mesh (study §8 "Bottom line": we are Segue's P2P special case at n=2).

**Adopted**

- **`hello`/`ack` handshake shape** — first-message identity exchange with a hard timeout
  and a dedicated close code (study §4: hello within 10 s else 4002; §8.4). We kept the
  shape, tightened the deadline to 5 s, and renamed the ack `welcome` → `hello_ack` with
  `replyTo` correlation (§8.3's command/result envelope idea, shrunk to the handshake).
- **Newest-wins single-connection-per-peer replacement** with a dedicated close code, and
  the superseded side must not auto-reconnect (study §4 duplicate connections, §8.5) —
  this is exactly the app-restart flap two mDNS peers produce. Contract §3, close 4003.
- **Short probe deadlines for fast liveness** (study §4: 5 s probe ping on command, §8.7)
  — their background cadence was 30 s/60 s and only the probe was fast; we made the fast
  path the steady path: ping every 5 s, pong deadline 10 s, dead peer detected ≤ 10 s.
- **Structured JSON over WS, exactly one message per frame, `type` discriminator, ignore
  unknown fields/types for forward compatibility, bounded errors that don't disconnect**
  (study §4/§5, §8.11) — contract §6 envelope + receiver rules.
- **Per-device monotonic `seq`** — deliberately *not* lifted: the study notes Segue has
  "no sequence number, no state version" (study §5). Our experiment's purpose includes
  observing stale/conflicting updates, so we added the counter and the `state_conflict`
  log (latest arrival still wins, no resolution policy — contract §6).
- **Backoff to a 30 s cap, reset on success, resend state after (re)connect** (study §4
  reconnect, §8.12); graceful shutdown closes cleanly so the peer reconnects at once
  (study §8.6, §4 shutdown — ours: `goodbye` then close 1000).

**Not adopted**

- **Hub/coordinator with authoritative single-mutex state** (study §2) — topology is
  explicitly hubless; there is nothing to arbitrate with two symmetric peers.
- **Credential-proxy auth** (`hello.auth` subsonic/apiKey/jellyfin schemes, study §2/§5) —
  no media server exists; identity/encryption is out of scope v1.
- **Media-server coupling and HTTP-probe discovery** (study §3) — we design DNS-SD
  service type, TXT fields, and browse/announce lifecycle ourselves.
- **Fixed client-vs-server role split** (only devices dial, never the hub — study §4) —
  our peers are symmetric; the caller role is elected per pair by the id tie-break.
- **24 h gone-TTL sweeps and fleet housekeeping** (study §6 offline device age, §8
  NOT ADOPTED) — presence here is "mDNS service exists"; expiry is a flat 60 s.

## Out of scope (v1) — mirrors contract §8

Audio; file transfer; message relay; encryption/identity verification; NAT/WAN traversal;
background services; conflict-resolution policy; playback synchronization.

## Future hooks — explicitly "not now"

- **Linux peer** — protocol is already platform-neutral; a third implementation would
  validate symmetry. *Not now: the experiment needs only the two shipped platforms.*
- **Security/identity** — trust-on-same-LAN is acceptable for measurement; signed
  `hello` / TOFU pairing later. *Not now: would change ids and confound v1 baselines.*
- **Relay / multi-subnet** — a relay breaks the "no hub" premise and is a different
  experiment. *Not now: single local network is the whole subject.*
