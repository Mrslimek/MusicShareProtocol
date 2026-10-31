package com.musicshare.mvp

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import java.util.UUID

/** Persistent device id (UUID v4, lowercase) + editable display name. */
class DeviceStore(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("musicshare", Context.MODE_PRIVATE)

    val id: String
        get() {
            var v = prefs.getString("id", null)
            if (v == null) {
                v = UUID.randomUUID().toString().lowercase()
                prefs.edit().putString("id", v).apply()
            }
            return v
        }

    var name: String
        get() = prefs.getString("name", null) ?: Build.MODEL
        set(value) = prefs.edit().putString("name", value).apply()
}
