package com.awmanager.ui

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.util.concurrent.Executors

class AlphaWetProxyService : Service() {
    companion object {
        const val ACTION_START = "alphawet.action.START_PROXY"
        const val ACTION_STOP = "alphawet.action.STOP_PROXY"
        private const val NOTIFICATION_CHANNEL_ID = "alphawet_proxy"
        private const val NOTIFICATION_ID = 2381
    }

    private val executor = Executors.newSingleThreadExecutor()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                executor.execute {
                    stopRuntime()
                }
                return START_NOT_STICKY
            }

            ACTION_START -> {
                startForegroundCompat(buildNotification("Starting AlphaWet local proxy..."))
                val workIntent = Intent(intent)
                executor.execute {
                    startRuntime(workIntent, startId)
                }
                return START_STICKY
            }
        }
        return START_STICKY
    }

    private fun startRuntime(intent: Intent, startId: Int) {
        try {
            val bundle = RuntimeBundleFactory.fromIntent(this, intent).copy(enableDeviceVpn = false)
            val result = XrayCoreRuntimeManager.start(bundle = bundle, tunFd = -1)
            if (result["success"] == true) {
                val label = bundle.displayName.ifBlank { "AlphaWet" }
                val text = "AlphaWet local proxy is active through $label."
                val manager = getSystemService(NotificationManager::class.java)
                manager.notify(NOTIFICATION_ID, buildNotification(text))
            } else {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelfResult(startId)
            }
        } catch (error: Throwable) {
            XrayCoreRuntimeManager.recordFailure(
                message = error.message ?: error.javaClass.simpleName,
                logFile = null,
            )
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelfResult(startId)
        }
    }

    private fun stopRuntime() {
        XrayCoreRuntimeManager.stop("local-proxy")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(text: String): Notification {
        ensureNotificationChannel()
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("AlphaWet")
            .setContentText(text)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(pendingIntent)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) {
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "AlphaWet Proxy",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Foreground notification for the AlphaWet local proxy"
            },
        )
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdownNow()
    }
}
