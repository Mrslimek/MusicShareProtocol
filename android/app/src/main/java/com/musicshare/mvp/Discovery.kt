package com.musicshare.mvp

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import java.net.InetAddress

/** mDNS/DNS-SD advertiser + browser (PROTOCOL.md §2), plus the WiFi multicast lock. */
class Discovery(context: Context, private val myId: String, private val listener: Listener) {

    interface Listener {
        fun onPeer(id: String, name: String, host: String, port: Int, elapsedDiscoveryMs: Long)
        fun onGone(id: String, reason: String)
        fun onAnnounceResult(ok: Boolean, detail: String)
    }

    private val appContext = context.applicationContext
    private val nsd = appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = appContext.applicationContext
        .getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val mcast = wifi.createMulticastLock("mshare").apply { setReferenceCounted(false) }

    private val instanceToId = HashMap<String, String>()
    // Deferred removals: serviceName -> confirm-runnable. A service_removed is not honoured until it
    // survives GONE_CONFIRM_MS; a re-find/heal (browse-start snapshot quirk on this image emits a
    // transient lost→found within the CURRENT generation) cancels it. All touched on the main looper.
    private val pendingGone = HashMap<String, Runnable>()
    private var regListener: NsdManager.RegistrationListener? = null
    private var discListener: NsdManager.DiscoveryListener? = null
    var discoveryStartMs: Long = 0L
        private set

    // Periodic re-discovery (PROTOCOL.md §2/§5, mirrors the macOS 45 s re-browse). NsdManager
    // fires onServiceFound only when a service newly appears to it, so without a stop+restart a
    // live peer never re-announces and would falsely hit the 60 s expiry. A fresh browse re-
    // notifies every live service → refreshes lastSeenAt, re-resolves new ports, revives `gone`.
    private val handler = Handler(Looper.getMainLooper())
    private var browseGeneration = 0                 // active listener = current gen; stale gens ignore onServiceLost
    // Wall-clock start of the CURRENT generation's browse (set in runBrowse). Used to measure the
    // age of a received onServiceLost against QUIET_MS. Only ever read once `gen == browseGeneration`
    // (stale listeners return before then), so it always names the current listener's browse.
    private var browseStartMs = 0L
    private val cycleRunnable = Runnable { rediscover() }

    fun acquireLock(reason: String) {
        if (!mcast.isHeld) mcast.acquire()
        Jsonl.event("announce", "debug", "detail" to "multicast_lock_acquired:$reason",
            "localAddr" to ipv4().toString())
    }

    fun releaseLock(reason: String) {
        if (mcast.isHeld) mcast.release()
        Jsonl.event("announce", "debug", "detail" to "multicast_lock_released:$reason")
    }

    /** Register the WS server as a `_musicshare._tcp` service with TXT id/name/v. */
    fun register(name: String, port: Int) {
        acquireLock("register")
        val info = NsdServiceInfo().apply {
            serviceName = "musicshare-$myId"
            serviceType = Protocol.SERVICE_TYPE
            this.port = port
            setAttribute(Protocol.TXT_ID, myId.toByteArray())
            setAttribute(Protocol.TXT_NAME, name.toByteArray())
            setAttribute(Protocol.TXT_V, Protocol.PROTOCOL_VERSION.toByteArray())
        }
        val rl = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) {
                Jsonl.event("announce", "info", "detail" to "nsd_registered:${i.serviceName}",
                    "localAddr" to "${ipv4()}:$port")
                listener.onAnnounceResult(true, "port=$port")
            }
            override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) {
                val d = "nsd_register_failed code=${regName(code)}"
                Jsonl.event("announce", "error", "detail" to d)
                listener.onAnnounceResult(false, d)
            }
            override fun onServiceUnregistered(i: NsdServiceInfo) {}
            override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) {}
        }
        regListener?.let { try { nsd.unregisterService(it) } catch (_: Exception) {} }
        regListener = rl
        // On API 36+ the platform can reject NSD registration with a SecurityException when the
        // local-network permission is absent. Never let it crash the app: log it as a failure.
        try {
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, rl)
        } catch (e: SecurityException) {
            Jsonl.event("announce", "error", "detail" to "nsd_register_denied:${e.message}")
            releaseLock("register_denied")
            listener.onAnnounceResult(false, "SecurityException: ${e.message}")
        } catch (e: Exception) {
            Jsonl.event("announce", "error", "detail" to "nsd_register_exception:${e.message}")
            listener.onAnnounceResult(false, "exception: ${e.message}")
        }
    }

    /** Browse for peers and resolve each into host/port/TXT. Full start: resets the discovery
     *  clock, logs `discovery_start`, and arms the periodic re-browse cycle. */
    fun discover() {
        stopDiscovery()
        acquireLock("discover")
        discoveryStartMs = System.currentTimeMillis()
        Jsonl.event("discovery_start", "info")
        runBrowse()
    }

    /** Periodic re-browse: stop the current browse (its in-flight onServiceLost teardown is
     *  suppressed via the generation counter, so live peers are not falsely marked gone) then,
     *  after a short gap so NsdManager has fully torn down, start a fresh one. */
    private fun rediscover() {
        Jsonl.event("announce", "debug", "detail" to "rediscovery_cycle")
        stopDiscovery()
        handler.postDelayed({ acquireLock("rediscover"); runBrowse() }, REBROWSE_RESTART_DELAY_MS)
    }

    /** Start a browse under a new generation and (re)arm the next re-browse tick. */
    private fun runBrowse() {
        browseStartMs = System.currentTimeMillis()   // anchor the quiet period for this generation
        val gen = ++browseGeneration
        val dl = makeListener(gen)
        discListener = dl
        try {
            nsd.discoverServices(Protocol.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, dl)
        } catch (e: SecurityException) {
            Jsonl.event("discovery_start", "error", "detail" to "denied:${e.message}")
            releaseLock("discover_denied")
        }
        armCycle()
    }

    private fun armCycle() {
        handler.removeCallbacks(cycleRunnable)
        handler.postDelayed(cycleRunnable, REBROWSE_INTERVAL_MS)
    }

    private fun makeListener(gen: Int) = object : NsdManager.DiscoveryListener {
        override fun onStartDiscoveryFailed(t: String, code: Int) {
            Jsonl.event("discovery_start", "error", "detail" to "failed ${discName(code)}")
        }
        override fun onStopDiscoveryFailed(t: String, code: Int) {}
        override fun onDiscoveryStarted(t: String) {}
        override fun onDiscoveryStopped(t: String) {
            Jsonl.event("discovery_stop", "info")
        }
        override fun onServiceFound(s: NsdServiceInfo) {
            // A found right after a transient lost is the browse-start snapshot heal: cancel any
            // pending removal — the service is alive, so no onGone fires.
            healPendingGone(s.serviceName)
            if (s.serviceType == Protocol.SERVICE_TYPE) nsd.resolveService(s, resolveListener(s.serviceName))
        }
        override fun onServiceLost(s: NsdServiceInfo) {
            // Ignore teardown from a browse we already replaced (re-browse): only the active
            // generation can report real removals (PROTOCOL.md §2 "OS reports service removed").
            if (gen != browseGeneration) return
            // Browse quiet period: on this API 37 image the platform re-notifies a live peer as a
            // spurious lost up to ~20 s into a generation, but its matching found arrives only in a
            // LATER generation — so there is no same-generation heal to cancel a debounced removal,
            // and honouring it closes a healthy socket once per re-browse (~2 s blackout/cycle).
            // Discard removals received within QUIET_MS of this listener's browse start. Tradeoff,
            // documented here (contract §2 unchanged): a genuinely gone peer emits no later found,
            // so its removal is caught by the §2 60 s expiry backstop. A removal arriving >= QUIET_MS
            // after browse start still runs the 2.5 s debounce -> onGone <= QUIET_MS+GONE_CONFIRM_MS
            // (~32.5 s, inside the 45 s cycle); worst case the 60 s expiry. Detection latency, not
            // correctness, is what this buys.
            if (System.currentTimeMillis() - browseStartMs < QUIET_MS) {
                Jsonl.event("announce", "debug",
                    "detail" to "service_removed during browse quiet period ignored instance=${s.serviceName}")
                return
            }
            // Defer, don't fire immediately: on this API 37 image a healthy peer emits a spurious
            // lost→found within the SAME (current) generation right after a browse starts, which the
            // gen check above cannot catch. Debounce confirms only a disappearance surviving
            // GONE_CONFIRM_MS; a re-find cancels it. Contract §2's 60 s expiry stays the backstop —
            // the +2.5 s is a deliberate, bounded measurement-latency grace (PROTOCOL.md unchanged).
            schedulePendingGone(s.serviceName)
        }
    }

    /** Debounce a service removal: honour it only if it survives GONE_CONFIRM_MS without a heal. */
    private fun schedulePendingGone(instance: String) {
        if (pendingGone.containsKey(instance)) return          // earliest pending timestamp wins
        val id = instanceToId[instance] ?: return              // never resolved → nothing to mark gone
        val confirm = Runnable {
            if (pendingGone.remove(instance) == null) return@Runnable   // healed → this never runs
            instanceToId.remove(instance)
            listener.onGone(id, "service_removed")
        }
        pendingGone[instance] = confirm
        handler.postDelayed(confirm, GONE_CONFIRM_MS)
    }

    /** A found/resolved service cancels a pending removal: it is still alive. */
    private fun healPendingGone(instance: String) {
        pendingGone.remove(instance)?.let { handler.removeCallbacks(it) }
    }

    /** Drop every deferred confirmation and its callback (browse teardown / shutdown). */
    private fun clearPendingGone() {
        pendingGone.values.forEach { handler.removeCallbacks(it) }
        pendingGone.clear()
    }

    private fun resolveListener(instance: String) = object : NsdManager.ResolveListener {
        override fun onResolveFailed(i: NsdServiceInfo, code: Int) {
            Jsonl.event("peer_lost", "warn", "detail" to "resolve_failed code=$code name=${i.serviceName}")
        }
        override fun onServiceResolved(i: NsdServiceInfo) {
            healPendingGone(instance)   // a successful resolve proves the peer is alive
            val attrs = i.attributes
            val id = String(attrs[Protocol.TXT_ID] ?: return)
            if (id == myId) return                       // ignore self
            val name = String(attrs[Protocol.TXT_NAME] ?: ByteArray(0))
            val host = i.host.hostAddress ?: return
            instanceToId[instance] = id
            val elapsed = System.currentTimeMillis() - discoveryStartMs
            listener.onPeer(id, name, host, i.port, elapsed)
        }
    }

    fun shutdown() {
        Jsonl.event("discovery_stop", "info")
        handler.removeCallbacks(cycleRunnable)
        clearPendingGone()   // never fire stale confirms after a full stop
        regListener?.let { try { nsd.unregisterService(it) } catch (_: Exception) {} }
        stopDiscovery()
        releaseLock("shutdown")
    }

    private fun stopDiscovery() {
        browseGeneration++   // mark the current listener stale → its onServiceLost is suppressed
        discListener?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) {} }
        discListener = null
        clearPendingGone()   // a browse teardown must never fire stale confirms into the new gen
    }

    /** NSD register-failure codes are documented as ints (not public constants). */
    private fun regName(code: Int) = when (code) {
        0 -> "FAILED_ALREADY_REGISTERED"; 1 -> "FAILED_INTERNAL_ERROR"
        2 -> "FAILED_INVALID_SERVICE_TYPE"; 3 -> "FAILED_INVALID_SERVICE_NAME"
        4 -> "FAILED_SERVICE_KEY_LIMIT"; 5 -> "FAILED_SERVICE_ALREADY_ADVERTISED"
        else -> "code$code"
    }

    /** NSD discovery-failure codes, same integer convention. */
    fun discName(code: Int) = when (code) {
        0 -> "FAILED_ALREADY_DISCOVERING"; 1 -> "FAILED_INTERNAL_ERROR"
        2 -> "FAILED_INVALID_SERVICE_TYPE"; 3 -> "FAILED_UNREACHABLE"
        else -> "code$code"
    }

    companion object {
        private const val REBROWSE_INTERVAL_MS = 45_000L   // < 60 s expiry (PROTOCOL.md §2)
        private const val REBROWSE_RESTART_DELAY_MS = 400L // let NsdManager finish the stop first
        private const val GONE_CONFIRM_MS = 2_500L         // heal window for a transient lost→found
        // Ignore spurious onServiceLost within this window of a browse start: on API 37 a live peer's
        // false removal lands ~20 s into a generation while its heal found only arrives next cycle.
        // 30 s (> that ~20 s, < 45 s cycle so QUIET_MS+GONE_CONFIRM_MS still resolves inside a cycle,
        // << 60 s expiry backstop).
        private const val QUIET_MS = 30_000L

        fun ipv4(): List<String> = try {
            java.util.Collections.list(java.net.NetworkInterface.getNetworkInterfaces())
                .filter { !it.isLoopback && it.isUp }
                .flatMap { ni -> java.util.Collections.list(ni.inetAddresses) }
                .filterIsInstance<InetAddress>()
                .filter { it is java.net.Inet4Address }
                .map { it.hostAddress ?: "?" }
        } catch (e: Exception) {
            emptyList()
        }
    }
}
