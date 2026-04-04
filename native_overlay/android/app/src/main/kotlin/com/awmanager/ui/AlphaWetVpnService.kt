package com.awmanager.ui

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat

class AlphaWetVpnService : VpnService() {
    companion object {
        private const val CHANNEL_ID = "alphawet_vpn"
        private const val NOTIFICATION_ID = 2308
        private const val ACTION_START = "alphawet.action.START"
        private const val ACTION_STOP = "alphawet.action.STOP"
        private const val EXTRA_HTTP_PORT = "httpPort"
        private const val EXTRA_SOCKS_PORT = "socksPort"

        @Volatile
        private var running: Boolean = false

        fun isRunning(): Boolean = running

        fun start(context: Context, httpPort: Int, socksPort: Int) {
            val intent = Intent(context, AlphaWetVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_HTTP_PORT, httpPort)
                putExtra(EXTRA_SOCKS_PORT, socksPort)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, AlphaWetVpnService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var currentHttpPort: Int = 10808
    private var currentSocksPort: Int = 10809

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                currentHttpPort = intent?.getIntExtra(EXTRA_HTTP_PORT, currentHttpPort) ?: currentHttpPort
                currentSocksPort = intent?.getIntExtra(EXTRA_SOCKS_PORT, currentSocksPort) ?: currentSocksPort
                val notification = buildNotification()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                startTunnel()
                return START_STICKY
            }
        }
    }

    override fun onRevoke() {
        stopTunnel()
        stopSelf()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    private fun startTunnel() {
        stopTunnel()
        val builder = Builder()
            .setSession("AlphaWet")
            .setMtu(1500)
            .addAddress("10.7.0.2", 32)
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")
            .addRoute("0.0.0.0", 0)

        runCatching {
            builder.addRoute("::", 0)
        }

        runCatching {
            builder.addDisallowedApplication(packageName)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setHttpProxy(ProxyInfo.buildDirectProxy("127.0.0.1", currentHttpPort))
        }

        vpnInterface = builder.establish()
        running = vpnInterface != null
    }

    private fun stopTunnel() {
        running = false
        runCatching { vpnInterface?.close() }
        vpnInterface = null
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun buildNotification() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.ic_lock_lock)
        .setContentTitle("AlphaWet")
        .setContentText("Whole-device tunnel is active")
        .setCategory(NotificationCompat.CATEGORY_SERVICE)
        .setOngoing(true)
        .setContentIntent(mainActivityPendingIntent())
        .build()

    private fun mainActivityPendingIntent(): PendingIntent {
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: Intent(this, MainActivity::class.java)
        intent.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        return PendingIntent.getActivity(this, 0, intent, flags)
    }

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "AlphaWet VPN",
                NotificationManager.IMPORTANCE_LOW,
            )
            manager.createNotificationChannel(channel)
        }
    }
}
