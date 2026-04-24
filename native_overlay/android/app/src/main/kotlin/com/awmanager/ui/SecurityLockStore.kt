package com.awmanager.ui

import android.content.Context

object SecurityLockStore {
    private const val PREFS = "alphawet_security_lock"
    private const val KEY_LOCKED = "locked"
    private const val KEY_REASON = "reason"

    fun markLocked(context: Context, reason: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_LOCKED, true)
            .putString(KEY_REASON, reason)
            .apply()
    }

    fun isLocked(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_LOCKED, false)

    fun reason(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_REASON, "SECURITY_LOCKED") ?: "SECURITY_LOCKED"

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_LOCKED)
            .remove(KEY_REASON)
            .apply()
    }
}
