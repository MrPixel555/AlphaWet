package com.awmanager.ui

object XrayNativeBridge {
    init {
        System.loadLibrary("xrayjni")
    }

    external fun validate(
        binaryPath: String,
        configPath: String,
        assetDir: String,
        workingDir: String,
        logPath: String,
    ): Int

    external fun start(
        binaryPath: String,
        configPath: String,
        assetDir: String,
        workingDir: String,
        logPath: String,
        tunFd: Int,
    ): Long

    external fun stop(pid: Long): Boolean

    external fun isRunning(pid: Long): Boolean
}
