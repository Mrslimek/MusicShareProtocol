package com.musicshare.mvp

import org.json.JSONObject
import java.util.UUID

/** Wire-protocol constants and envelope helpers, one-to-one with protocol/PROTOCOL.md. */
object Protocol {
    const val V = 1
    const val SERVICE_TYPE = "_musicshare._tcp."   // DNS-SD service type
    const val TXT_ID = "id"
    const val TXT_NAME = "name"
    const val TXT_V = "v"
    const val PROTOCOL_VERSION = "1"
    const val PLATFORM = "android"
    const val APP_VERSION = "0.1.0"

    // Close codes (diagnostic convention; receivers always log code + reason).
    const val CLOSE_NORMAL = 1000        // sent after `goodbye`
    const val CLOSE_HANDSHAKE = 4002     // handshake timeout
    const val CLOSE_SUPERSEDED = 4003    // newer connection for same peer id
    const val CLOSE_INTERNAL = 1011      // unexpected internal error

    // Timing (ms).
    const val HANDSHAKE_TIMEOUT_MS = 5_000L
    const val PING_INTERVAL_MS = 5_000L
    const val PONG_TIMEOUT_MS = 10_000L
    const val PEER_EXPIRY_MS = 60_000L

    // Reconnect delays: 1.5 -> 30 s cap, +/-20% jitter, reset on success.
    val BACKOFF_MS = longArrayOf(1_500, 3_000, 6_000, 12_000, 24_000, 30_000)
    const val JITTER = 0.20

    fun newId(): String = UUID.randomUUID().toString()

    /** Build one JSON text frame: common envelope flattened with type-specific fields. */
    fun envelope(type: String, fromId: String, extra: JSONObject? = null,
                 replyTo: String? = null, id: String = newId()): String {
        val o = JSONObject()
        o.put("v", V)
        o.put("type", type)
        o.put("id", id)
        o.put("from", fromId)
        o.put("ts", System.currentTimeMillis())
        if (replyTo != null) o.put("replyTo", replyTo)
        if (extra != null) for (k in extra.keys()) o.put(k, extra.get(k))
        return o.toString()
    }

    /** Parse a frame. Returns the envelope fields or null if not valid JSON. */
    class Msg(val obj: JSONObject) {
        val type: String get() = obj.optString("type")
        val id: String get() = obj.optString("id")
        val from: String get() = obj.optString("from")
        val ts: Long get() = obj.optLong("ts")
        val replyTo: String? get() = if (obj.has("replyTo")) obj.optString("replyTo") else null
    }

    fun parse(text: String): Msg? = try {
        Msg(JSONObject(text))
    } catch (e: Exception) {
        null
    }

    /** Envelope-required-field check per PROTOCOL.md §6. */
    fun malformed(m: Msg): String? {
        if (m.obj.optInt("v", -1) != V) return "v"
        if (m.type.isEmpty()) return "type"
        if (m.id.isEmpty()) return "id"
        if (m.from.isEmpty()) return "from"
        if (!m.obj.has("ts")) return "ts"
        return null
    }
}
