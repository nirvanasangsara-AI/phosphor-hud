package com.phosphor.hud

import android.content.Context
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.phosphor.hud.widget.RefreshWorker
import com.phosphor.hud.widget.updateWidgets
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale
import java.util.concurrent.TimeUnit

class MainActivity : ComponentActivity() {
    private val scan = registerForActivityResult(ScanContract()) { result ->
        result.contents?.let { openPairLink(it) }
    }

    override fun attachBaseContext(newBase: Context) {
        val lang = SnapshotStore.language(newBase)
        val locale = when (lang) {
            "ko" -> Locale.KOREAN
            "en" -> Locale.ENGLISH
            else -> null
        }
        if (locale == null) {
            super.attachBaseContext(newBase)
            return
        }
        val config = Configuration(newBase.resources.configuration)
        config.setLocale(locale)
        super.attachBaseContext(newBase.createConfigurationContext(config))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val work = PeriodicWorkRequestBuilder<RefreshWorker>(15, TimeUnit.MINUTES).build()
        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "phosphor-sync",
            ExistingPeriodicWorkPolicy.UPDATE,
            work,
        )
        intent?.data?.let { openPairLink(it.toString()) }
        setContent { HudScreen(::startScan, ::reloadLocale) }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        intent.data?.let { openPairLink(it.toString()) }
    }

    private fun startScan() {
        scan.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Phosphor"))
    }

    private fun openPairLink(raw: String) {
        val uri = Uri.parse(raw)
        if (uri.scheme != "phosphor") return
        val host = uri.getQueryParameter("host") ?: return
        val port = uri.getQueryParameter("port")?.toIntOrNull() ?: 47321
        val code = uri.getQueryParameter("code") ?: return
        Thread {
            runCatching { SnapshotStore.pair(this, host, port, code) }
            runOnUiThread { recreate() }
        }.start()
    }

    private fun reloadLocale() { recreate() }
}

@androidx.compose.runtime.Composable
private fun HudScreen(onScan: () -> Unit, onLocale: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var snap by remember { mutableStateOf(SnapshotStore.load(context)) }
    var paired by remember { mutableStateOf(SnapshotStore.token(context) != null || SnapshotStore.demo(context)) }
    var host by remember { mutableStateOf(SnapshotStore.host(context)) }
    var port by remember { mutableStateOf(SnapshotStore.port(context).toString()) }
    var code by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    LaunchedEffect(paired) {
        if (paired) {
            withContext(Dispatchers.IO) { runCatching { SnapshotStore.refresh(context) } }
            snap = SnapshotStore.load(context)
            withContext(Dispatchers.IO) { runCatching { updateWidgets(context) } }
        }
    }

    MaterialTheme(colorScheme = darkColorScheme(background = Color(0xFF12141A), primary = Color(0xFFF4C46A))) {
        Column(
            Modifier
                .fillMaxSize()
                .background(Color(0xFF12141A))
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Φ  Phosphor", color = Color(0xFFF4C46A), style = MaterialTheme.typography.headlineSmall)
            if (!paired) {
                Text(context.getString(R.string.pair_title), color = Color.White, style = MaterialTheme.typography.titleMedium)
                Text(context.getString(R.string.pair_body), color = Color(0xFFA8A29A))
                OutlinedTextField(host, { host = it }, label = { Text(context.getString(R.string.host)) }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(
                    port,
                    { port = it.filter { ch -> ch.isDigit() }.take(5) },
                    label = { Text(context.getString(R.string.port)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    code,
                    { code = it.filter { ch -> ch.isDigit() }.take(6) },
                    label = { Text(context.getString(R.string.code)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                )
                if (error != null) Text(error ?: "", color = Color(0xFFF07167))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = {
                        busy = true
                        error = null
                        Thread {
                            val result = runCatching { SnapshotStore.pair(context, host.trim(), port.toIntOrNull() ?: 47321, code) }
                            (context as MainActivity).runOnUiThread {
                                busy = false
                                if (result.isSuccess) paired = true else error = context.getString(R.string.error_pair)
                            }
                        }.start()
                    }, enabled = !busy) { Text(context.getString(R.string.pair)) }
                    Button(onClick = onScan) { Text(context.getString(R.string.scan)) }
                }
                Button(onClick = {
                    SnapshotStore.setDemo(context, true)
                    paired = true
                    snap = SnapshotStore.load(context)
                }) { Text(context.getString(R.string.demo)) }
            } else {
                if (SnapshotStore.demo(context)) Text(context.getString(R.string.demo_note), color = Color(0xFFF4C46A))
                val rows = snap?.rows.orEmpty()
                if (rows.isEmpty()) Text(context.getString(R.string.empty), color = Color(0xFFA8A29A))
                rows.forEach { row ->
                    Text(row.name + (row.plan?.let { "  ·  $it" } ?: ""), color = Color.White)
                    row.windows.forEach { w ->
                        Text("${w.label}  ${w.usedPercent}%", color = Color(0xFFA8A29A))
                        if (w.kind != "meter") {
                            LinearProgressIndicator(
                                progress = { w.usedPercent.coerceIn(0, 100) / 100f },
                                modifier = Modifier.fillMaxWidth(),
                                color = if (w.warns) Color(0xFFF07167) else Color(0xFFF4C46A),
                            )
                        }
                        w.forecastText?.let { Text(it, color = if (w.warns) Color(0xFFF07167) else Color(0xFFA8A29A)) }
                        w.resetsIn?.let { Text(it, color = Color(0xFFA8A29A)) }
                        w.amount?.let { Text(it, color = Color(0xFFA8A29A)) }
                    }
                    Spacer(Modifier.height(8.dp))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = {
                        Thread {
                            runCatching { SnapshotStore.refresh(context) }
                            (context as MainActivity).runOnUiThread { snap = SnapshotStore.load(context) }
                            Thread { runCatching { kotlinx.coroutines.runBlocking { updateWidgets(context) } } }.start()
                        }.start()
                    }) { Text(context.getString(R.string.refresh)) }
                    Button(onClick = {
                        SnapshotStore.forget(context)
                        paired = false
                        snap = null
                    }) { Text(context.getString(R.string.unpair)) }
                }
                Text(context.getString(R.string.language), color = Color(0xFFA8A29A))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("system" to R.string.lang_system, "en" to R.string.lang_en, "ko" to R.string.lang_ko).forEach { (id, label) ->
                        Button(onClick = {
                            SnapshotStore.setLanguage(context, id)
                            onLocale()
                        }) { Text(context.getString(label)) }
                    }
                }
                Text(context.getString(R.string.theme), color = Color(0xFFA8A29A))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("clean" to R.string.theme_clean, "matrix" to R.string.theme_matrix, "retro" to R.string.theme_retro).forEach { (id, label) ->
                        Button(onClick = {
                            SnapshotStore.setTheme(context, id)
                            Thread { runCatching { kotlinx.coroutines.runBlocking { updateWidgets(context) } } }.start()
                        }) { Text(context.getString(label)) }
                    }
                }
            }
        }
    }
}
