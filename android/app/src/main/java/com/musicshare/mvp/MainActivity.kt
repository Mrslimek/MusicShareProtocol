package com.musicshare.mvp

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Bundle
import android.text.SpannableStringBuilder
import android.text.style.ForegroundColorSpan
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/** Single Activity: UI + runtime-permission gate + network monitor. Delegates all
 *  protocol/mesh behaviour to [MeshController]. */
class MainActivity : Activity(), MeshController.Listener {

    private lateinit var controller: MeshController
    private lateinit var store: DeviceStore
    private var discoveryAllowed = false

    private lateinit var localInfo: TextView
    private lateinit var banner: TextView
    private lateinit var peersView: TextView
    private lateinit var logView: TextView
    private lateinit var logScroll: ScrollView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        store = DeviceStore(this)
        Jsonl.init(this, store.id)
        controller = MeshController(this, store).also { it.listener = this }
        Jsonl.onUpdate = { runOnUiThread { renderLog() } }

        localInfo = findViewById(R.id.localInfo)
        banner = findViewById(R.id.banner)
        peersView = findViewById(R.id.peers)
        logView = findViewById(R.id.logView)
        logScroll = findViewById(R.id.logScroll)

        controller.logStartup()                       // app_start + platform/java/ipv4
        controller.startServer()                     // WS server, always (manual connect)
        controller.startScheduling()
        registerNetworkMonitor()
        findViewById<EditText>(R.id.nameField).setText(store.name)
        wireControls()

        requestDiscoveryOrProceed()
        handleIntentTarget(intent)
        renderLocal(); renderPeers()
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        intent?.let { handleIntentTarget(it) }
    }

    // ---- permission gate ------------------------------------------------

    /** NEARBY_WIFI_DEVICES on API 33+; ACCESS_LOCAL_NETWORK on API 36+ (enforced by this
     *  platform image even with targetSdk 35). Discovery is gated on the applicable ones. */
    private fun missingPerm(): List<String> {
        val out = ArrayList<String>()
        if (Build.VERSION.SDK_INT >= 33 && notGranted(Manifest.permission.NEARBY_WIFI_DEVICES))
            out.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        if (Build.VERSION.SDK_INT >= 36 && notGranted(LOCAL_NETWORK))
            out.add(LOCAL_NETWORK)
        return out
    }

    private fun notGranted(p: String) =
        checkSelfPermission(p) != android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun requestDiscoveryOrProceed() {
        val missing = missingPerm()
        if (missing.isEmpty()) {
            Jsonl.event("permission_granted", "info", "detail" to "discovery perms present")
            startDiscovery()
        } else {
            Jsonl.event("permission_request", "info", "detail" to missing.joinToString(","))
            requestPermissions(missing.toTypedArray(), REQ_PERM)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERM) return
        if (missingPerm().isEmpty()) {
            Jsonl.event("permission_granted", "info", "detail" to "granted: ${permissions.joinToString()}")
            startDiscovery()
        } else {
            Jsonl.event("permission_denied", "warn",
                "detail" to "still missing: ${missingPerm().joinToString()}")
            runOnUiThread {
                banner.visibility = View.VISIBLE
                Toast.makeText(this, "Discovery unavailable; manual connect still works", Toast.LENGTH_LONG).show()
                renderLocal()
            }
        }
    }

    private fun startDiscovery() {
        discoveryAllowed = true
        controller.registerDiscovery()
        runOnUiThread { banner.visibility = View.GONE; renderLocal() }
    }

    // ---- intent test hook ----------------------------------------------

    private fun handleIntentTarget(intent: Intent) {
        val target = intent.getStringExtra("connect_target") ?: return
        val parts = target.split(":")
        if (parts.size != 2) return
        val port = parts[1].toIntOrNull() ?: return
        logMessage("connect_target intent hook: dialing $target")
        findViewById<EditText>(R.id.manualHost).setText(target)
        android.os.Handler(mainLooper).postDelayed(
            { controller.dialManual(parts[0], port) }, INTENT_DIAL_DELAY_MS)
    }

    // ---- network monitor -----------------------------------------------

    private fun registerNetworkMonitor() {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                controller.onNetChange("available ${transportOf(cm, network)}")
            }
            override fun onLost(network: Network) {
                controller.onNetChange("lost")
            }
        }
        try { cm.registerNetworkCallback(request, callback) } catch (e: Exception) {
            Jsonl.event("error", "error", "error" to e.message, "detail" to "registerNetworkCallback")
        }
    }

    private fun transportOf(cm: ConnectivityManager, network: Network): String {
        val caps = cm.getNetworkCapabilities(network) ?: return "?"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "WIFI"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ETHERNET"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "CELLULAR"
            else -> "OTHER"
        }
    }

    // ---- UI controls ----------------------------------------------------

    private fun wireControls() {
        findViewById<Button>(R.id.btnPlaying).setOnClickListener { controller.onStatusChange("playing") }
        findViewById<Button>(R.id.btnPaused).setOnClickListener { controller.onStatusChange("paused") }
        findViewById<Button>(R.id.btnStopped).setOnClickListener { controller.onStatusChange("stopped") }

        findViewById<Button>(R.id.btnBroadcast).setOnClickListener {
            findViewById<EditText>(R.id.track).text.toString().takeIf { it.isNotEmpty() }
                ?.let { controller.onTrackChange(it) }
            findViewById<EditText>(R.id.position).text.toString().toDoubleOrNull()
                ?.let { controller.onPositionChange(it) }
            controller.broadcastState(increment = true)
        }
        findViewById<CheckBox>(R.id.autoBroadcast).setOnCheckedChangeListener { _, checked ->
            controller.autoBroadcast = checked
        }

        findViewById<Button>(R.id.btnTest).setOnClickListener {
            val text = findViewById<EditText>(R.id.testMsg).text.toString()
            controller.sendTest(text)
        }
        findViewById<Button>(R.id.btnConnect).setOnClickListener {
            val raw = findViewById<EditText>(R.id.manualHost).text.toString().trim()
            val parts = raw.split(":")
            val port = parts.getOrNull(1)?.toIntOrNull()
            if (parts.size != 2 || parts[0].isEmpty() || port == null) {
                Toast.makeText(this, "Enter host:port", Toast.LENGTH_SHORT).show()
            } else controller.dialManual(parts[0], port)
        }
        findViewById<Button>(R.id.btnSetName).setOnClickListener {
            val n = findViewById<EditText>(R.id.nameField).text.toString().trim()
            if (n.isNotEmpty()) {
                store.name = n
                controller.restartDiscoveryForName(n)   // refresh TXT `name`
                renderLocal()
            }
        }
        findViewById<Button>(R.id.btnCopy).setOnClickListener {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("mshare", Jsonl.snapshot()))
            Toast.makeText(this, "Log copied", Toast.LENGTH_SHORT).show()
        }
        findViewById<Button>(R.id.btnShare).setOnClickListener { shareLogFile() }
    }

    private fun shareLogFile() {
        val f = Jsonl.logFile
        val body = try { f?.readText() ?: "" } catch (e: Exception) { Jsonl.snapshot() }
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "application/x-ndjson"
            putExtra(Intent.EXTRA_SUBJECT, "Music Share session log")
            putExtra(Intent.EXTRA_TEXT, body)
        }
        startActivity(Intent.createChooser(send, "Share session log"))
    }

    // ---- rendering ------------------------------------------------------

    override fun onPeersChanged() { runOnUiThread { renderPeers(); renderLocal() } }

    private fun renderLocal() {
        val disc = when {
            controller.discoveryLive -> "live"
            discoveryAllowed -> "registering"
            else -> "OFF (no permission)"
        }
        localInfo.text = buildString {
            append("id: ${controller.localId()}\n")
            append("name: ${controller.localName()}\n")
            append("platform: android ${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT}\n")
            append("ipv4: ${controller.ipv4()}\n")
            append("ws_server_port: ${controller.serverPort}\n")
            append("discovery: $disc")
        }
    }

    private fun renderPeers() {
        val list = controller.snapshotPeers()
        if (list.isEmpty()) { peersView.text = "(none)"; return }
        val sb = SpannableStringBuilder()
        for (p in list) {
            val line = "[${p.state}] ${p.name} ${p.shortId}  ${if (p.disc) "seen" else "gone"}  ws://${p.host}\n"
            val start = sb.length
            sb.append(line)
            sb.setSpan(ForegroundColorSpan(colorFor(p.state)), start, start + p.state.length + 2,
                SpannableStringBuilder.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (p.status.isNotEmpty())
                sb.append("      track=${p.track} status=${p.status} pos=${p.pos} seq=${p.seq}\n")
        }
        peersView.text = sb
    }

    private fun colorFor(state: String): Int = when (state) {
        "CONNECTED" -> Color.parseColor("#2E7D32")
        "CONNECTING" -> Color.parseColor("#F9A825")
        "RECONNECTING" -> Color.parseColor("#EF6C00")
        "GONE" -> Color.parseColor("#B71C1C")
        else -> Color.parseColor("#616161")   // IDLE
    }

    private fun renderLog() {
        logView.text = Jsonl.snapshot()
        logScroll.post { logScroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun logMessage(text: String) { Jsonl.event("msg_sent", "debug", "detail" to text) }

    override fun onDestroy() {
        super.onDestroy()
        try { controller.stopDiscovery() } catch (_: Exception) {}
        controller.shutdown()      // goodbye + close
        Jsonl.stop()
    }

    companion object {
        private const val REQ_PERM = 1001
        private const val INTENT_DIAL_DELAY_MS = 2000L
        // Referenced as a string: the constant name is not present in every platform API jar.
        private const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
    }
}
