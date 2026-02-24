package com.example.v2ray_box.bg

import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import com.example.v2ray_box.Settings
import com.example.v2ray_box.V2rayBoxPlugin
import com.example.v2ray_box.constant.Action
import com.example.v2ray_box.constant.Alert
import com.example.v2ray_box.constant.CoreEngine
import com.example.v2ray_box.constant.ServiceMode
import com.example.v2ray_box.constant.Status
import com.example.v2ray_box.utils.CommandClient
import com.example.v2ray_box.utils.SingboxConfigParser
import com.example.v2ray_box.utils.SingboxProcess
import com.example.v2ray_box.utils.XrayConfigParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray
import java.io.File

class BoxService(
    private val service: Service,
    private val platformInterface: PlatformInterfaceWrapper
) : CoreCallbackHandler {

    companion object {
        private const val TAG = "V2Ray/BoxService"

        private var initializeOnce = false
        private var workingDir: File? = null

        private fun getWorkingDir(context: Context): File {
            if (workingDir == null) {
                workingDir = context.getExternalFilesDir(null) ?: context.filesDir
                workingDir?.mkdirs()
            }
            return workingDir!!
        }

        private fun initialize(context: Context) {
            if (initializeOnce) return
            val wDir = getWorkingDir(context)
            Log.d(TAG, "working dir: ${wDir.path}")
            Libv2ray.initCoreEnv(wDir.path, "")
            initializeOnce = true
        }

        fun parseConfig(context: Context, configLink: String, debug: Boolean): String {
            return try {
                if (Settings.coreEngine == CoreEngine.SINGBOX) {
                    SingboxConfigParser.buildSingboxConfig(configLink)
                } else {
                    XrayConfigParser.buildXrayConfig(configLink)
                }
                ""
            } catch (e: Exception) {
                Log.w(TAG, "Config validation failed: ${e.message}", e)
                e.message ?: "invalid config"
            }
        }

        fun buildConfig(context: Context, configLink: String): String {
            val proxyOnly = Settings.serviceMode == ServiceMode.PROXY
            return if (Settings.coreEngine == CoreEngine.SINGBOX) {
                SingboxConfigParser.buildSingboxConfig(configLink, !proxyOnly)
            } else {
                XrayConfigParser.buildXrayConfig(configLink, proxyOnly)
            }
        }

        fun writeConfigFile(context: Context, configLink: String): String {
            val wDir = getWorkingDir(context)
            val proxyOnly = Settings.serviceMode == ServiceMode.PROXY
            val engine = Settings.coreEngine

            if (engine == CoreEngine.SINGBOX) {
                val config = SingboxConfigParser.buildSingboxConfig(configLink, false)
                val configFile = File(wDir, "singbox_config.json")
                configFile.writeText(config)
                Log.d(TAG, "Sing-box config written to: ${configFile.absolutePath}")

                if (!proxyOnly) {
                    val bridgeConfig = buildXrayTunBridge()
                    val bridgeFile = File(wDir, "active_config.json")
                    bridgeFile.writeText(bridgeConfig)
                    Log.d(TAG, "Xray TUN bridge config written")
                }

                return configFile.absolutePath
            } else {
                val config = XrayConfigParser.buildXrayConfig(configLink, proxyOnly)
                val configFile = File(wDir, "active_config.json")
                configFile.writeText(config)
                Log.d(TAG, "Config written to: ${configFile.absolutePath}")
                return configFile.absolutePath
            }
        }

        private fun buildXrayTunBridge(): String {
            val config = mapOf(
                "log" to mapOf("loglevel" to "warning"),
                "inbounds" to listOf(
                    mapOf(
                        "tag" to "tun",
                        "port" to 0,
                        "protocol" to "tun",
                        "settings" to mapOf(
                            "name" to "xray0",
                            "MTU" to 1500,
                            "userLevel" to 8
                        ),
                        "sniffing" to mapOf(
                            "enabled" to true,
                            "destOverride" to listOf("http", "tls")
                        )
                    )
                ),
                "outbounds" to listOf(
                    mapOf(
                        "tag" to "proxy",
                        "protocol" to "socks",
                        "settings" to mapOf(
                            "servers" to listOf(
                                mapOf(
                                    "address" to "127.0.0.1",
                                    "port" to 10808
                                )
                            )
                        )
                    ),
                    mapOf(
                        "tag" to "direct",
                        "protocol" to "freedom",
                        "settings" to mapOf("domainStrategy" to "UseIP")
                    )
                ),
                "routing" to mapOf(
                    "domainStrategy" to "AsIs",
                    "rules" to listOf(
                        mapOf(
                            "type" to "field",
                            "outboundTag" to "direct",
                            "ip" to listOf(
                                "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                                "127.0.0.0/8", "fc00::/7", "fe80::/10", "::1/128"
                            )
                        )
                    )
                ),
                "policy" to mapOf(
                    "levels" to mapOf(
                        "8" to mapOf(
                            "handshake" to 4,
                            "connIdle" to 300,
                            "uplinkOnly" to 1,
                            "downlinkOnly" to 1
                        )
                    )
                )
            )
            return com.google.gson.Gson().toJson(config)
        }

        fun writeJsonConfigFile(context: Context, configJson: String): String {
            val wDir = getWorkingDir(context)
            val configFile = File(wDir, "active_config.json")
            configFile.writeText(configJson)
            Log.d(TAG, "JSON config written to: ${configFile.absolutePath}")
            return configFile.absolutePath
        }

        fun start(context: Context) {
            val intent = runBlocking {
                withContext(Dispatchers.IO) {
                    Intent(context, Settings.serviceClass())
                }
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.sendBroadcast(
                Intent(Action.SERVICE_CLOSE).setPackage(context.packageName)
            )
        }

        fun reload(context: Context) {
            context.sendBroadcast(
                Intent(Action.SERVICE_RELOAD).setPackage(context.packageName)
            )
        }
    }

    var fileDescriptor: ParcelFileDescriptor? = null
    var coreController: CoreController? = null
        private set

    private val status = MutableLiveData(Status.Stopped)
    private val binder = ServiceBinder(status)
    private val notification = ServiceNotification(status, service)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var receiverRegistered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Action.SERVICE_CLOSE -> stopService()
                Action.SERVICE_RELOAD -> serviceReload()
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        serviceUpdateIdleMode()
                    }
                }
            }
        }
    }

    private var activeProfileName = ""

    @Suppress("DEPRECATION")
    private suspend fun startService() {
        try {
            if (coreController != null || SingboxProcess.isRunning || SingboxProcess.isProcessAlive) {
                Log.w(TAG, "Detected stale core state before start, forcing cleanup")
                stopCore(async = false, closeTun = true)
            }
            Log.d(TAG, "starting service (engine: ${Settings.coreEngine})")
            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, "Starting...")
            }

            val selectedConfigPath = Settings.activeConfigPath
            if (selectedConfigPath.isBlank()) {
                stopAndAlert(Alert.EmptyConfiguration)
                return
            }

            activeProfileName = Settings.activeProfileName

            if (!File(selectedConfigPath).exists()) {
                Log.w(TAG, "Config file not found: $selectedConfigPath")
                stopAndAlert(Alert.EmptyConfiguration, "Config file not found")
                return
            }

            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, "Starting...")
                binder.broadcast {
                    it.onServiceResetLogs(listOf())
                }
            }

            DefaultNetworkMonitor.start()
            Log.d(TAG, "DefaultNetworkMonitor started")

            val isVpnMode = Settings.serviceMode == ServiceMode.VPN
            val engine = Settings.coreEngine

            val started = if (engine == CoreEngine.SINGBOX) {
                startSingboxEngine(isVpnMode)
            } else {
                startXrayEngine(isVpnMode)
            }

            if (!started) return

            status.postValue(Status.Started)
            Log.d(TAG, "Service is now running (engine: $engine)")

            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, "Connected")
            }
            notification.start()
        } catch (e: Exception) {
            Log.e(TAG, "Unexpected error in startService", e)
            stopAndAlert(Alert.StartService, e.message)
        }
    }

    private suspend fun startXrayEngine(isVpnMode: Boolean): Boolean {
        val content = File(Settings.activeConfigPath).readText()

        var tunFd = 0
        if (isVpnMode) {
            val pfd = platformInterface.createTun()
            if (pfd == null) {
                stopAndAlert(Alert.StartService, "Failed to create TUN interface")
                return false
            }
            tunFd = pfd.fd
            Log.d(TAG, "TUN created with fd=$tunFd")
        }

        try {
            Log.d(TAG, "Starting Xray core...")
            val controller = Libv2ray.newCoreController(this)
            controller.startLoop(content, tunFd)
            if (!waitForCoreControllerReady(controller)) {
                throw IllegalStateException("Xray core did not enter running state")
            }
            coreController = controller
            CommandClient.activeCoreController = controller
            Log.d(TAG, "Xray core started successfully")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Xray core", e)
            platformInterface.closeTun()
            stopAndAlert(Alert.StartService, e.message)
            return false
        }
    }

    private suspend fun startSingboxEngine(isVpnMode: Boolean): Boolean {
        val singboxConfigPath = Settings.activeConfigPath
        Log.d(TAG, "Starting sing-box engine...")

        if (!SingboxProcess.start(service, singboxConfigPath)) {
            stopAndAlert(Alert.StartService, "Failed to start sing-box process")
            return false
        }
        if (!SingboxProcess.waitForMixedInboundReady()) {
            SingboxProcess.stop()
            stopAndAlert(Alert.StartService, "sing-box inbound not ready on 127.0.0.1:10808")
            return false
        }
        Log.d(TAG, "sing-box process started")

        if (isVpnMode) {
            val pfd = platformInterface.createTun()
            if (pfd == null) {
                SingboxProcess.stop()
                stopAndAlert(Alert.StartService, "Failed to create TUN interface")
                return false
            }
            val tunFd = pfd.fd
            Log.d(TAG, "TUN created with fd=$tunFd, starting Xray TUN bridge...")

            try {
                val wDir = getWorkingDir(service)
                val bridgeConfigFile = File(wDir, "active_config.json")
                if (!bridgeConfigFile.exists()) {
                    SingboxProcess.stop()
                    platformInterface.closeTun()
                    stopAndAlert(Alert.StartService, "TUN bridge config not found")
                    return false
                }
                val bridgeContent = bridgeConfigFile.readText()
                val controller = Libv2ray.newCoreController(this)
                controller.startLoop(bridgeContent, tunFd)
                if (!waitForCoreControllerReady(controller)) {
                    throw IllegalStateException("Xray TUN bridge did not enter running state")
                }
                coreController = controller
                Log.d(TAG, "Xray TUN bridge started for sing-box VPN mode")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start Xray TUN bridge", e)
                SingboxProcess.stop()
                platformInterface.closeTun()
                stopAndAlert(Alert.StartService, "TUN bridge failed: ${e.message}")
                return false
            }
        }
        return true
    }

    fun serviceReload() {
        notification.close()
        status.postValue(Status.Starting)

        stopCore(async = false, closeTun = true)

        runBlocking {
            DefaultNetworkMonitor.stop()
            startService()
        }
    }

    private fun stopCore(async: Boolean = true, closeTun: Boolean = true) {
        val controller = coreController
        coreController = null
        CommandClient.activeCoreController = null

        if (controller != null) {
            val stopRunner = {
                try {
                    controller.stopLoop()
                } catch (e: Exception) {
                    Log.w(TAG, "Error stopping xray core", e)
                }
            }
            if (async) {
                val stopThread = Thread({
                    try {
                        stopRunner()
                    } catch (e: Exception) {
                        Log.w(TAG, "Error in async xray stop thread", e)
                    }
                }, "xray-stop-thread")
                stopThread.isDaemon = true
                stopThread.start()
            } else {
                stopRunner()
            }
        }

        if (SingboxProcess.isRunning || SingboxProcess.isProcessAlive) {
            if (async) {
                val stopThread = Thread({
                    try {
                        SingboxProcess.stop()
                        Log.d(TAG, "sing-box process stopped")
                    } catch (e: Exception) {
                        Log.w(TAG, "Error stopping sing-box process", e)
                    }
                }, "singbox-stop-thread")
                stopThread.isDaemon = true
                stopThread.start()
            } else {
                SingboxProcess.stop()
                Log.d(TAG, "sing-box process stopped")
            }
        }

        if (closeTun) {
            platformInterface.closeTun()
            fileDescriptor = null
        }
    }

    private fun waitForCoreControllerReady(
        controller: CoreController,
        timeoutMs: Long = 2500L
    ): Boolean {
        val start = System.currentTimeMillis()
        while (System.currentTimeMillis() - start < timeoutMs) {
            if (controller.isRunning) return true
            Thread.sleep(80)
        }
        return controller.isRunning
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun serviceUpdateIdleMode() {
        V2rayBoxPlugin.powerManager?.let { pm ->
            if (pm.isDeviceIdleMode) {
                Log.d(TAG, "Device entered idle mode")
            } else {
                Log.d(TAG, "Device exited idle mode")
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun stopService() {
        if (status.value == Status.Stopped || status.value == Status.Stopping) return
        status.value = Status.Stopping
        if (receiverRegistered) {
            service.unregisterReceiver(receiver)
            receiverRegistered = false
        }
        notification.close()
        // Keep stop path fast like v2rayNG: request service stop early, then tear down cores asynchronously.
        service.stopSelf()
        // Close TUN immediately so Android removes VPN key icon as soon as possible.
        platformInterface.closeTun()
        fileDescriptor = null
        GlobalScope.launch(Dispatchers.IO) {
            stopCore(async = true, closeTun = false)
            DefaultNetworkMonitor.stop()

            Settings.startedByUser = false
            status.postValue(Status.Stopped)
        }
    }

    private suspend fun stopAndAlert(type: Alert, message: String? = null) {
        Settings.startedByUser = false
        platformInterface.closeTun()
        fileDescriptor = null
        stopCore(async = true, closeTun = false)
        DefaultNetworkMonitor.stop()
        withContext(Dispatchers.Main) {
            if (receiverRegistered) {
                service.unregisterReceiver(receiver)
                receiverRegistered = false
            }
            notification.close()
            binder.broadcast { callback ->
                callback.onServiceAlert(type.ordinal, message)
            }
            status.value = Status.Stopped
            service.stopSelf()
        }
    }

    @Suppress("DEPRECATION")
    fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (status.value != Status.Stopped) return Service.START_NOT_STICKY
        status.value = Status.Starting

        if (!receiverRegistered) {
            ContextCompat.registerReceiver(service, receiver, IntentFilter().apply {
                addAction(Action.SERVICE_CLOSE)
                addAction(Action.SERVICE_RELOAD)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                }
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }

        GlobalScope.launch(Dispatchers.IO) {
            Settings.startedByUser = true
            initialize(service)
            startService()
        }
        return Service.START_NOT_STICKY
    }

    fun onBind(intent: Intent): IBinder {
        return binder
    }

    fun onDestroy() {
        if (receiverRegistered) {
            runCatching { service.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        notification.close()
        platformInterface.closeTun()
        fileDescriptor = null
        stopCore(async = true, closeTun = false)
        GlobalScope.launch(Dispatchers.IO) {
            DefaultNetworkMonitor.stop()
        }
        status.postValue(Status.Stopped)
        binder.close()
    }

    fun onRevoke() {
        stopService()
    }

    // CoreCallbackHandler implementation

    override fun startup(): Long {
        Log.d(TAG, "CoreCallbackHandler: startup")
        return 0
    }

    override fun shutdown(): Long {
        Log.d(TAG, "CoreCallbackHandler: shutdown")
        mainHandler.post {
            stopService()
        }
        return 0
    }

    override fun onEmitStatus(status: Long, message: String?): Long {
        Log.d(TAG, "CoreCallbackHandler: onEmitStatus status=$status, msg=$message")
        binder.broadcast {
            it.onServiceWriteLog(message ?: "")
        }
        if (message?.contains("core stopped", ignoreCase = true) == true) {
            mainHandler.post {
                stopService()
            }
        }
        return 0
    }
}
