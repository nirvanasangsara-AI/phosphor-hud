package com.phosphor.hud.widget

import android.content.Context
import android.content.Intent
import androidx.compose.ui.graphics.Color as ComposeColor
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.action.ActionParameters
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Column
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.phosphor.hud.MainActivity
import com.phosphor.hud.SnapshotStore

class PhosphorWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snap = SnapshotStore.load(context)
        val theme = themeColors(SnapshotStore.theme(context))
        val demo = SnapshotStore.demo(context)
        val open = Intent(context, MainActivity::class.java)
        provideContent {
            Column(
                modifier = GlanceModifier
                    .fillMaxWidth()
                    .background(ColorProvider(theme.bg))
                    .padding(12.dp)
                    .clickable(actionStartActivity(open))
            ) {
                Text(
                    text = if (demo) "Φ  Demo" else "Φ",
                    style = TextStyle(
                        color = ColorProvider(theme.phi),
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                    )
                )
                if (snap == null || snap.rows.isEmpty()) {
                    Spacer(GlanceModifier.height(8.dp))
                    Text(
                        text = if (SnapshotStore.language(context) == "ko") "연결하려면 Phosphor를 여세요" else "Open Phosphor to pair",
                        style = TextStyle(color = ColorProvider(theme.dim), fontSize = 13.sp)
                    )
                } else {
                    snap.rows.take(4).forEach { row ->
                        val window = row.windows.firstOrNull()
                        Spacer(GlanceModifier.height(8.dp))
                        Text(
                            text = row.name + (window?.let { "  ${it.label} ${it.usedPercent}%" } ?: ""),
                            style = TextStyle(color = ColorProvider(theme.fg), fontSize = 13.sp, fontWeight = FontWeight.Medium),
                            maxLines = 1,
                        )
                        if (window != null && window.kind != "meter") {
                            Spacer(GlanceModifier.height(4.dp))
                            LinearProgressIndicator(
                                progress = (window.usedPercent.coerceIn(0, 100) / 100f),
                                modifier = GlanceModifier.fillMaxWidth(),
                                color = ColorProvider(if (window.warns) theme.warn else theme.phi),
                                backgroundColor = ColorProvider(theme.track),
                            )
                        }
                    }
                }
                Spacer(GlanceModifier.height(8.dp))
                Text(
                    text = if (SnapshotStore.language(context) == "ko") "새로고침" else "Refresh",
                    style = TextStyle(color = ColorProvider(theme.phi), fontSize = 12.sp),
                    modifier = GlanceModifier.clickable(actionRunCallback<RefreshAction>()),
                )
            }
        }
    }
}

class PhosphorWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = PhosphorWidget()
}

class RefreshAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        runCatching { SnapshotStore.refresh(context) }
        PhosphorWidget().update(context, glanceId)
    }
}

data class WidgetColors(val bg: ComposeColor, val fg: ComposeColor, val dim: ComposeColor, val phi: ComposeColor, val warn: ComposeColor, val track: ComposeColor)

fun themeColors(name: String): WidgetColors = when (name) {
    "matrix" -> WidgetColors(
        ComposeColor(0xFF041208), ComposeColor(0xFFB6F5C2), ComposeColor(0xFF6FBF7A),
        ComposeColor(0xFF39FF6A), ComposeColor(0xFFFFB020), ComposeColor(0xFF12301A)
    )
    "retro" -> WidgetColors(
        ComposeColor(0xFF1A1004), ComposeColor(0xFFFFE0A3), ComposeColor(0xFFC9A36A),
        ComposeColor(0xFFFFB000), ComposeColor(0xFFFF5A36), ComposeColor(0xFF3A2A10)
    )
    else -> WidgetColors(
        ComposeColor(0xFF12141A), ComposeColor(0xFFF4F1EA), ComposeColor(0xFFA8A29A),
        ComposeColor(0xFFF4C46A), ComposeColor(0xFFF07167), ComposeColor(0xFF2A2E36)
    )
}

suspend fun updateWidgets(context: Context) {
    val widget = PhosphorWidget()
    for (id in GlanceAppWidgetManager(context).getGlanceIds(PhosphorWidget::class.java)) {
        widget.update(context, id)
    }
}
