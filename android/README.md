# Music Share MVP — Android app

Android peer of the minimal p2p discovery/communication MVP. Implements
`protocol/PROTOCOL.md` **field-for-field**: `_musicshare._tcp` DNS-SD discovery with
`id`/`name`/`v` TXT records, smaller-id-dials tie-break (manual connect overrides), the
`hello`/`hello_ack` handshake (5 s timeouts, close codes 4002/4003/1011/1000), the
post-handshake `state_update` snapshot, JSON keepalive `ping` (5 s) / `pong` timeout (10 s),
reconnect backoff 1.5→30 s with ±20 % jitter, per-peer single connection with newest-wins
replacement, the full message schemas, duplicate/unknown/malformed handling, the structured
log-event vocabulary, and the required timing measurements.

Kotlin, single `Activity`, plain XML views (no Compose), minSdk 26 / compileSdk 37 /
targetSdk 35. The networking core (`MeshController`) is fully separated from the `Activity`.

## Layout

```
android/
  settings.gradle build.gradle gradle.properties local.properties
  gradlew gradle/wrapper/            # committed Gradle wrapper (8.14.2)
  app/build.gradle
  app/src/main/AndroidManifest.xml
  app/src/main/res/layout/activity_main.xml
  app/src/main/res/values/strings.xml
  app/src/main/java/com/musicshare/mvp/
    Protocol.kt        # constants, envelope builder, message parse + field validation
    Jsonl.kt           # structured JSONL logger: logcat(tag MShare) + ring buffer + file
    DeviceStore.kt     # persistent UUID-v4 id (SharedPreferences) + editable name
    Discovery.kt       # NsdManager register/browse/resolve + MulticastLock
    MeshController.kt  # WS server+client, per-peer state machine, keepalive, reconnect, state
    MainActivity.kt    # UI, permission gate, network monitor, intent hook, log view
```

## Dependency substitution (IMPORTANT)

The task pinned `org.java-websocket:Java-WebSocket:1.7.0`, but **1.7.0 is not published on
Maven Central** (verified: the repo lists 1.3.0 … 1.6.0 as the newest). This build therefore
uses the latest actually-published version, **1.6.0** (same API family: `WebSocketServer` +
`WebSocketClient`, both raw sockets). This is the only deviation from the stated spec and it
is an availability fact, not a protocol change. See `app/build.gradle`.

## Prerequisites / bootstrap (exact commands used)

Everything was installed **without sudo** on macOS arm64. `brew --cask` needs sudo, so the
Temurin tarball was pulled straight from the Adoptium API.

JDK 21 (Temurin) into `~/jdks`:
```bash
mkdir -p ~/jdks
curl -sL -o /tmp/jdk21.tar.gz \
  "https://api.adoptium.net/v3/binary/latest/21/ga/mac/aarch64/jdk/hotspot/normal/eclipse"
tar -xzf /tmp/jdk21.tar.gz -C ~/jdks
export JAVA_HOME="$HOME/jdks/jdk-21.0.13+9/Contents/Home"   # path from tarball (may differ)
"$JAVA_HOME/bin/java" -version
```

Gradle 8.14.2 (no `gradle` binary existed), bootstrapped to generate the wrapper once:
```bash
curl -sL -o /tmp/gradle.zip https://services.gradle.org/distributions/gradle-8.14.2-bin.zip
unzip -q /tmp/gradle.zip -d /tmp/gradle
cd android
/tmp/gradle/gradle-8.14.2/bin/gradle wrapper --gradle-version 8.14.2 --distribution-type bin
# from now on use ./gradlew
```

Android SDK is already at `~/Library/Android/sdk` with **only**:
`platforms;android-37` (installed as the minor-version dir `android-37.0`), `build-tools;36.0.0`,
`platform-tools` (adb), `emulator`, API-37 arm64 system image. There is **no `cmdline-tools` /
`sdkmanager`** — no new SDK packages were installed. `local.properties` pins `sdk.dir`:
```
sdk.dir=/Users/viktor/Library/Android/sdk
```

Toolchain choices: AGP **8.13.0** (JDK 21 + Gradle 8.14 compatible), Kotlin **2.1.20**,
`compileSdk 37`. AGP 8.13 does not know API 37's surface, so
`android.suppressUnsupportedCompileSdk=37` is set in `gradle.properties` to silence the
"compileSdk newer than tested" warning. `buildToolsVersion "36.0.0"` pins the one installed.

## Build

```bash
export JAVA_HOME="$HOME/jdks/jdk-21.0.13+9/Contents/Home"
cd android
./gradlew assembleDebug
# APK: app/build/outputs/apk/debug/app-debug.apk
```
Compile emits **2 warnings**, both the Android platform deprecating `NsdManager.resolveService`
and `NsdServiceInfo.host` on API 34+ (kept for minSdk-26 compatibility). No other warnings.

## Install & run

```bash
export ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" install -r app/build/outputs/apk/debug/app-debug.apk
"$ADB" shell am start -n com.musicshare.mvp/.MainActivity
```

Headless emulator smoke boot (as used here):
```bash
"$HOME/Library/Android/sdk/emulator/emulator" \
  -avd Medium_Phone_API_37.0 -no-window -no-audio -no-boot-anim &
"$ADB" wait-for-device
# poll until ready: "$ADB" shell getprop sys.boot_completed  -> 1
```

## Runtime permission ("Nearby devices")

On **API ≥ 33** the app requests `NEARBY_WIFI_DEVICES`, and on **API ≥ 36** it additionally
requests `ACCESS_LOCAL_NETWORK`, at launch **before** starting NSD, logging `permission_request`
→ `permission_granted`/`permission_denied`. The primary dialog is titled **"Nearby devices"** /
"Allow Music Share to find, connect to, and determine the signal strength of nearby WiFi devices?".

- **Granted** → multicast lock acquired, WS server is announced as `_musicshare._tcp`, browsing
  starts.
- **Denied** → a persistent red banner shows *"Discovery unavailable; manual connect still
  works"*. The WS server and **manual connect** remain fully functional — only mDNS browse/
  advertise is off. `NEARBY_WIFI_DEVICES` uses `neverForLocation` (no implicit location).

Grant it from a shell for testing:
```bash
"$ADB" shell pm grant com.musicshare.mvp android.permission.NEARBY_WIFI_DEVICES
```

### Why framework `requestPermissions` instead of the Activity Result API

The deliverable is **one external dependency** (`Java-WebSocket`). The Activity Result API lives
in `androidx.activity`, so adding it would break the single-dependency rule. The permission flow
therefore uses the framework `Activity.requestPermissions` / `onRequestPermissionsResult`. This
is an API-choice substitution forced by the dependency constraint; the contract-relevant logging
(`permission_request`/`granted`/`denied`) is identical.

## Local-network access (Android 16 / API 36–37)

The manifest declares `ACCESS_LOCAL_NETWORK` for **forward-compatibility**. Android 16's
local-network opt-in is documented to apply to apps targeting **API ≥ 36**; this app pins
`targetSdk 35`, so the design assumption is that it stays exempt (with `NEARBY_WIFI_DEVICES`
governing mDNS) and that raw Java-WebSocket sockets bypass the cleartext-traffic policy.

**Observed deviation on this environment (documented, not hidden):** the API-37 system image
enforced `ACCESS_LOCAL_NETWORK` at runtime *regardless of targetSdk 35* — the first `NsdManager
.registerService` call threw `SecurityException: Missing local network permission`. The app was
hardened so this can never crash it: `Discovery.register()`/`discover()` catch `SecurityException`
and log an `announce`/`discovery_start` **failure** (exactly the contract's "registration success
or a logged failure"). On the smoke run we granted it via `pm grant` and registration then
succeeded. The activity also requests `ACCESS_LOCAL_NETWORK` at runtime on API ≥ 36. On a device
where it truly is exempt (or once granted) nothing changes. If you raise `targetSdk` to 36+,
`ACCESS_LOCAL_NETWORK` becomes a first-class requirement.

Grant both for headless testing:
```bash
"$ADB" shell pm grant com.musicshare.mvp android.permission.NEARBY_WIFI_DEVICES
"$ADB" shell pm grant com.musicshare.mvp android.permission.ACCESS_LOCAL_NETWORK
```

## Multicast lock

`WifiManager.MulticastLock` ("mshare", reference-counted off) is acquired around all NSD
usage (register + browse) and released on shutdown / before re-acquire on network change.
Android drops incoming multicast/broadcast (mDNS relies on it) unless a lock is held, so
without it discovery silently finds nothing. Acquire/release and each `net_change`
(release → re-register → re-discover) are logged with the interface transport + IPv4 list.

### Emulator ↔ host mDNS (environment-specific)

Whether the headless emulator can see the host's real LAN mDNS (and be seen by it) is
**environment-specific — it is NOT guaranteed on every machine**. On *this* host it worked in
both directions during the live cross-platform test: multicast bridging into the emulator was
up, so the emulator's `NsdManager` discovered the macOS peer (`CrossMac`) over real LAN mDNS,
and the macOS host resolved the app's NSD advertisement (`Android_…local`). This is a property
of this host's network/AVD setup, not of the app, and must not be assumed elsewhere. See
Verification status below for the observed evidence.

## Intent hook — auto-dial on launch

Launching with `--es connect_target host:port` dials that address once ~2 s after start
(a normal `connect_attempt` log). This is a test hook for scripted cross-peer connect.
```bash
"$ADB" shell am start -n com.musicshare.mvp/.MainActivity \
  --es connect_target 192.168.1.20:46000
```
Manual connect from the UI's "host:port" field behaves identically (the entered side is the
caller, overriding the id tie-break).

## Logging & export

Every event is a JSON line (`ts` ISO-8601+ms UTC, `level`, `event`, `localId`, plus
`remoteId`/`remoteAddr`/`elapsedDiscoveryMs`/`elapsedConnMs`/`rttMs`/`error`/`detail`).
Each line goes to three sinks at once: **logcat** (tag `MShare`), an in-app scrolling ring
buffer (~4000 lines), and a JSONL session file under
`getExternalFilesDir(null)/logs/session-<id>.jsonl` (falls back to `filesDir/logs`).

UI buttons:
- **copy** — copies the in-app log to the clipboard.
- **share** — `ACTION_SEND` of the session log contents.

Dump from logcat:
```bash
"$ADB" logcat -s MShare:V
# pull the file:
"$ADB" shell run-as com.musicshare.mvp ls /sdcard/Android/data/com.musicshare.mvp/files/logs
```

## Manual UI

Local info block (id, name, platform, IPv4, WS port, discovery status) · editable device
name (re-announces TXT `name`) · color-coded peers list (IDLE/CONNECTING/CONNECTED/
RECONNECTING/GONE, discovery badge shown separately) · simulated playback controls
(play/pause/stop, track, position, **auto** toggle = 2 s ticks while playing, **broadcast
state** = manual seq bump + send) · test-message field · manual `host:port` connect. Foreground
only — no services. The post-handshake `state_update` snapshot reuses the current `seq`
(no increment), per the contract.

## Verification status

> Below reflects exactly what was observed on the headless `Medium_Phone_API_37.0` emulator in
> this environment (build, boot, and a live macOS↔Android cross-platform test). No claims beyond
> that; emulator↔host mDNS bridging and discovery latency are environment-specific (see above).

VERIFIED (build + emulator boot smoke in this environment):
- `./gradlew assembleDebug` → **BUILD SUCCESSFUL**; APK at
  `app/build/outputs/apk/debug/app-debug.apk`. Only 2 compiler warnings, both Android platform
  deprecations in `Discovery.kt` (`NsdManager.resolveService`, `NsdServiceInfo.host`), kept for
  minSdk-26 compatibility.
- App installs, launches, and **stays alive** (no `FATAL`/crash); PID present after launch.
- Startup logging observed verbatim:
  - `app_start` → `"detail":"platform=17 sdk=37 java=0","localAddr":"[10.0.2.15, 10.0.2.16]"`
  - `announce` → `"detail":"ws_server_listening port=43353"` (dynamic WS port)
  - `permission_granted` → `"detail":"discovery perms present"` (after `pm grant` of both perms)
  - `announce` → `"detail":"nsd_registered:musicshare-<id>","localAddr":"[...]:43353"` (**NSD registration SUCCESS**)
  - `discovery_start` → `"detail":"port=43353","elapsedDiscoveryMs":997"` (app_start→discovery-live measurement)
  - `announce` → `"multicast_lock_acquired:register"` and `:discover`
  - `net_change` → `"transport=available WIFI addrs=[10.0.2.15, 10.0.2.16]"`
- `connect_target` intent hook observed: `connect_attempt` (detail `manual_connect`) → `error`
  (ECONNREFUSED, remoteAddr present) → `connect_failed` → `reconnect_scheduled` with an
  **escalating, jittered backoff** (`1614ms attempt=1`, `2662ms attempt=2`, `5937ms attempt=3`,
  `11356ms attempt=4` ≈ 1.5/3/6/12 s ±20%).
- When `ACCESS_LOCAL_NETWORK` is absent the app does **not** crash: it logs a discovery failure
  and keeps the WS server + manual connect functional (banner path).

VERIFIED — cross-platform (this Android emulator ↔ the macOS `MusicShareMVP` peers, real LAN
mDNS bridged on this host, app id `3a78d9ea-…`, ws port `41645`):
- Discovery works over the emulator↔host bridge: the app's `NsdManager` browse resolved the
  macOS peer `CrossMac` (`eeee0000-…`) and `CrossMac2` (`11110000-…`); TXT `id`/`name` parsed.
- The tie-break → dial → `hello`/`hello_ack` → `connect_ok` path ran end-to-end against a real
  remote: app id `3a78… < eeee…` → `role=CALLER`, `connect_attempt detail=dial` → `connect_ok`
  (`elapsedConnMs≈532ms`).
- Keepalive RTT on a live socket: `ping_sent` → `pong_recv` → `rtt` every ~5 s, 26 pings / 26
  pongs / 26 RTT samples, `rttMs` min 3 / avg 11 / max 104 ms; `state_update` received
  (`state_recv`) right after handshake.
- **60 s false-expiry bug is fixed**: the healthy connection was kept alive past the 60 s window
  — observed continuous pongs for a **136.9 s** connected span (first `pong_recv`
  `17:19:07.070Z`, last `17:21:23.973Z`), crossing the `peer_found+60s` (`≈17:20:06Z`) expiry
  threshold with **no** `disconnect`/`peer_lost`/`expired`/`peer gone` and **no** reconnect churn.
- Periodic NSD re-discovery cycle confirmed: `announce detail=rediscovery_cycle` logged 4× at
  ~45.4 s intervals, each followed by `peer_found detail=re-announced` (this is also how the
  peer was first found this run — the initial browse found nothing and the 45 s re-browse
  resolved it, demonstrating the cycle rescues missed advertisements).
- `goodbye` contract §6 compliance: no out-of-contract goodbye `reason` is emitted (the
  expiry/service-removal path only logs `peer_lost`; the only `goodbye` is `app_shutdown` on
  clean shutdown).

Discovery **latency** is variable and environment-dependent: `app_start_to_first_peer` measured
**≈46.4 s** in the run above (first browse found nothing; the 45 s re-browse found both peers),
where an earlier run found a peer **≈1 s** after start. Treat the number as a property of this
host's multicast timing, not a fixed app figure.

NOT VERIFIED:
- True-silence expiry and `gone` on genuine OS service-removal / a peer actually leaving (only
  the *false*-expiry fix was exercised; no controlled removal was forced).
- Re-resolution of a peer that **restarts on a new port** (the `address_changed` log path),
  and a `gone` peer **reappearing** to resume its reconnect schedule — implemented but not
  exercised against a live restart in this session.
- `state_conflict` (out-of-order `seq`) and newest-wins replacement (close 4003) between two
  live peers.
- Positive `goodbye`/close-1000 actually delivered to a connected peer on app shutdown.
- Full UI interaction (buttons, clipboard copy, `ACTION_SEND`) — only launch + logcat were driven.
- Android 16 / API 36+ `ACCESS_LOCAL_NETWORK` *policy* semantics (the exemption was observed to
  differ on this image, as noted above).
