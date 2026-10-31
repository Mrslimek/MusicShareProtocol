#!/bin/bash
# Music Share MVP — macOS end-to-end smoke test (protocol PROTOCOL.md v1).
#
# Starts two headless instances on this machine:
#   Alpha  id aaaaaaaa-… (smaller → contract tie-break makes Alpha the caller)
#   Beta   id bbbbbbbb-… (larger  → waits as callee, unless discovery is blocked)
# Waits up to 60 s for a discovery-driven (mDNS) connection. If discovery is
# permission-blocked in this environment, falls back to a manual loopback
# connect (Beta --connect 127.0.0.1:<Alpha READY port>) and prints which path ran.
#
# Then asserts, with measured numbers, the contract items listed in PROTOCOL.md:
#   handshake, post-handshake state snapshots, smoke 'test' messages, keepalive
#   ping/pong + RTT, keepalive failure detection after a hung/dead peer, and
#   reconnection after restart. Prints PASS/FAIL per assertion, every measurement,
#   and tail -15 of both logs. Exit 0 = all green.
#
# Note on step (f): a local `kill -9` tears the TCP socket down immediately, so the
# surviving peer would log an instant `disconnect`, not `keepalive_timeout`. To test
# the keepalive path the script uses SIGSTOP, which simulates a peer that is dead
# to the application but silent on the wire (the case a dropped network creates).
set -u
cd "$(dirname "$0")/.."

swift build -q || { echo "BUILD FAILED"; exit 1; }
BIN=$(swift build --show-bin-path)/MusicShareMVP
IDA=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
IDB=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
PA=${IDA:0:8}; PB=${IDB:0:8}

pkill -9 -f "MusicShareMVP --headless --id $IDA" 2>/dev/null
pkill -9 -f "MusicShareMVP --headless --id $IDB" 2>/dev/null

WORK=$(mktemp -d /tmp/musicshare-smoke.XXXXXX)
LOGD="$WORK/logs"; mkdir -p "$LOGD"
: > "$WORK/pids"
cleanup() { [ -f "$WORK/pids" ] && while read -r p; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done < "$WORK/pids"; }
trap cleanup EXIT

log_for() { ls -t "$LOGD"/*"$1"*.jsonl 2>/dev/null | head -1; }   # $1 = id8, newest file wins
say()  { echo "[$(date +%H:%M:%S)] $*"; }
FAILS=0
check() { if [ "$2" = "0" ]; then echo "PASS  $1"; else echo "FAIL  $1"; FAILS=$((FAILS+1)); fi; }

start_instance() {  # $1 label $2 id $3 stdout-file [extra args…] -> echoes pid
    local label=$1 id=$2 out=$3; shift 3
    "$BIN" --headless --id "$id" --name "$label" --port 0 --log-dir "$LOGD" "$@" > "$out" 2>&1 &
    local pid=$!
    PIDS+=("$pid"); echo "$pid"
}

wait_ready() {  # $1 stdout-file $2 timeout-s -> echoes "<id> <port>"
    local out=$1 t=$2 w=0
    while [ $w -lt $((t * 2)) ]; do
        if grep -q '^READY ' "$out" 2>/dev/null; then
            grep '^READY ' "$out" | tail -1 | sed -E 's/^READY id=([^ ]+) port=([0-9]+).*$/\1 \2/'
            return 0
        fi
        sleep 0.5; w=$((w+1))
    done
    return 1
}

count_ok() {  # $1 log $2 remote id
    [ -n "$1" ] && grep "\"event\":\"connect_ok\".*\"remoteId\":\"$2\"" "$1" 2>/dev/null | wc -l | tr -d ' ' \
        || echo 0
}

iso_epoch() { python3 -c "import sys
from datetime import datetime, timezone
print(datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp())" "$1"; }

# ---------------- start both ----------------
say "starting Alpha (headless, id $PA)"
PID_A=$(start_instance Alpha "$IDA" "$WORK/alpha.out")
RD_A=$(wait_ready "$WORK/alpha.out" 30) || { say "ALPHA NEVER BECAME READY"; tail -20 "$WORK/alpha.out"; exit 1; }
PORT_A=${RD_A##* }
say "Alpha READY id=${RD_A%% *} port=$PORT_A"
say "starting Beta (headless, id $PB)"
PID_B=$(start_instance Beta "$IDB" "$WORK/beta.out")
wait_ready "$WORK/beta.out" 30 >/dev/null || { say "BETA NEVER BECAME READY"; tail -20 "$WORK/beta.out"; exit 1; }
say "Beta READY"

LA=$(log_for "$PA"); LB=$(log_for "$PB")

# ---------------- discovery-driven connect (or fallback) ----------------
MODE=discovery
say "waiting up to 60s for discovery-driven connect_ok on both sides"
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 60 ]; do
    if [ "$(count_ok "$LA" "$IDB")" -ge 1 ] && [ "$(count_ok "$LB" "$IDA")" -ge 1 ]; then break; fi
    if grep -lq '"event":"permission_denied"' "$LA" "$LB" 2>/dev/null; then
        say "discovery permission-blocked detected in logs"
        break
    fi
    sleep 1
done

if [ "$(count_ok "$LA" "$IDB")" -eq 0 ]; then
    MODE=manual
    say "FALLBACK (manual connect): relaunching Beta with --connect 127.0.0.1:$PORT_A"
    kill -9 "$PID_B" 2>/dev/null
    PID_B=$(start_instance Beta "$IDB" "$WORK/beta2.out" --connect "127.0.0.1:$PORT_A")
    wait_ready "$WORK/beta2.out" 30 >/dev/null || { say "FALLBACK BETA NOT READY"; tail -20 "$WORK/beta2.out"; exit 1; }
    LB=$(log_for "$PB")
    t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt 40 ]; do
        [ "$(count_ok "$LA" "$IDB")" -ge 1 ] && [ "$(count_ok "$LB" "$IDA")" -ge 1 ] && break
        sleep 1
    done
fi
LB=$(log_for "$PB")
say "connection path executed: $MODE"

# ---------------- post-handshake traffic (pings, states, smoke test msgs) ----------------
say "waiting up to 25s for >=2 pong_recv with rttMs per side + state_recv + smoke test messages"
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 25 ]; do
    pa=$(grep '"event":"pong_recv"' "$LA" | grep -c '"rttMs"')
    pb=$(grep '"event":"pong_recv"' "$LB" | grep -c '"rttMs"')
    if [ "$pa" -ge 2 ] && [ "$pb" -ge 2 ] \
       && grep -q '"event":"state_recv"' "$LA" && grep -q '"event":"state_recv"' "$LB" \
       && grep -q 'smoke-hello from Beta' "$LA" && grep -q 'smoke-hello from Alpha' "$LB"; then break; fi
    sleep 1
done

echo "--- assertions ---"
grep -qE '"event":"peer_found"|"event":"connect_attempt"' "$LA"; check "(a) Alpha: peer_found or connect_attempt" $?
grep -qE '"event":"peer_found"|"event":"connect_attempt"' "$LB"; check "(a) Beta:  peer_found or connect_attempt" $?
[ "$(count_ok "$LA" "$IDB")" -ge 1 ]; check "(b) Alpha connect_ok(remoteId=Beta)" $?
[ "$(count_ok "$LB" "$IDA")" -ge 1 ]; check "(b) Beta  connect_ok(remoteId=Alpha)" $?
pa=$(grep '"event":"pong_recv"' "$LA" | grep -c '"rttMs"'); pb=$(grep '"event":"pong_recv"' "$LB" | grep -c '"rttMs"')
[ "$pa" -ge 2 ] && [ "$pb" -ge 2 ]; check "(c) pong_recv with rttMs >=2 each side (alpha=$pa beta=$pb)" $?
grep -q '"event":"state_recv"' "$LA" && grep -q '"event":"state_recv"' "$LB"; check "(d) state_recv on both sides" $?
grep -q 'smoke-hello from Beta' "$LA" && grep -q 'smoke-hello from Alpha' "$LB"; check "(e) smoke 'test' msg_recv on both sides" $?

# ---------------- (f) keepalive failure detection: hang Beta ----------------
say "SIGSTOP Beta (hung/silent peer; see header note on why not SIGKILL)"
STOP_TS=$(date +%s)
kill -STOP "$PID_B"
say "waiting up to 30s for Alpha keepalive_timeout for Beta"
t0=$(date +%s); KA_LINE=""
while [ $(( $(date +%s) - t0 )) -lt 30 ]; do
    KA_LINE=$(grep '"event":"keepalive_timeout"' "$LA" | grep "$IDB" | tail -1)
    [ -n "$KA_LINE" ] && break
    sleep 1
done
KA_LAT=n/a; KA_INTERNAL=n/a
if [ -n "$KA_LINE" ]; then
    KA_TS=$(echo "$KA_LINE" | sed -E 's/.*"ts":"([^"]+)".*/\1/')
    KA_LAT=$(python3 -c "print(round($(iso_epoch "$KA_TS") - $STOP_TS, 1))")
    KA_INTERNAL=$(echo "$KA_LINE" | sed -nE 's/.*"lastPongToTimeoutMs":([0-9-]+).*/\1/p')
    python3 -c "import sys; sys.exit(0 if $KA_LAT <= 25 else 1)"
    check "(f) keepalive_timeout <=25s after Beta hang (wall=${KA_LAT}s, internal lastPongToTimeout=${KA_INTERNAL:-n/a}ms)" $?
else
    check "(f) keepalive_timeout appeared after Beta hang" 1
fi

# ---------------- (g) reconnection: restart Beta ----------------
say "restarting Beta"
OK_A_BASE=$(count_ok "$LA" "$IDB")
kill -9 "$PID_B" 2>/dev/null
OUT_G="$WORK/beta3.out"
RESTART_TS=$(date +%s)
if [ "$MODE" = "manual" ]; then
    PID_B=$(start_instance Beta "$IDB" "$OUT_G" --connect "127.0.0.1:$PORT_A")
else
    PID_B=$(start_instance Beta "$IDB" "$OUT_G")
fi
wait_ready "$OUT_G" 30 >/dev/null || { say "BETA RESTART NOT READY"; tail -20 "$OUT_G"; exit 1; }
RECON=timeout
LB=$(log_for "$PB")
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 90 ]; do
    if [ "$(count_ok "$LA" "$IDB")" -ge $((OK_A_BASE + 1)) ] && [ "$(count_ok "$LB" "$IDA")" -ge 1 ]; then
        RECON=$(( $(date +%s) - RESTART_TS ))
        break
    fi
    sleep 1
done
if [ "$RECON" != "timeout" ]; then
    python3 -c "import sys; sys.exit(0 if $RECON <= 90 else 1)"
    check "(g) reconnect after restart: connect_ok both sides in ${RECON}s (<=90s)" $?
else
    check "(g) reconnect after restart (no connect_ok within 90s)" 1
fi

# ---------------- measurements ----------------
echo "--- measurements (mode: $MODE) ---"
python3 - "$LA" "$LB" "$IDA" "$IDB" <<'PY'
import json, sys

def rows(p):
    out = []
    try:
        for line in open(p, errors="replace"):
            line = line.strip()
            if line.startswith("{"):
                try: out.append(json.loads(line))
                except Exception: pass
    except OSError:
        print(f"  (cannot read {p})")
    return out

def first(rs, ev, rid=None):
    for r in rs:
        if r.get("event") == ev and (rid is None or r.get("remoteId") == rid):
            return r
    return None

def epoch(ts):
    from datetime import datetime
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()

A, B = rows(sys.argv[1]), rows(sys.argv[2])
ida, idb = sys.argv[3], sys.argv[4]
for label, rs, peer in (("Alpha", A, idb), ("Beta", B, ida)):
    if not rs:
        print(f"{label}: no log rows")
        continue
    app = first(rs, "app_start")
    live = next((r for r in rs if r.get("event") == "discovery_start" and "appStartToLiveMs" in (r.get("detail") or "")), None)
    pf = first(rs, "peer_found", peer)
    ca = first(rs, "connect_attempt", peer)
    co = first(rs, "connect_ok", peer)
    rtts = [r["rttMs"] for r in rs if r.get("event") == "pong_recv" and "rttMs" in r]
    line = f"{label}:"
    if app and live: line += f" app_start->discovery_live={live['detail'].split('appStartToLiveMs=')[1].rstrip(')')}ms"
    if app and pf:  line += f" app_start->first_peer_found={int((epoch(pf['ts'])-epoch(app['ts']))*1000)}ms"
    if pf and ca and "foundToAttemptMs" in ca: line += f" peer_found->connect_attempt={ca['foundToAttemptMs']}ms"
    if ca and co and "elapsedConnMs" in co: line += f" connect_attempt->connect_ok={co['elapsedConnMs']}ms"
    if rtts: line += f" RTT_ms n={len(rtts)} min={min(rtts)} max={max(rtts)}"
    print(line)
PY
echo "keepalive detection latency: ${KA_LAT}s after SIGSTOP (app-internal lastPongToTimeoutMs=${KA_INTERNAL:-n/a})"
echo "reconnect (restart->connect_ok both sides): ${RECON}s"

# ---------------- cleanup + report ----------------
say "sending SIGTERM to both (expect goodbye + app_stop, exit 0)"
kill -TERM "$PID_A" "$PID_B" 2>/dev/null
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 10 ]; do
    kill -0 "$PID_A" 2>/dev/null || kill -0 "$PID_B" 2>/dev/null || break
    sleep 0.5
done
LA=$(log_for "$PA"); LB=$(log_for "$PB")
grep -q '"event":"app_stop"' "$LA"; check "(h1) Alpha app_stop on SIGTERM" $?
grep -q '"event":"app_stop"' "$LB"; check "(h1) Beta  app_stop on SIGTERM" $?
grep -q '"event":"goodbye"' "$LB" || grep -q '"event":"msg_recv".*goodbye' "$LA" || grep -q 'goodbye' "$LA"
check "(h2) goodbye visible on shutdown path (sender or receiver)" $?

echo "=== tail Alpha ($(basename "${LA:-none}")) ==="; tail -15 "${LA:-/dev/null}"
echo "=== tail Beta ($(basename "${LB:-none}")) ===";  tail -15 "${LB:-/dev/null}"
echo
if [ "$FAILS" -eq 0 ]; then echo "RESULT: PASS (mode=$MODE)"; exit 0
else echo "RESULT: FAIL ($FAILS failed checks, mode=$MODE)"; exit 1; fi
