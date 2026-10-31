package com.musicshare.mvp

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Structured JSONL logger (PROTOCOL.md §7). Fans each event out to three sinks:
 * logcat (tag MShare), an in-memory ring buffer for the UI, and a session file.
 * Not UI-thread safe to write from arbitrary threads — guarded by `lock`.
 */
object Jsonl {
    private const val TAG = "MShare"
    private const val CAP = 4000

    private val lock = Any()
    private val ring = ArrayDeque<String>()
    private val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        .apply { timeZone = TimeZone.getTimeZone("UTC") }

    @Volatile var localId: String = ""
    @Volatile private var writer: FileWriter? = null
    @Volatile var logFile: File? = null
        private set
    @Volatile var onUpdate: (() -> Unit)? = null   // UI refresh hook, invoked off-lock

    fun init(context: Context, localId: String) {
        this.localId = localId
        val dir = File(context.getExternalFilesDir(null) ?: context.filesDir, "logs")
        dir.mkdirs()
        val f = File(dir, "session-$localId.jsonl")
        logFile = f
        synchronized(lock) {
            writer = FileWriter(f, true)
        }
        Log.i(TAG, "log file: ${f.absolutePath}")
    }

    private fun line(level: String, event: String, fields: JSONObject): String {
        val o = JSONObject()
        o.put("ts", fmt.format(Date()))
        o.put("level", level)
        o.put("event", event)
        o.put("localId", localId)
        for (k in fields.keys()) o.put(k, fields.get(k))
        return o.toString()
    }

    /** Log an event with optional key/value extras (remoteId, localAddr, rttMs, …). */
    fun event(event: String, level: String = "info", vararg kv: Pair<String, Any?>) {
        val fields = JSONObject()
        for ((k, v) in kv) if (v != null) fields.put(k, v)
        val s = line(level, event, fields)
        when (level) {
            "error" -> Log.e(TAG, s)
            "warn" -> Log.w(TAG, s)
            "debug" -> Log.d(TAG, s)
            else -> Log.i(TAG, s)
        }
        synchronized(lock) {
            if (ring.size >= CAP) ring.pollFirst()
            ring.addLast(s)
            try {
                writer?.apply { write(s); write("\n"); flush() }
            } catch (e: Exception) {
                Log.e(TAG, "file write failed: ${e.message}")
            }
        }
        onUpdate?.invoke()
    }

    fun snapshot(): String = synchronized(lock) { ring.joinToString("\n") }

    fun stop() {
        synchronized(lock) {
            try { writer?.close() } catch (_: Exception) {}
            writer = null
        }
    }
}
