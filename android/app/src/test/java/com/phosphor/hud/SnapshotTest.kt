package com.phosphor.hud

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class SnapshotTest {
    @Test
    fun demoSnapshotUsesTheSharedFixture() {
        val start = File(System.getProperty("user.dir") ?: ".")
        val file = generateSequence(start) { it.parentFile }
            .map { File(it, "fixtures/sync/sample-snapshot.json") }
            .take(8)
            .firstOrNull { it.isFile }
            ?: error("fixture not found from $start")
        val snap = SnapshotJson.parse(file.readText())
        assertEquals("Demo", snap.hostName)
        assertEquals("Claude Code", snap.rows[0].name)
        assertEquals(62, snap.rows[0].windows[0].usedPercent)
        assertEquals(18, snap.rows[1].windows[0].usedPercent)
        assertEquals(false, snap.rows[0].windows[0].warns)
    }
}
