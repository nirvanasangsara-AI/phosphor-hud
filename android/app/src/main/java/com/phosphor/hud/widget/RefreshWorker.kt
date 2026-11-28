package com.phosphor.hud.widget

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        runCatching { com.phosphor.hud.SnapshotStore.refresh(applicationContext) }
        updateWidgets(applicationContext)
        return Result.success()
    }
}
