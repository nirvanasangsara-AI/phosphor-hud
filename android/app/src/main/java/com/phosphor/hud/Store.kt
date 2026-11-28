package com.phosphor.hud

import android.content.Context
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

object SnapshotStore {
    private const val PREFS = "phosphor"

    fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun paired(context: Context): Boolean = token(context) != null && !demo(context)

    fun demo(context: Context) = prefs(context).getBoolean("demo", false)

    fun token(context: Context): String? = prefs(context).getString("token", null)?.takeIf { it.isNotEmpty() }

    fun host(context: Context) = prefs(context).getString("host", "") ?: ""

    fun port(context: Context) = prefs(context).getInt("port", 47321)

    fun language(context: Context) = prefs(context).getString("language", "system") ?: "system"

    fun theme(context: Context) = prefs(context).getString("theme", "clean") ?: "clean"

    fun load(context: Context): PhoneSnapshot? {
        val raw = prefs(context).getString("snapshot", null) ?: return null
        return runCatching { SnapshotJson.parse(raw) }.getOrNull()
    }

    fun setLanguage(context: Context, value: String) {
        prefs(context).edit().putString("language", value).apply()
    }

    fun setTheme(context: Context, value: String) {
        prefs(context).edit().putString("theme", value).apply()
    }

    fun setDemo(context: Context, on: Boolean) {
        val edit = prefs(context).edit().putBoolean("demo", on)
        if (on) {
            val raw = context.assets.open("demo-snapshot.json").bufferedReader().readText()
            edit.putString("snapshot", raw)
        }
        edit.apply()
    }

    fun forget(context: Context) {
        prefs(context).edit().remove("token").remove("host").remove("snapshot").putBoolean("demo", false).apply()
    }

    fun pair(context: Context, host: String, port: Int, code: String) {
        val body = JSONObject().put("code", code).toString()
        val text = http("http://$host:$port/v1/pair", "POST", body, null)
        val token = JSONObject(text).getString("token")
        prefs(context).edit()
            .putString("host", host.trim())
            .putInt("port", port)
            .putString("token", token)
            .putBoolean("demo", false)
            .apply()
        refresh(context)
    }

    fun refresh(context: Context) {
        if (demo(context)) {
            setDemo(context, true)
            return
        }
        val token = token(context) ?: return
        val host = host(context)
        if (host.isEmpty()) return
        val text = http("http://$host:${port(context)}/v1/snapshot", "GET", null, token)
        prefs(context).edit().putString("snapshot", text).apply()
    }

    private fun http(url: String, method: String, body: String?, token: String?): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = false
            connectTimeout = 4000
            readTimeout = 8000
            requestMethod = method
            setRequestProperty("Accept", "application/json")
            if (token != null) setRequestProperty("Authorization", "Bearer $token")
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
        }
        if (body != null) conn.outputStream.use { it.write(body.toByteArray()) }
        val code = conn.responseCode
        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
        val text = stream?.bufferedReader()?.readText().orEmpty()
        if (code !in 200..299) error("HTTP $code")
        return text
    }
}
