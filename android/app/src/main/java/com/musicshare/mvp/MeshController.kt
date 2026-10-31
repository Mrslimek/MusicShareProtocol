package com.musicshare.mvp

import android.content.Context
import android.os.Build
import org.java_websocket.WebSocket
import org.java_websocket.client.WebSocketClient
import org.java_websocket.exceptions.WebsocketNotConnectedException
import org.java_websocket.handshake.ClientHandshake
import org.java_websocket.handshake.ServerHandshake
import org.java_websocket.server.WebSocketServer
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.URI
import java.util.IdentityHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

enum class ConnState { IDLE, CONNECTING, CONNECTED, CLOSING, RECONNECTING, GONE }
enum class Role { CALLER, CALLEE }
enum class Cause { SUPERSEDED, SHUTDOWN, KEEPALIVE, HANDSHAKE_TIMEOUT, REMOTE, ERROR }

/** One peer: discovery presence + the single live connection + protocol bookkeeping. */
class Peer(val addrKey: String) {
    var id: String? = null
    var name = ""
    var platform = ""
    var host = ""
    var port = 0
    var role = Role.CALLEE
    var manual = false
    var state = ConnState.IDLE
    var ws: WebSocket? = null

    var openAtMs = 0L
    var dialAtMs = 0L
    var foundAtMs = 0L
    var lastSeenAt = 0L
    var discovered = false
    var reconnectIdx = 0
    var nextReconnectAt = 0L
    var closeCause: Cause? = null
    var handshakeTimer: ScheduledFuture<*>? = null
    var connectGen = 0   // incremented each dial; MClient carries its gen so a stale/abandoned
                         // socket's onOpen/onClose/onMessage are ignored (P2 dial-timeout safety)

    var lastSeq = -1L
    var lastTrack = ""
    var lastStatus = ""
    var lastPosition = 0.0
    var lastStateRecvAt = 0L

    var pingId: String? = null
    var pingSentLocal = 0L
    var lastPingAt = 0L
    var lastPongAt = 0L

    val seen = ArrayDeque<String>()
    val seenSet = HashSet<String>()
    fun key() = id ?: addrKey
}

/**
 * The networking core. Owns the WS server, the discovery browser, the per-peer
 * state machine (handshake, keepalive, reconnect, newest-wins replacement) and the
 * simulated playback state. Kept independent of the Activity (UI drives it via the
 * public methods; it drives the UI via `refresh`).
 */
class MeshController(context: Context, private val store: DeviceStore) {

    interface Listener { fun onPeersChanged() }
    var listener: Listener? = null

    private val appContext = context.applicationContext
    private val lock = Any()
    private val peers = LinkedHashMap<String, Peer>()
    private val socketToPeer = IdentityHashMap<WebSocket, Peer>()
    private val seenEver = HashSet<String>()   // ids we have ever discovered (to tell new vs reappeared)
    private val sched = Executors.newScheduledThreadPool(3)   // tick + a blocking dial (connectBlocking) concurrently

    private val now get() = System.currentTimeMillis()
    private val myId get() = store.id
    private val myName get() = store.name

    var serverPort = 0
        private set
    var discoveryLive = false
        private set

    // Simulated playback state.
    @Volatile var track = "Fake Track 01"
    @Volatile var status = "stopped"          // playing | paused | stopped
    @Volatile var positionSec = 0.0
    @Volatile var seq = 1L                     // starts at 1 per run, +1 per change
    @Volatile var autoBroadcast = false
    private var lastAutoAt = 0L

    private val appStartMs = System.currentTimeMillis()
    private var firstPeerFoundLogged = false
    private var server: MServer? = null

    // ---- startup logging -------------------------------------------------

    fun logStartup() {
        val jv = System.getProperty("java.version") ?: "?"
        Jsonl.event("app_start", "info",
            "detail" to "platform=${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT} java=$jv",
            "localAddr" to ipv4().toString())
    }

    fun ipv4(): List<String> = Discovery.ipv4()
    fun localId(): String = store.id
    fun localName(): String = store.name

    /** Network changed: log, drop+reacquire multicast lock, re-announce, re-discover. */
    fun onNetChange(transport: String) {
        val detail = "transport=$transport addrs=${ipv4()}"
        Jsonl.event("net_change", "info", "localAddr" to ipv4().toString(), "detail" to detail)
        if (discoveryLive) {
            discovery.releaseLock("net_change")
            discovery.register(myName, serverPort)   // re-acquires lock + re-announces
        }
    }

    // ---- WS server -------------------------------------------------------

    /** Bind an ephemeral port, start the server, return the port used by NSD. */
    fun startServer(): Int {
        val freePort = try {
            ServerSocket(0).use { it.localPort }
        } catch (e: Exception) {
            Jsonl.event("error", "error", "error" to e.message)
            46000 + (Math.random() * 10000).toInt()
        }
        server = MServer(freePort)
        server!!.start()
        serverPort = freePort
        Jsonl.event("announce", "info", "detail" to "ws_server_listening port=$freePort")
        return freePort
    }

    private inner class MServer(port: Int) : WebSocketServer(InetSocketAddress(port)) {
        init {
            isReuseAddr = true
            setConnectionLostTimeout(15)   // TCP dead-connection safety net
        }

        override fun onStart() {
            Jsonl.event("announce", "debug", "detail" to "ws_server_started")
        }

        override fun onOpen(conn: WebSocket, handshake: ClientHandshake) {
            val rs = conn.remoteSocketAddress
            val addrKey = "inbound:${rs?.hostString ?: "?"}"
            val peer = Peer(addrKey).apply {
                host = rs?.address?.hostAddress ?: "?"
                ws = conn
                role = Role.CALLEE
                state = ConnState.CONNECTING
                openAtMs = now
            }
            synchronized(lock) { peers[addrKey] = peer; socketToPeer[conn] = peer }
            Jsonl.event("connect_attempt", "info", "remoteAddr" to rs?.toString(),
                "detail" to "inbound_accepted")
            startHandshakeTimer(peer)   // callee waits for `hello`
        }

        override fun onMessage(conn: WebSocket, message: String) {
            val peer = socketToPeer[conn] ?: return
            handle(peer, conn, message)
        }

        override fun onClose(conn: WebSocket, code: Int, reason: String, remote: Boolean) {
            val peer = socketToPeer.remove(conn) ?: return
            Jsonl.event("disconnect", "info", "remoteId" to peer.id,
                "remoteAddr" to conn.remoteSocketAddress?.toString(),
                "detail" to "onClose code=$code reason=$reason remote=$remote")
            onSocketClosed(peer, conn, code)
        }

        override fun onError(conn: WebSocket?, ex: Exception) {
            val peer = conn?.let { socketToPeer[it] }
            Jsonl.event("error", "error",
                "remoteId" to peer?.id,
                "remoteAddr" to conn?.remoteSocketAddress?.toString(),
                "error" to ex.message,
                "detail" to "server onError ${ex.javaClass.simpleName}")
        }
    }

    // ---- WS client (we dial) --------------------------------------------

    private inner class MClient(uri: URI, val peer: Peer, val gen: Int) : WebSocketClient(uri) {
        init { setConnectionLostTimeout(15) }

        // A dial whose gen was abandoned (connect timeout) must not hijack the peer if its
        // socket opens late (frozen peer that unfroze just past the timeout).
        private fun stale(): Boolean = peer.connectGen != gen

        override fun onOpen(handshake: ServerHandshake?) {
            if (stale()) { try { close() } catch (_: Exception) {}; return }
            peer.openAtMs = now
            synchronized(lock) {
                if (peer.ws != null && peer.ws !== this) supersedeSocket(peer, peer.ws!!, "superseded by redial")
                peer.ws = this
                peer.closeCause = null
                socketToPeerPut(this, peer)
            }
            sendHello(peer)
            startHandshakeTimer(peer)   // caller waits for `hello_ack`
        }

        override fun onMessage(message: String) {
            if (stale()) return
            handle(peer, this, message)
        }

        override fun onClose(code: Int, reason: String, remote: Boolean) {
            if (stale()) return
            Jsonl.event("disconnect", "info", "remoteId" to peer.id,
                "remoteAddr" to "${peer.host}:${peer.port}",
                "detail" to "onClose code=$code reason=$reason remote=$remote")
            onSocketClosed(peer, this, code)
        }

        override fun onError(ex: Exception?) {
            if (stale()) return
            Jsonl.event("error", "error", "remoteId" to peer.id,
                "remoteAddr" to "${peer.host}:${peer.port}",
                "error" to ex?.message, "detail" to "client onError ${ex?.javaClass?.simpleName}")
        }
    }

    // ---- dial / connect --------------------------------------------------

    /** Automatic dial after discovery: apply the smaller-id-dials tie-break. */
    fun onPeerFound(id: String, name: String, host: String, port: Int, elapsedDiscoveryMs: Long) {
        val caller = myId.compareTo(id) < 0
        var addrChanged = false
        var tag = "new peer"
        val peer = synchronized(lock) {
            val existing = peers[id]
            val wasEverKnown = seenEver.contains(id)
            seenEver.add(id)
            addrChanged = existing != null && existing.host.isNotEmpty() &&
                (existing.host != host || existing.port != port)
            tag = when {
                addrChanged -> "address_changed"
                existing != null -> "re-announced"
                wasEverKnown -> "reappeared; reconnect resumed"   // was `gone` (entry removed), back
                else -> "new peer"
            }
            val p = existing ?: Peer(id).also { peers[id] = it }
            p.id = id; p.name = name; p.host = host; p.port = port
            p.discovered = true; p.lastSeenAt = now; p.foundAtMs = now
            p
        }
        if (!firstPeerFoundLogged) {
            firstPeerFoundLogged = true
            Jsonl.event("peer_found", "info", "remoteId" to id,
                "elapsedDiscoveryMs" to elapsedDiscoveryMs,
                "detail" to "app_start_to_first_peer=${now - appStartMs}ms name=$name")
        } else if (addrChanged) {   // re-resolve an already-known peer whose host:port moved (§5)
            Jsonl.event("peer_found", "info", "remoteId" to id, "remoteAddr" to "$host:$port",
                "detail" to "address_changed name=$name")
        } else {
            Jsonl.event("peer_found", "debug", "remoteId" to id,
                "elapsedDiscoveryMs" to elapsedDiscoveryMs, "detail" to "$tag name=$name")
        }
        // Caller role means we initiate; re-resolution re-dials an idle/reconnecting peer (and a
        // peer that reappeared after going `gone` — its entry was recreated fresh, so this resumes
        // the reconnect schedule per contract §5). Never start a second dial while one is already
        // in flight (CONNECTING) or a socket is already live (CONNECTED): the transient discovery
        // flap used to recreate the peer and fire a parallel dial → dual connect_ok → 4003 supersede.
        if (caller && peer.state != ConnState.CONNECTING && peer.state != ConnState.CONNECTED
            && peer.state != ConnState.CLOSING) {
            peer.role = Role.CALLER
            dial(peer, elapsedDiscoveryMs)
        }
    }

    /** Manual connect (UI / intent). Whoever entered the address is the caller. */
    fun dialManual(host: String, port: Int) {
        val addrKey = "manual:$host:$port"
        val peer = synchronized(lock) {
            peers.values.firstOrNull { it.host == host && it.port == port }
                ?: Peer(addrKey).apply { this.host = host; this.port = port }
                .also { peers[addrKey] = it }
        }
        peer.manual = true
        peer.role = Role.CALLER
        Jsonl.event("connect_attempt", "info", "remoteAddr" to "$host:$port",
            "detail" to "manual_connect")
        dial(peer, null)
    }

    private fun dial(peer: Peer, elapsedDiscoveryMs: Long?) {
        var gen = 0
        val oldWs: WebSocket?
        synchronized(lock) {
            if (peer.state == ConnState.CONNECTING || peer.state == ConnState.CONNECTED) return
            oldWs = peer.ws
            peer.ws = null
            peer.state = ConnState.CONNECTING
            peer.dialAtMs = now
            peer.closeCause = null
            gen = ++peer.connectGen
        }
        oldWs?.let { supersedeSocket(peer, it, "superseded by new dial") }
        if (elapsedDiscoveryMs != null)
            Jsonl.event("connect_attempt", "info", "remoteId" to peer.id,
                "remoteAddr" to "${peer.host}:${peer.port}",
                "elapsedDiscoveryMs" to elapsedDiscoveryMs, "detail" to "dial")
        // Bound the HTTP-upgrade wait so a peer that accepts TCP but never returns 101 (frozen
        // socket sitting in the kernel backlog) cannot park this dial forever: the handshake timer
        // only arms at onOpen, so without an explicit connect timeout a dead-but-accepting peer
        // stalls the reconnect ladder (PROTOCOL.md §3/§5). connectBlocking runs on `sched`, never
        // on the caller (main/tick) thread, so it cannot block the UI or a concurrent tick.
        val client = MClient(URI("ws://${peer.host}:${peer.port}"), peer, gen)
        sched.execute {
            try {
                if (!client.connectBlocking(Protocol.HANDSHAKE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                    failDial(peer, client, gen,
                        "no HTTP upgrade within ${Protocol.HANDSHAKE_TIMEOUT_MS}ms (dial timeout)")
                }
            } catch (e: Exception) {
                failDial(peer, client, gen, e.message ?: "dial failed")
            }
        }
    }

    /** A dial whose upgrade never completed within the timeout. Schedules the ladder ONLY if the
     *  socket still never opened for this attempt — a late onOpen (peer recovered) or a newer dial
     *  supersedes this, in which case the normal path owns the peer. */
    private fun failDial(peer: Peer, client: WebSocketClient, gen: Int, detail: String) {
        val owned = synchronized(lock) {
            if (peer.connectGen == gen && peer.ws == null && peer.state == ConnState.CONNECTING) {
                peer.connectGen += 1                 // abandon this socket; its late events go stale
                true
            } else false
        }
        if (!owned) return
        try { client.close() } catch (e: Exception) {
            Jsonl.event("error", "debug", "detail" to "abandon dial close ${e.message}")
        }
        Jsonl.event("connect_failed", "warn", "remoteId" to peer.id,
            "remoteAddr" to "${peer.host}:${peer.port}",
            "elapsedConnMs" to (now - peer.dialAtMs), "detail" to detail)
        beginReconnect(peer)                         // escalates the backoff ladder
    }

    // ---- handshake -------------------------------------------------------

    private fun sendHello(peer: Peer) {
        val extra = JSONObject().put("name", myName).put("platform", Protocol.PLATFORM)
            .put("appVersion", Protocol.APP_VERSION)
        val helloId = Protocol.newId()
        peer.ws?.send(Protocol.envelope("hello", myId, extra, id = helloId))
        Jsonl.event("handshake_sent", "info", "remoteId" to peer.id, "detail" to "hello")
    }

    private fun sendHelloAck(peer: Peer, replyTo: String) {
        val extra = JSONObject().put("name", myName).put("platform", Protocol.PLATFORM)
            .put("appVersion", Protocol.APP_VERSION)
        peer.ws?.send(Protocol.envelope("hello_ack", myId, extra, replyTo = replyTo))
        Jsonl.event("handshake_ack", "info", "remoteId" to peer.id, "detail" to "hello_ack_sent")
    }

    private fun startHandshakeTimer(peer: Peer) {
        peer.handshakeTimer?.cancel(false)
        peer.handshakeTimer = sched.schedule({
            synchronized(lock) {
                if (peer.state == ConnState.CONNECTING && peer.ws != null) {
                    peer.closeCause = Cause.HANDSHAKE_TIMEOUT
                    Jsonl.event("handshake_timeout", "warn", "remoteId" to peer.id,
                        "remoteAddr" to "${peer.host}:${peer.port}",
                        "detail" to "role=${peer.role} elapsed=${now - peer.openAtMs}ms")
                    if (peer.role == Role.CALLER)
                        Jsonl.event("connect_timeout", "warn", "remoteId" to peer.id,
                            "detail" to "failed (handshake timeout)")
                    safeClose(peer.ws!!, Protocol.CLOSE_HANDSHAKE, "handshake timeout")
                }
            }
        }, Protocol.HANDSHAKE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
    }

    private fun completeHandshake(peer: Peer) {
        synchronized(lock) {
            if (peer.state == ConnState.CONNECTED) return
            peer.state = ConnState.CONNECTED
            peer.reconnectIdx = 0
            peer.lastPongAt = now; peer.lastPingAt = 0; peer.pingId = null
        }
        val elapsed = now - (if (peer.dialAtMs > 0) peer.dialAtMs else peer.openAtMs)
        Jsonl.event("connect_ok", "info", "remoteId" to peer.id,
            "remoteAddr" to "${peer.host}:${peer.port}",
            "elapsedConnMs" to elapsed, "detail" to "handshake complete role=${peer.role}")
        sendStateTo(peer, increment = false)   // fresh snapshot, same seq
    }

    // ---- message handling ------------------------------------------------

    private fun handle(peer: Peer, ws: WebSocket, text: String) {
        val m = Protocol.parse(text)
        if (m == null) {
            Jsonl.event("message_malformed", "warn", "remoteId" to peer.id, "detail" to "not_json")
            return
        }
        Protocol.malformed(m)?.let {
            Jsonl.event("message_malformed", "warn", "remoteId" to peer.id, "detail" to "missing:$it")
            return
        }
        if (seenDuplicate(peer, m.id)) {
            Jsonl.event("message_duplicate", "debug", "remoteId" to peer.id, "detail" to "id=${m.id}")
            return
        }
        rememberId(peer, m.id)
        // Liveness evidence (PROTOCOL.md §2): any non-duplicate message from this peer — pings/
        // pongs arrive every 5 s — refreshes lastSeenAt so a answering peer is never expired.
        peer.lastSeenAt = now
        Jsonl.event("msg_recv", "debug", "remoteId" to m.from, "detail" to "type=${m.type}")
        try {
            when (m.type) {
                "hello" -> onHello(peer, ws, m)
                "hello_ack" -> onHelloAck(peer, m)
                "ping" -> onPing(peer, m)
                "pong" -> onPong(peer, m)
                "state_update" -> onStateUpdate(peer, m)
                "test" -> onTest(peer, m)
                "goodbye" -> onGoodbye(peer, m)
                else -> Jsonl.event("message_unknown", "warn", "remoteId" to peer.id, "detail" to m.type)
            }
        } catch (e: Exception) {
            Jsonl.event("message_malformed", "error", "remoteId" to peer.id,
                "detail" to "dispatch ${m.type}: ${e.message}")
        }
    }

    private fun onHello(peer: Peer, ws: WebSocket, m: Protocol.Msg) {
        val name = m.obj.optString("name")
        val platform = m.obj.optString("platform")
        attachId(peer, m.from, name, platform)
        sendHelloAck(peer, m.id)
        peer.handshakeTimer?.cancel(false)
        completeHandshake(peer)
    }

    private fun onHelloAck(peer: Peer, m: Protocol.Msg) {
        if (m.replyTo == null) {
            Jsonl.event("message_malformed", "warn", "remoteId" to peer.id, "detail" to "hello_ack_no_replyTo")
            return
        }
        attachId(peer, m.from, m.obj.optString("name"), m.obj.optString("platform"))
        Jsonl.event("handshake_ack", "info", "remoteId" to peer.id, "detail" to "hello_ack_received")
        peer.handshakeTimer?.cancel(false)
        completeHandshake(peer)
    }

    private fun onPing(peer: Peer, m: Protocol.Msg) {
        peer.ws?.send(Protocol.envelope("pong", myId, replyTo = m.id))
        Jsonl.event("msg_sent", "debug", "remoteId" to peer.id, "detail" to "pong")
    }

    private fun onPong(peer: Peer, m: Protocol.Msg) {
        val pingId = m.replyTo
        if (pingId == null || pingId != peer.pingId) return   // stale/unsolicited
        val recvLocal = now
        val rttLocal = recvLocal - peer.pingSentLocal
        val remote = m.ts - peer.pingSentLocal     // cross-clock, per contract note
        peer.pingId = null
        peer.lastPongAt = recvLocal
        Jsonl.event("pong_recv", "debug", "remoteId" to peer.id, "detail" to "replyTo=$pingId")
        Jsonl.event("rtt", "info", "remoteId" to peer.id, "rttMs" to rttLocal,
            "detail" to "local_send_to_recv=${rttLocal}ms pong.ts-ping.ts=${remote}ms")
    }

    private fun onStateUpdate(peer: Peer, m: Protocol.Msg) {
        val s = m.obj.optString("status")
        val trk = m.obj.optString("track")
        if (s !in setOf("playing", "paused", "stopped") || !m.obj.has("seq") || !m.obj.has("positionSec")) {
            Jsonl.event("message_malformed", "warn", "remoteId" to peer.id, "detail" to "state_update")
            return
        }
        val arrivingSeq = m.obj.optLong("seq")
        val recvAt = now
        if (peer.lastSeq >= 0 && arrivingSeq <= peer.lastSeq) {
            Jsonl.event("state_conflict", "warn", "remoteId" to peer.id,
                "detail" to "arriving_seq=$arrivingSeq last_seq=${peer.lastSeq} " +
                    "recv_last=${peer.lastStateRecvAt} recv_this=$recvAt")
        }
        peer.lastSeq = arrivingSeq
        peer.lastStatus = s; peer.lastTrack = trk
        peer.lastPosition = m.obj.optDouble("positionSec")
        peer.lastStateRecvAt = recvAt
        Jsonl.event("state_recv", "info", "remoteId" to peer.id, "rttMs" to null,
            "detail" to "track=$trk status=$s pos=${peer.lastPosition} seq=$arrivingSeq")
        listener?.onPeersChanged()
    }

    private fun onTest(peer: Peer, m: Protocol.Msg) {
        Jsonl.event("msg_recv", "info", "remoteId" to peer.id, "detail" to "test text=${m.obj.optString("text")}")
    }

    private fun onGoodbye(peer: Peer, m: Protocol.Msg) {
        val reason = m.obj.optString("reason")
        Jsonl.event("disconnect", "info", "remoteId" to peer.id, "detail" to "goodbye reason=$reason")
        // Contract §5/§6: an intentional goodbye (app_shutdown/user_close) means the peer is gone —
        // reconnecting to it violates "stop when the peer is gone". markGone sets closeCause=SHUTDOWN
        // + state=GONE + removes it from the map BEFORE the socket close arrives (goodbye is processed
        // on the read thread ahead of the close frame), so onSocketClosed returns early and cannot
        // reschedule. No goodbye reply, no dial. `reason` is only used as a clean wire close token.
        if (reason == "app_shutdown" || reason == "user_close") {
            markGone(peer, "goodbye_received reason=$reason", wireReason = reason)
        } else {
            synchronized(lock) { peer.closeCause = Cause.REMOTE }
        }
    }

    // ---- identity / newest-wins replacement ------------------------------

    /** Learn a peer's id from hello/hello_ack and enforce one-connection-per-id. */
    private fun attachId(peer: Peer, id: String, name: String, platform: String) {
        if (id.isEmpty() || id == myId) return
        synchronized(lock) {
            peer.id = id
            if (name.isNotEmpty()) peer.name = name
            if (platform.isNotEmpty()) peer.platform = platform
            val other = peers[id]
            if (other != null && other !== peer) {            // newest wins: drop the old entry's socket
                other.ws?.let { supersedeSocketLocked(other, it, "superseded by newer connection") }
                peers.remove(other.key())
            }
            // rekey under the id map
            peers.remove(peer.addrKey)
            peers[id] = peer
        }
    }

    private fun supersedeSocket(peer: Peer, ws: WebSocket, reason: String) {
        synchronized(lock) { supersedeSocketLocked(peer, ws, reason) }
    }

    private fun supersedeSocketLocked(peer: Peer, ws: WebSocket, reason: String) {
        Jsonl.event("disconnect", "info", "remoteId" to peer.id,
            "detail" to "superseded:$reason code=${Protocol.CLOSE_SUPERSEDED}")
        safeClose(ws, Protocol.CLOSE_SUPERSEDED, "superseded")
    }

    // ---- socket close / reconnect ---------------------------------------

    private fun onSocketClosed(peer: Peer, ws: WebSocket, code: Int) {
        val cause: Cause = synchronized(lock) {
            // Only ignore a close when a *different* live socket already owns the peer
            // (supersession). A connect that failed before onOpen leaves peer.ws == null and
            // must be handled, or the peer would be stuck in CONNECTING forever.
            if (peer.ws != null && peer.ws !== ws) return
            peer.ws = null
            socketToPeer.remove(ws)
            peer.closeCause ?: if (peer.role == Role.CALLER || peer.manual) Cause.ERROR else Cause.REMOTE
        }
        peer.handshakeTimer?.cancel(false)
        val caller = peer.role == Role.CALLER || peer.manual
        when (cause) {
            Cause.SHUTDOWN, Cause.SUPERSEDED -> return
            Cause.KEEPALIVE -> {
                Jsonl.event("keepalive_timeout", "warn", "remoteId" to peer.id,
                    "detail" to "unreachable (keepalive timeout; remote state unknown) " +
                        "last_pong_to_detect=${peer.lastPongAt.let { if (it > 0) now - it else -1 }}ms")
                if (caller && (peer.discovered || peer.manual)) beginReconnect(peer) else setIdleOrRemove(peer)
            }
            Cause.HANDSHAKE_TIMEOUT -> {
                if (caller) beginReconnect(peer) else setIdleOrRemove(peer)
            }
            else -> {                                   // REMOTE / ERROR
                if (cause == Cause.ERROR) {
                    // 1006 (abnormal, no close frame) / 1001 (going away) are what Java-WebSocket's
                    // LostTCPPinger reports when it detects a dead link first. Label them as a
                    // keepalive loss (remote state unknown) rather than "unexpected failure" — the
                    // reconnect behaviour below is identical either way.
                    val detail = if (code == 1006 || code == 1001)
                        "keepalive lost (library close code=$code; remote state unknown)"
                        else "connection failed/closed unexpectedly"
                    Jsonl.event("connect_failed", "warn", "remoteId" to peer.id,
                        "remoteAddr" to "${peer.host}:${peer.port}", "detail" to detail)
                }
                if (caller && (peer.discovered || peer.manual)) beginReconnect(peer) else setIdleOrRemove(peer)
            }
        }
        listener?.onPeersChanged()
    }

    private fun setIdleOrRemove(peer: Peer) {
        synchronized(lock) {
            if (peer.discovered) peer.state = ConnState.IDLE
            else if (peer.manual) peer.state = ConnState.RECONNECTING.also { scheduleReconnect(peer) }
            else peers.remove(peer.key())
        }
    }

    private fun beginReconnect(peer: Peer) {
        // The 1.5→30 s ladder escalates across consecutive failures; the index is reset
        // ONLY on a successful handshake (completeHandshake), never here.
        synchronized(lock) {
            peer.state = ConnState.RECONNECTING
            scheduleReconnect(peer)
        }
    }

    private fun scheduleReconnect(peer: Peer) {
        val idx = peer.reconnectIdx.coerceAtMost(Protocol.BACKOFF_MS.size - 1)
        val base = Protocol.BACKOFF_MS[idx].toDouble()
        val delay = (base * (1 + (Math.random() * 2 - 1) * Protocol.JITTER)).toLong()
        peer.nextReconnectAt = now + delay
        peer.reconnectIdx = (peer.reconnectIdx + 1).coerceAtMost(Protocol.BACKOFF_MS.size - 1)
        Jsonl.event("reconnect_scheduled", "info", "remoteId" to peer.id,
            "detail" to "in ${delay}ms attempt=${peer.reconnectIdx}")
    }

    // ---- keepalive / periodic tick (1 s) --------------------------------

    private fun tick() {
        val list = synchronized(lock) { peers.values.toList() }
        val t = now
        for (peer in list) {
            val ws = peer.ws
            if (peer.state == ConnState.CONNECTED && ws != null) {
                if (t - peer.lastPingAt >= Protocol.PING_INTERVAL_MS) sendPing(peer)
                // Failure detection (PROTOCOL.md §4): close when NO pong has arrived for 10 s.
                // Measured from lastPongAt (refreshed in completeHandshake + onPong), NOT pingSentLocal
                // which sendPing refreshes every ≤6 s and so can never reach the 10 s threshold.
                // The verdict is one-shot: a non-null closeCause means teardown is already decided
                // (keepalive latched, goodbye pending, app shutting down) — a later tick must
                // neither re-fire connect_failed nor touch a socket that is CLOSING/CLOSED.
                if (peer.closeCause == null && peer.lastPongAt > 0
                    && t - peer.lastPongAt >= Protocol.PONG_TIMEOUT_MS) {
                    beginKeepaliveTeardown(peer, ws)
                }
            }
            if (peer.state == ConnState.RECONNECTING && (peer.discovered || peer.manual) && t >= peer.nextReconnectAt) {
                dial(peer, if (peer.foundAtMs > 0) t - peer.foundAtMs else null)
            }
            // Expiry (PROTOCOL.md §2) applies only to a discovered peer with NO live connection
            // that has stopped re-announcing: it never expires a connected socket (pongs keep
            // lastSeenAt fresh anyway) and idle-but-present peers are kept alive by the 45 s
            // re-browse cycle re-firing onServiceFound → lastSeenAt.
            if (peer.discovered && peer.state != ConnState.CONNECTED && peer.ws == null
                && t - peer.lastSeenAt > Protocol.PEER_EXPIRY_MS) {
                markGone(peer, "expired_60s")
            }
        }
        if (autoBroadcast && t - lastAutoAt >= 2000) {
            lastAutoAt = t
            if (status == "playing") positionSec += 2.0
            broadcastState(increment = true)
        }
    }

    /** §4 failure verdict for one live socket, executed exactly once per teardown decision.
     *  Latches the peer into CLOSING before any close API is touched, so subsequent ticks re-enter
     *  neither the ping nor the failure branch (no re-fired connect_failed, no send on a dying
     *  socket). The close itself must be a hard closeConnection: a graceful close() waits for the
     *  peer's close-frame reply, which a frozen peer never sends, parking the socket in the
     *  library's CLOSING state until its TCP pinger reports 1006 ~10 s later. closeConnection
     *  aborts the TCP link and fires onClose immediately with our code/reason (§6 convention). */
    private fun beginKeepaliveTeardown(peer: Peer, ws: WebSocket) {
        synchronized(lock) {
            if (peer.state != ConnState.CONNECTED || peer.ws !== ws || peer.closeCause != null) return
            peer.state = ConnState.CLOSING
            peer.closeCause = Cause.KEEPALIVE
        }
        Jsonl.event("connect_failed", "warn", "remoteId" to peer.id,
            "detail" to "keepalive_timeout")
        forceClose(ws, Protocol.CLOSE_NORMAL, "keepalive timeout")
    }

    private fun sendPing(peer: Peer) {
        val id = Protocol.newId()
        peer.pingId = id
        peer.pingSentLocal = now
        peer.lastPingAt = now
        try {
            peer.ws?.send(Protocol.envelope("ping", myId, id = id))
        } catch (e: WebsocketNotConnectedException) {
            // Benign race: the socket moved to CLOSING/CLOSED between the tick's CONNECTED check
            // and this send (e.g. a remote close frame arriving mid-tick). The §4 lastPongAt
            // watchdog owns failure detection, so the lost ping needs no recovery — but letting
            // the exception escape would resurface as a spurious {"detail":"tick"} error.
            Jsonl.event("ping_sent", "debug", "remoteId" to peer.id,
                "detail" to "skipped: socket closing")
            return
        }
        Jsonl.event("ping_sent", "debug", "remoteId" to peer.id, "detail" to "id=$id")
    }

    fun markGone(peer: Peer, reason: String, wireReason: String = reason.substringBefore(":")) {
        val ws: WebSocket?
        synchronized(lock) {
            if (peer.state == ConnState.GONE) return
            peer.discovered = false
            peer.state = ConnState.GONE
            peer.closeCause = Cause.SHUTDOWN
            peer.handshakeTimer?.cancel(false)
            ws = peer.ws
            // No `goodbye` here (PROTOCOL.md §6): expiry / service-removal is not an intentional
            // close from us and there is no reliable socket to say it over. Just record peer_lost
            // and close normally; `reason` is a peer_lost *detail*, never a goodbye wire reason.
            peers.remove(peer.key())
        }
        Jsonl.event("peer_lost", "info", "remoteId" to peer.id, "detail" to reason)
        // Close frame carries ONE clean token, never the joined internal label (e.g. the raw
        // `service_removed:service_removed`) that a remote peer would otherwise see (§6 convention).
        ws?.let { safeClose(it, Protocol.CLOSE_NORMAL, wireReason) }
        listener?.onPeersChanged()
    }

    // ---- outbound messages ----------------------------------------------

    private fun sendStateTo(peer: Peer, increment: Boolean) {
        if (increment) synchronized(lock) { seq += 1 }
        val s = state()
        peer.ws?.send(Protocol.envelope("state_update", myId, s))
        Jsonl.event("state_sent", "info", "remoteId" to peer.id,
            "detail" to "track=$track status=$status pos=$positionSec seq=$seq")
    }

    fun state(): JSONObject = JSONObject()
        .put("track", track).put("status", status)
        .put("positionSec", positionSec).put("seq", seq)

    fun broadcastState(increment: Boolean) {
        if (increment) synchronized(lock) { seq += 1 }
        val s = state()
        val snapshot = synchronized(lock) { peers.values.mapNotNull { if (it.state == ConnState.CONNECTED) it else null } }
        for (peer in snapshot) {
            try {
                peer.ws?.send(Protocol.envelope("state_update", myId, s))
            } catch (e: WebsocketNotConnectedException) {
                // Same benign close race as sendPing; a broadcast must also survive one peer's
                // socket going away mid-loop without skipping the remaining peers.
                Jsonl.event("state_sent", "debug", "remoteId" to peer.id,
                    "detail" to "skipped: socket closing")
                continue
            }
            Jsonl.event("state_sent", "info", "remoteId" to peer.id,
                "detail" to "track=$track status=$status pos=$positionSec seq=$seq")
        }
    }

    fun sendTest(text: String) {
        val snapshot = synchronized(lock) { peers.values.mapNotNull { if (it.state == ConnState.CONNECTED) it.ws else null } }
        for (ws in snapshot) ws.send(Protocol.envelope("test", myId,
            JSONObject().put("text", text)))
        Jsonl.event("msg_sent", "info", "detail" to "test to ${snapshot.size} peers text=$text")
    }

    fun onStatusChange(newStatus: String) {
        status = newStatus
        broadcastState(increment = true)
    }

    fun onTrackChange(t: String) { track = t }
    fun onPositionChange(p: Double) { positionSec = p }

    // ---- shutdown -------------------------------------------------------

    fun shutdown() {
        val snapshot = synchronized(lock) { peers.values.toList() }
        for (peer in snapshot) {
            val ws = peer.ws ?: continue
            peer.closeCause = Cause.SHUTDOWN
            sendGoodbye(peer, ws, "app_shutdown")
            safeClose(ws, Protocol.CLOSE_NORMAL, "app shutdown")
        }
        sched.shutdownNow()
        server?.stop()
        Jsonl.event("app_stop", "info")
    }

    private fun sendGoodbye(peer: Peer, ws: WebSocket, reason: String) {
        try {
            ws.send(Protocol.envelope("goodbye", myId, JSONObject().put("reason", reason)))
            Jsonl.event("msg_sent", "debug", "remoteId" to peer.id, "detail" to "goodbye:$reason")
        } catch (e: Exception) {
            Jsonl.event("error", "warn", "remoteId" to peer.id, "error" to e.message)
        }
    }

    private fun safeClose(ws: WebSocket, code: Int, reason: String) {
        try { ws.close(code, reason) } catch (e: Exception) {
            Jsonl.event("error", "debug", "detail" to "close failed ${e.message}")
        }
    }

    /** Hard, exactly-once teardown (WebSocketImpl.closeConnection): aborts the TCP link without a
     *  close handshake and fires onClose with `code`/`reason` on the calling thread. The library
     *  no-ops a repeat call once the socket is CLOSED, so onClose can never fire twice here. */
    private fun forceClose(ws: WebSocket, code: Int, reason: String) {
        try {
            ws.closeConnection(code, reason)
        } catch (e: Exception) {
            Jsonl.event("error", "debug", "detail" to "hard close failed ${e.message}")
            safeClose(ws, code, reason)
        }
    }

    private fun socketToPeerPut(ws: WebSocket, peer: Peer) { socketToPeer[ws] = peer }

    private fun seenDuplicate(peer: Peer, id: String): Boolean =
        id.isNotEmpty() && peer.seenSet.contains(id)

    private fun rememberId(peer: Peer, id: String) {
        if (id.isEmpty()) return
        peer.seenSet.add(id); peer.seen.addLast(id)
        while (peer.seen.size > 128) peer.seenSet.remove(peer.seen.removeFirst())
    }

    fun startScheduling() {
        sched.scheduleAtFixedRate({ try { tick() } catch (e: Exception) {
            Jsonl.event("error", "error", "error" to e.message, "detail" to "tick")
        } }, 1000L, 1000L, TimeUnit.MILLISECONDS)
    }

    // ---- discovery wiring (called by Activity) --------------------------

    private lateinit var discovery: Discovery

    init {
        discovery = Discovery(appContext, myId, object : Discovery.Listener {
            override fun onPeer(id: String, name: String, host: String, port: Int, elapsed: Long) =
                onPeerFound(id, name, host, port, elapsed)

            override fun onGone(id: String, reason: String) {
                val peer = synchronized(lock) { peers[id] } ?: return
                // PROTOCOL.md §2: service_removed is only an mDNS presence HINT; the authoritative
                // liveness signals are §4 keepalive and §2's 60 s expiry — the tick already "never
                // expires a connected socket". On the emulator↔host bridge a live peer's cached mDNS
                // record intermittently drops and only re-forms at the next re-browse (measured
                // 2–8 s gaps, not tick-aligned), which no Discovery-side debounce can fully mask.
                // So a healthy, pong-current socket is never torn down on a hint: real loss is still
                // caught by keepalive (10 s → reconnect) and by the non-connected reconnect/expiry paths.
                val healthy = peer.state == ConnState.CONNECTED && peer.ws != null &&
                    peer.lastPongAt > 0 && now - peer.lastPongAt < Protocol.PONG_TIMEOUT_MS
                if (healthy) {
                    peer.lastSeenAt = now
                    Jsonl.event("announce", "debug", "remoteId" to id,
                        "detail" to "dns_hint_ignored:socket_healthy")
                    return
                }
                // `reason` already names the cause ("service_removed"); do not re-prefix it or the
                // peer_lost detail doubles ("service_removed:service_removed"). The clean wire token
                // still comes via markGone's wireReason default (substringBefore(":")).
                markGone(peer, reason)
            }

            override fun onAnnounceResult(ok: Boolean, detail: String) {
                discoveryLive = ok
                if (ok) {
                    Jsonl.event("discovery_start", "info", "detail" to detail,
                        "elapsedDiscoveryMs" to (now - appStartMs))   // app_start -> discovery live
                    discovery.discover()
                }
                listener?.onPeersChanged()
            }
        })
    }

    fun registerDiscovery() { discovery.register(myName, serverPort) }
    fun stopDiscovery() = discovery.shutdown()
    fun restartDiscoveryForName(name: String) { if (discoveryLive) discovery.register(name, serverPort) }

    // ---- UI snapshot ----------------------------------------------------

    data class PeerView(
        val shortId: String, val name: String, val state: String, val disc: Boolean,
        val host: String, val status: String, val track: String, val pos: Double, val seq: Long)

    fun snapshotPeers(): List<PeerView> = synchronized(lock) {
        peers.values.map {
            PeerView((it.id ?: it.addrKey).take(8),
                if (it.name.isNotEmpty()) it.name else "?",
                it.state.name, it.discovered, "${it.host}:${it.port}",
                it.lastStatus, it.lastTrack, it.lastPosition, it.lastSeq)
        }
    }

    companion object {
        fun ipv4Addresses(): List<String> = Discovery.ipv4()
    }
}
