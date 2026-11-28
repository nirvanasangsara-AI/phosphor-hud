package com.phosphor.hud

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

data class PhoneWindow(
    val label: String,
    val usedPercent: Int,
    val kind: String,
    val resetsIn: String?,
    val forecastText: String?,
    val warns: Boolean,
    val amount: String?,
)

data class PhoneRow(
    val id: String,
    val name: String,
    val monogram: String,
    val color: String,
    val plan: String?,
    val status: String,
    val windows: List<PhoneWindow>,
)

data class PhoneSnapshot(
    val version: Int,
    val generatedAt: String,
    val hostName: String,
    val rows: List<PhoneRow>,
)

object SnapshotJson {
    private val json = Json { ignoreUnknownKeys = true }

    fun parse(text: String): PhoneSnapshot {
        val root = json.parseToJsonElement(text).jsonObject
        val rows = root["rows"]?.jsonArray.orEmpty().map { element ->
            val row = element.jsonObject
            val windows = row["windows"]?.jsonArray.orEmpty().map { wElement ->
                val w = wElement.jsonObject
                PhoneWindow(
                    label = w.str("label"),
                    usedPercent = w["usedPercent"]?.jsonPrimitive?.doubleOrNull?.toInt() ?: 0,
                    kind = w.str("kind").ifEmpty { "quota" },
                    resetsIn = w.str("resetsIn").ifEmpty { null },
                    forecastText = w.str("forecastText").ifEmpty { null },
                    warns = w["warns"]?.jsonPrimitive?.booleanOrNull ?: false,
                    amount = w.str("amount").ifEmpty { null },
                )
            }
            PhoneRow(
                id = row.str("id"),
                name = row.str("name"),
                monogram = row.str("monogram"),
                color = row.str("color").ifEmpty { "#D97757" },
                plan = row.str("plan").ifEmpty { null },
                status = row.str("status").ifEmpty { "ok" },
                windows = windows,
            )
        }
        return PhoneSnapshot(
            version = root["version"]?.jsonPrimitive?.doubleOrNull?.toInt() ?: 1,
            generatedAt = root.str("generatedAt"),
            hostName = root.str("hostName"),
            rows = rows,
        )
    }
}

private fun kotlinx.serialization.json.JsonObject.str(key: String): String =
    this[key]?.jsonPrimitive?.contentOrNull ?: ""
