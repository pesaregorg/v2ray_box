package com.example.v2ray_box

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.ComponentCallbacks2
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.ConnectivityManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.util.Base64
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.getSystemService
import androidx.lifecycle.MutableLiveData
import com.example.v2ray_box.bg.BoxService
import com.example.v2ray_box.bg.PlatformInterfaceWrapper
import com.example.v2ray_box.bg.ServiceConnection
import com.example.v2ray_box.constant.Alert
import com.example.v2ray_box.constant.CoreEngine
import com.example.v2ray_box.constant.ServiceMode
import com.example.v2ray_box.constant.Status
import com.example.v2ray_box.utils.CommandClient
import com.example.v2ray_box.utils.ConfigParser
import com.example.v2ray_box.utils.SingboxProcess
import com.example.v2ray_box.utils.XrayConfigParser
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.google.gson.annotations.SerializedName
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.JSONMethodCodec
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import libv2ray.Libv2ray
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.ServerSocket
import java.util.LinkedList
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class V2rayBoxPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener, ServiceConnection.Callback, CommandClient.Handler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var statusChannel: EventChannel
    private lateinit var alertsChannel: EventChannel
    private lateinit var statsChannel: EventChannel
    private lateinit var pingChannel: EventChannel
    private lateinit var logsChannel: EventChannel

    private var activity: Activity? = null
    private var connection: ServiceConnection? = null
    private var scope: CoroutineScope = GlobalScope

    private val logList = LinkedList<String>()
    val serviceStatus = MutableLiveData(Status.Stopped)
    val serviceAlerts = MutableLiveData<ServiceEvent?>(null)

    private var statusEventSink: EventChannel.EventSink? = null
    private var alertsEventSink: EventChannel.EventSink? = null
    private var statsEventSink: EventChannel.EventSink? = null
    private var pingEventSink: EventChannel.EventSink? = null
    private var logsEventSink: EventChannel.EventSink? = null

    private var statsCommandClient: CommandClient? = null
    private var logsCommandClient: CommandClient? = null
    private val pingSessionId = AtomicLong(0L)
    private val pingExecutors = Collections.newSetFromMap(ConcurrentHashMap<ExecutorService, Boolean>())
    private var componentCallbacksRegistered = false
    private var activityCallbacksRegistered = false
    private var startedActivityCount = 0
    private val appComponentCallbacks = object : ComponentCallbacks2 {
        override fun onConfigurationChanged(newConfig: Configuration) = Unit
        override fun onLowMemory() = Unit

        override fun onTrimMemory(level: Int) {
            if (level >= ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) {
                cancelActivePing("app moved to background")
            }
        }
    }
    private val appActivityCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityResumed(activity: Activity) = Unit
        override fun onActivityPaused(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit

        override fun onActivityStarted(activity: Activity) {
            startedActivityCount++
        }

        override fun onActivityStopped(activity: Activity) {
            startedActivityCount = (startedActivityCount - 1).coerceAtLeast(0)
            if (startedActivityCount == 0) {
                cancelActivePing("all activities stopped")
            }
        }
    }

    companion object {
        private const val TAG = "V2rayBoxPlugin"
        private const val CHANNEL_NAME = "v2ray_box"
        private const val STATUS_CHANNEL = "v2ray_box/status"
        private const val ALERTS_CHANNEL = "v2ray_box/alerts"
        private const val STATS_CHANNEL = "v2ray_box/stats"
        private const val PING_CHANNEL = "v2ray_box/ping"
        private const val LOGS_CHANNEL = "v2ray_box/logs"
        private const val DEFAULT_PING_TIMEOUT_MS = 7000
        private const val MIN_PING_TIMEOUT_MS = 1000
        private const val MAX_PING_TIMEOUT_MS = 30000
        private const val PING_TASK_GRACE_MS = 1200L
        private const val PING_MAX_PARALLEL_TASKS = 4
        private const val PING_EXECUTOR_DRAIN_WAIT_MS = 200L
        private const val SERVICE_RESTART_SETTLE_MS = 400L

        const val VPN_PERMISSION_REQUEST_CODE = 1001
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1010

        var applicationContext: Context? = null
            private set
        var connectivity: ConnectivityManager? = null
            private set
        var packageManager: PackageManager? = null
            private set
        var powerManager: PowerManager? = null
            private set
        var notificationManager: NotificationManager? = null
            private set

        private val gson = Gson()
        private val prettyGson = GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create()
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        connectivity = applicationContext?.getSystemService()
        packageManager = applicationContext?.packageManager
        powerManager = applicationContext?.getSystemService()
        notificationManager = applicationContext?.getSystemService()
        if (!componentCallbacksRegistered) {
            applicationContext?.registerComponentCallbacks(appComponentCallbacks)
            componentCallbacksRegistered = true
        }
        val app = applicationContext as? Application
        if (!activityCallbacksRegistered && app != null) {
            app.registerActivityLifecycleCallbacks(appActivityCallbacks)
            activityCallbacksRegistered = true
            startedActivityCount = 0
        }

        Settings.init(flutterPluginBinding.applicationContext)

        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL_NAME)
        methodChannel.setMethodCallHandler(this)

        statusChannel = EventChannel(
            flutterPluginBinding.binaryMessenger,
            STATUS_CHANNEL,
            JSONMethodCodec.INSTANCE
        )
        statusChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                statusEventSink = events
                events?.success(mapOf("status" to serviceStatus.value?.name))
            }

            override fun onCancel(arguments: Any?) {
                statusEventSink = null
            }
        })

        alertsChannel = EventChannel(
            flutterPluginBinding.binaryMessenger,
            ALERTS_CHANNEL,
            JSONMethodCodec.INSTANCE
        )
        alertsChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                alertsEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                alertsEventSink = null
            }
        })

        statsChannel = EventChannel(
            flutterPluginBinding.binaryMessenger,
            STATS_CHANNEL,
            JSONMethodCodec.INSTANCE
        )
        statsChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                statsEventSink = events
                statsCommandClient = CommandClient(scope, CommandClient.ConnectionType.Status, this@V2rayBoxPlugin)
                statsCommandClient?.connect()
            }

            override fun onCancel(arguments: Any?) {
                statsEventSink = null
                statsCommandClient?.disconnect()
                statsCommandClient = null
            }
        })

        pingChannel = EventChannel(
            flutterPluginBinding.binaryMessenger,
            PING_CHANNEL,
            JSONMethodCodec.INSTANCE
        )
        pingChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                pingEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                pingEventSink = null
                cancelActivePing("ping stream cancelled")
            }
        })

        logsChannel = EventChannel(
            flutterPluginBinding.binaryMessenger,
            LOGS_CHANNEL,
            JSONMethodCodec.INSTANCE
        )
        logsChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                logsEventSink = events
                logsCommandClient = CommandClient(scope, CommandClient.ConnectionType.Log, this@V2rayBoxPlugin)
                logsCommandClient?.connect()
            }

            override fun onCancel(arguments: Any?) {
                logsEventSink = null
                logsCommandClient?.disconnect()
                logsCommandClient = null
            }
        })

        serviceStatus.observeForever { status ->
            activity?.runOnUiThread {
                statusEventSink?.success(mapOf("status" to status.name))
            }
            if (status == Status.Started && statsEventSink != null) {
                scope.launch(Dispatchers.IO) {
                    delay(500)
                    statsCommandClient?.disconnect()
                    statsCommandClient = CommandClient(scope, CommandClient.ConnectionType.Status, this@V2rayBoxPlugin)
                    statsCommandClient?.connect()
                }
            }
            if (status == Status.Started && logsEventSink != null) {
                scope.launch(Dispatchers.IO) {
                    delay(500)
                    logsCommandClient?.disconnect()
                    logsCommandClient = CommandClient(scope, CommandClient.ConnectionType.Log, this@V2rayBoxPlugin)
                    logsCommandClient?.connect()
                }
            }
        }

        serviceAlerts.observeForever { event ->
            if (event != null) {
                activity?.runOnUiThread {
                    alertsEventSink?.success(
                        mapOf(
                            "status" to event.status.name,
                            "alert" to event.alert?.name,
                            "message" to event.message
                        ).filterValues { it != null }
                    )
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cancelActivePing("engine detached")
        methodChannel.setMethodCallHandler(null)
        statusChannel.setStreamHandler(null)
        alertsChannel.setStreamHandler(null)
        statsChannel.setStreamHandler(null)
        pingChannel.setStreamHandler(null)
        logsChannel.setStreamHandler(null)
        statsCommandClient?.disconnect()
        logsCommandClient?.disconnect()
        if (componentCallbacksRegistered) {
            applicationContext?.unregisterComponentCallbacks(appComponentCallbacks)
            componentCallbacksRegistered = false
        }
        val app = applicationContext as? Application
        if (activityCallbacksRegistered && app != null) {
            app.unregisterActivityLifecycleCallbacks(appActivityCallbacks)
            activityCallbacksRegistered = false
            startedActivityCount = 0
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
        connection = ServiceConnection(activity!!, this)
        connection?.reconnect()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        cancelActivePing("activity detached")
        connection?.disconnect()
        connection = null
        activity = null
    }

    override fun updateStatus(uplink: Long, downlink: Long, uplinkTotal: Long, downlinkTotal: Long) {
        val map = mapOf(
            "connections-in" to 0L,
            "connections-out" to 0L,
            "uplink" to uplink,
            "downlink" to downlink,
            "uplink-total" to uplinkTotal,
            "downlink-total" to downlinkTotal
        )
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            statsEventSink?.success(map)
        }
    }

    override fun onServiceStatusChanged(status: Status) {
        serviceStatus.postValue(status)
    }

    override fun onServiceAlert(type: Alert, message: String?) {
        serviceAlerts.postValue(ServiceEvent(Status.Stopped, type, message))
    }

    override fun onServiceWriteLog(message: String?) {
        if (message != null) {
            if (logList.size > 300) {
                logList.removeFirst()
            }
            logList.addLast(message)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                logsEventSink?.success(mapOf("message" to message))
            }
        }
    }

    override fun onServiceResetLogs(messages: MutableList<String>) {
        logList.clear()
        logList.addAll(messages)
    }

    override fun clearLog() {
        logList.clear()
    }

    override fun appendLogs(messages: List<String>) {
        for (msg in messages) {
            if (logList.size > 300) logList.removeFirst()
            logList.addLast(msg)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                logsEventSink?.success(mapOf("message" to msg))
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> {
                result.success("Android ${Build.VERSION.RELEASE}")
            }

            "setup" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val context = applicationContext ?: return@runCatching
                        val workingDir = context.getExternalFilesDir(null) ?: context.filesDir
                        workingDir.mkdirs()
                        runCatching {
                            Libv2ray.initCoreEnv(workingDir.path, "")
                        }
                        success("")
                    }
                }
            }

            "parse_config" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val context = applicationContext ?: run {
                            error("no_context", "Application context not available", null)
                            return@runCatching
                        }
                        val args = call.arguments as Map<*, *>
                        val configLink = args["link"] as String
                        val debug = args["debug"] as? Boolean ?: false
                        val msg = BoxService.parseConfig(context, configLink, debug)
                        success(msg)
                    }
                }
            }

            "change_config_options" -> {
                scope.launch {
                    result.runCatching {
                        val args = call.arguments as String
                        Settings.configOptions = args
                        success(true)
                    }
                }
            }

            "generate_config" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val context = applicationContext ?: run {
                            error("no_context", "Application context not available", null)
                            return@runCatching
                        }
                        val args = call.arguments as Map<*, *>
                        val configLink = args["link"] as String
                        if (configLink.isBlank()) {
                            error("blank properties", "blank properties", null)
                            return@runCatching
                        }
                        val config = BoxService.buildConfig(context, configLink)
                        success(config)
                    }
                }
            }

            "start" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val context = applicationContext ?: run {
                            error("no_context", "Application context not available", null)
                            return@runCatching
                        }
                        val args = call.arguments as Map<*, *>
                        val configLink = args["link"] as String? ?: ""

                        val configPath = BoxService.writeConfigFile(context, configLink)
                        Settings.activeConfigPath = configPath
                        Settings.activeProfileName = args["name"] as String? ?: ""

                        if (isServiceActive()) {
                            Log.w(TAG, "start requested while service is active, restarting service")
                            BoxService.stop(context)
                            waitForServiceStopped()
                            delay(SERVICE_RESTART_SETTLE_MS)
                        }
                        startService()
                        success(true)
                    }
                }
            }

            "request_vpn_permission" -> {
                scope.launch(Dispatchers.Main) {
                    result.runCatching {
                        val act = activity
                        if (act == null) {
                            error("no_activity", "Activity not available", null)
                            return@runCatching
                        }
                        val intent = VpnService.prepare(act)
                        if (intent != null) {
                            act.startActivityForResult(intent, VPN_PERMISSION_REQUEST_CODE)
                            success(false)
                        } else {
                            success(true)
                        }
                    }
                }
            }

            "check_vpn_permission" -> {
                scope.launch(Dispatchers.Main) {
                    result.runCatching {
                        val act = activity
                        if (act == null) {
                            success(false)
                            return@runCatching
                        }
                        val intent = VpnService.prepare(act)
                        success(intent == null)
                    }
                }
            }

            "stop" -> {
                scope.launch {
                    result.runCatching {
                        cancelActivePing("vpn stop requested")
                        val started = serviceStatus.value == Status.Started
                        if (!started) {
                            Log.w(TAG, "service is not running")
                            success(true)
                            return@runCatching
                        }
                        applicationContext?.let { BoxService.stop(it) }
                        success(true)
                    }
                }
            }

            "restart" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val context = applicationContext ?: run {
                            error("no_context", "Application context not available", null)
                            return@runCatching
                        }
                        val args = call.arguments as Map<*, *>
                        val configLink = args["link"] as String? ?: ""

                        val configPath = BoxService.writeConfigFile(context, configLink)
                        Settings.activeConfigPath = configPath
                        Settings.activeProfileName = args["name"] as String? ?: ""

                        val started = serviceStatus.value == Status.Started
                        if (!started) {
                            success(true)
                            return@runCatching
                        }
                        val restart = Settings.rebuildServiceMode()
                        if (restart) {
                            connection?.reconnect()
                        }
                        BoxService.stop(context)
                        waitForServiceStopped()
                        delay(SERVICE_RESTART_SETTLE_MS)
                        startService()
                        success(true)
                    }
                }
            }

            "set_service_mode" -> {
                val mode = call.arguments as String
                Settings.serviceMode = mode
                result.success(true)
            }

            "get_service_mode" -> {
                result.success(Settings.serviceMode)
            }

            "set_notification_stop_button_text" -> {
                val text = call.arguments as String
                Settings.notificationStopButtonText = text
                result.success(true)
            }

            "set_notification_title" -> {
                val title = call.arguments as String
                Settings.notificationTitle = title
                result.success(true)
            }

            "set_notification_icon" -> {
                val iconName = call.arguments as String
                Settings.notificationIconName = iconName
                result.success(true)
            }

            "get_installed_packages" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val pm = packageManager ?: return@runCatching
                        val context = applicationContext ?: return@runCatching
                        val flag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            PackageManager.GET_PERMISSIONS or PackageManager.MATCH_UNINSTALLED_PACKAGES
                        } else {
                            @Suppress("DEPRECATION")
                            PackageManager.GET_PERMISSIONS or PackageManager.GET_UNINSTALLED_PACKAGES
                        }
                        val installedPackages =
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                pm.getInstalledPackages(PackageManager.PackageInfoFlags.of(flag.toLong()))
                            } else {
                                @Suppress("DEPRECATION")
                                pm.getInstalledPackages(flag)
                            }
                        val list = mutableListOf<AppItem>()
                        installedPackages.forEach { packageInfo ->
                            val appInfo = packageInfo.applicationInfo
                            if (packageInfo.packageName != context.packageName && appInfo != null &&
                                (packageInfo.requestedPermissions?.contains(Manifest.permission.INTERNET) == true
                                        || packageInfo.packageName == "android")
                            ) {
                                list.add(
                                    AppItem(
                                        packageInfo.packageName,
                                        appInfo.loadLabel(pm).toString(),
                                        appInfo.flags and ApplicationInfo.FLAG_SYSTEM == 1
                                    )
                                )
                            }
                        }
                        list.sortBy { it.name }
                        success(gson.toJson(list))
                    }
                }
            }

            "get_package_icon" -> {
                result.runCatching {
                    val args = call.arguments as Map<*, *>
                    val packageName = args["packageName"] as String
                    val pm = packageManager ?: return
                    val drawable = pm.getApplicationIcon(packageName)
                    val bitmap = Bitmap.createBitmap(
                        drawable.intrinsicWidth,
                        drawable.intrinsicHeight,
                        Bitmap.Config.ARGB_8888
                    )
                    val canvas = Canvas(bitmap)
                    drawable.setBounds(0, 0, canvas.width, canvas.height)
                    drawable.draw(canvas)
                    val byteArrayOutputStream = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, byteArrayOutputStream)
                    val base64: String =
                        Base64.encodeToString(byteArrayOutputStream.toByteArray(), Base64.NO_WRAP)
                    success(base64)
                }
            }

            "url_test" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val args = call.arguments as Map<*, *>
                        val link = args["link"] as String
                        val timeout = parsePingTimeout(args["timeout"])
                        val sessionId = beginPingSession()

                        try {
                            val delay = testConfigLink(link, timeout, sessionId)
                            success(delay)
                        } catch (e: Exception) {
                            Log.e(TAG, "URL test failed: ${e.message}")
                            success(-1L)
                        }
                    }
                }
            }

            "url_test_all" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val args = call.arguments as Map<*, *>
                        @Suppress("UNCHECKED_CAST")
                        val links = args["links"] as List<String>
                        val timeout = parsePingTimeout(args["timeout"])
                        val sessionId = beginPingSession()

                        val results = testConfigLinksParallel(links, timeout, sessionId)
                        success(results)
                    }
                }
            }

            "set_per_app_proxy_mode" -> {
                val mode = call.arguments as String
                Settings.perAppProxyMode = mode
                result.success(true)
            }

            "get_per_app_proxy_mode" -> {
                result.success(Settings.perAppProxyMode)
            }

            "set_per_app_proxy_list" -> {
                val args = call.arguments as Map<*, *>
                @Suppress("UNCHECKED_CAST")
                val list = args["list"] as List<String>
                val mode = args["mode"] as String
                Settings.setPerAppProxyList(list, mode)
                result.success(true)
            }

            "get_per_app_proxy_list" -> {
                val mode = call.argument<String>("mode") ?: Settings.perAppProxyMode
                result.success(Settings.getPerAppProxyList(mode))
            }

            "get_total_traffic" -> {
                result.success(mapOf(
                    "upload" to Settings.totalUploadTraffic,
                    "download" to Settings.totalDownloadTraffic
                ))
            }

            "reset_total_traffic" -> {
                Settings.resetTrafficStats()
                result.success(true)
            }

            "get_core_info" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val engine = Settings.coreEngine
                        val info = mutableMapOf<String, Any>(
                            "core" to engine
                        )
                        if (engine == CoreEngine.SINGBOX) {
                            info["engine"] = "sing-box"
                            try {
                                val ctx = applicationContext
                                if (ctx != null) {
                                    val ver = SingboxProcess.getVersion(ctx)
                                    if (ver.isNotEmpty()) info["version"] = ver
                                }
                            } catch (_: Exception) {}
                        } else {
                            info["engine"] = "xray-core"
                            try {
                                val version = Libv2ray.checkVersionX()
                                if (!version.isNullOrEmpty()) info["version"] = version
                            } catch (_: Exception) {}
                        }
                        success(info)
                    }
                }
            }

            "set_core_engine" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val context = applicationContext ?: run {
                            error("no_context", "Application context not available", null)
                            return@runCatching
                        }
                        val engine = (call.arguments as String).trim().lowercase()
                        if (engine != CoreEngine.XRAY && engine != CoreEngine.SINGBOX) {
                            error("invalid_engine", "Engine must be 'xray' or 'singbox'", null)
                            return@runCatching
                        }
                        if (Settings.coreEngine == engine) {
                            success(true)
                            return@runCatching
                        }

                        cancelActivePing("core switch requested")
                        if (isServiceActive()) {
                            Log.d(TAG, "Stopping service before switching core to $engine")
                            BoxService.stop(context)
                            waitForServiceStopped()
                            delay(SERVICE_RESTART_SETTLE_MS)
                        }
                        if (SingboxProcess.isRunning || SingboxProcess.isProcessAlive) {
                            Log.d(TAG, "Stopping stale sing-box process before core switch")
                            SingboxProcess.stop()
                        }
                        CommandClient.activeCoreController = null
                        Settings.coreEngine = engine
                        success(true)
                    }
                }
            }

            "get_core_engine" -> {
                result.success(Settings.coreEngine)
            }

            "check_config_json" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val configJson = call.arguments as String
                        try {
                            gson.fromJson(configJson, Map::class.java)
                            success("")
                        } catch (e: Exception) {
                            success(e.message ?: "Invalid JSON config")
                        }
                    }
                }
            }

            "start_with_json" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val context = applicationContext ?: run {
                            error("no_context", "Application context not available", null)
                            return@runCatching
                        }
                        val args = call.arguments as Map<*, *>
                        val configJson = args["config"] as String
                        val name = args["name"] as String? ?: ""

                        try {
                            gson.fromJson(configJson, Map::class.java)
                        } catch (e: Exception) {
                            error("INVALID_CONFIG", "Config validation failed: ${e.message}", null)
                            return@runCatching
                        }

                        val configPath = BoxService.writeJsonConfigFile(context, configJson)
                        Settings.activeConfigPath = configPath
                        Settings.activeProfileName = name

                        if (isServiceActive()) {
                            Log.w(TAG, "start_with_json requested while service is active, restarting service")
                            BoxService.stop(context)
                            waitForServiceStopped()
                            delay(SERVICE_RESTART_SETTLE_MS)
                        }
                        startService()
                        success(true)
                    }
                }
            }

            "get_logs" -> {
                result.success(logList.toList())
            }

            "set_debug_mode" -> {
                val enabled = call.arguments as Boolean
                Settings.debugMode = enabled
                result.success(true)
            }

            "get_debug_mode" -> {
                result.success(Settings.debugMode)
            }

            "format_bytes" -> {
                val bytes = (call.arguments as Number).toLong()
                result.success(formatBytes(bytes))
            }

            "get_active_config" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val configPath = Settings.activeConfigPath
                        if (configPath.isNotEmpty()) {
                            val file = File(configPath)
                            if (file.exists()) {
                                success(file.readText())
                            } else {
                                success("")
                            }
                        } else {
                            success("")
                        }
                    }
                }
            }

            "proxy_display_type" -> {
                val type = call.arguments as String
                val displayName = when (type.lowercase()) {
                    "vless" -> "VLESS"
                    "vmess" -> "VMess"
                    "trojan" -> "Trojan"
                    "shadowsocks", "ss" -> "Shadowsocks"
                    "hysteria2", "hy2" -> "Hysteria2"
                    "hysteria", "hy" -> "Hysteria"
                    "wireguard", "wg" -> "WireGuard"
                    "tuic" -> "TUIC"
                    "ssh" -> "SSH"
                    "socks", "socks5" -> "SOCKS5"
                    "http" -> "HTTP"
                    else -> type
                }
                result.success(displayName)
            }

            "format_config" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val configJson = call.arguments as String
                        try {
                            val parsed = gson.fromJson(configJson, Map::class.java)
                            val formatted = prettyGson.toJson(parsed)
                            success(formatted)
                        } catch (e: Exception) {
                            success(configJson)
                        }
                    }
                }
            }

            "available_port" -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val startPort = (call.arguments as Number).toInt()
                        try {
                            var port = startPort
                            while (port < 65535) {
                                try {
                                    ServerSocket(port).use { }
                                    success(port)
                                    return@runCatching
                                } catch (e: Exception) {
                                    port++
                                }
                            }
                            success(-1)
                        } catch (e: Exception) {
                            success(-1)
                        }
                    }
                }
            }

            "select_outbound" -> {
                result.success(true)
            }

            "set_clash_mode" -> {
                result.success(true)
            }

            "parse_subscription" -> {
                result.error("NOT_SUPPORTED", "Subscription parsing not supported with Xray core", null)
            }

            "generate_subscription_link" -> {
                result.error("NOT_SUPPORTED", "Subscription link generation not supported with Xray core", null)
            }

            "set_locale" -> {
                result.success(true)
            }

            "set_ping_test_url" -> {
                val url = call.arguments as String
                Settings.pingTestUrl = url
                result.success(true)
            }

            "get_ping_test_url" -> {
                result.success(Settings.pingTestUrl)
            }

            else -> {
                result.notImplemented()
            }
        }
    }

    private fun startService() {
        if (!checkNotificationPermission()) {
            grantNotificationPermission()
            return
        }
        scope.launch(Dispatchers.IO) {
            if (Settings.rebuildServiceMode()) {
                connection?.reconnect()
            }
            if (Settings.serviceMode == ServiceMode.VPN) {
                if (prepareVpn()) {
                    Log.d(TAG, "VPN permission required")
                    return@launch
                }
            }
            applicationContext?.let { BoxService.start(it) }
        }
    }

    private fun checkNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        return notificationManager?.areNotificationsEnabled() ?: false
    }

    private fun grantNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity?.let {
                ActivityCompat.requestPermissions(
                    it,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_REQUEST_CODE
                )
            }
        }
    }

    private suspend fun prepareVpn() = withContext(Dispatchers.Main) {
        val act = activity ?: return@withContext false
        try {
            val intent = VpnService.prepare(act)
            if (intent != null) {
                act.startActivityForResult(intent, VPN_PERMISSION_REQUEST_CODE)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            onServiceAlert(Alert.RequestVPNPermission, e.message)
            false
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == VPN_PERMISSION_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                startService()
            } else {
                onServiceAlert(Alert.RequestVPNPermission, null)
            }
            return true
        } else if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                startService()
            } else {
                onServiceAlert(Alert.RequestNotificationPermission, null)
            }
            return true
        }
        return false
    }

    data class AppItem(
        @SerializedName("package-name") val packageName: String,
        @SerializedName("name") val name: String,
        @SerializedName("is-system-app") val isSystemApp: Boolean
    )

    private fun isServiceActive(): Boolean {
        val current = serviceStatus.value
        return current == Status.Started || current == Status.Starting || current == Status.Stopping
    }

    private suspend fun waitForServiceStopped(timeoutMs: Long = 6000L): Boolean {
        val startedAt = System.currentTimeMillis()
        while (System.currentTimeMillis() - startedAt < timeoutMs) {
            if (serviceStatus.value == Status.Stopped) return true
            delay(80L)
        }
        val stopped = serviceStatus.value == Status.Stopped
        if (!stopped) {
            Log.w(TAG, "Timed out waiting for service to stop. Current state=${serviceStatus.value}")
        }
        return stopped
    }

    private fun beginPingSession(): Long {
        val sessionId = pingSessionId.incrementAndGet()
        cancelPingExecutors("starting new ping session $sessionId")
        return sessionId
    }

    private fun cancelActivePing(reason: String) {
        pingSessionId.incrementAndGet()
        cancelPingExecutors(reason)
    }

    private fun cancelPingExecutors(reason: String) {
        if (pingExecutors.isEmpty()) return
        Log.d(TAG, "Cancelling ping tasks: $reason")
        val snapshot = pingExecutors.toList()
        snapshot.forEach { executor ->
            try {
                executor.shutdownNow()
                runCatching {
                    executor.awaitTermination(PING_EXECUTOR_DRAIN_WAIT_MS, TimeUnit.MILLISECONDS)
                }
            } catch (_: Exception) {
            } finally {
                pingExecutors.remove(executor)
            }
        }
    }

    private fun registerPingExecutor(executor: ExecutorService) {
        pingExecutors.add(executor)
    }

    private fun unregisterPingExecutor(executor: ExecutorService) {
        pingExecutors.remove(executor)
    }

    private fun newPingExecutor(threadCount: Int, namePrefix: String): ExecutorService {
        val counter = AtomicInteger(0)
        val factory = java.util.concurrent.ThreadFactory { runnable ->
            Thread(runnable, "$namePrefix-${counter.incrementAndGet()}").apply {
                isDaemon = true
                priority = Thread.NORM_PRIORITY
            }
        }
        return if (threadCount <= 1) {
            java.util.concurrent.Executors.newSingleThreadExecutor(factory)
        } else {
            java.util.concurrent.Executors.newFixedThreadPool(threadCount, factory)
        }
    }

    private fun isPingSessionActive(sessionId: Long): Boolean = pingSessionId.get() == sessionId

    private fun testConfigLink(link: String, timeout: Int, sessionId: Long): Long {
        if (!isPingSessionActive(sessionId)) return -1L
        val outbound = XrayConfigParser.parseLink(link) ?: run {
            Log.e(TAG, "Ping: failed to parse config link")
            return -1L
        }
        if (!isPingSessionActive(sessionId)) return -1L
        ensureCoreEnvInitializedForPing()
        val config = buildPingMeasureConfig(outbound)
        val measured = measureOutboundDelayWithTimeout(config, Settings.pingTestUrl, timeout, sessionId)
        if (!isPingSessionActive(sessionId)) return -1L
        val normalized = normalizeDelayValue(measured)
        if (normalized >= 0L) {
            Log.d(TAG, "Ping OK: ${normalized}ms")
        } else {
            Log.e(TAG, "Ping failed")
        }
        return normalized
    }

    private fun testConfigLinksParallel(
        links: List<String>,
        timeout: Int,
        sessionId: Long
    ): Map<String, Long> {
        val results = java.util.concurrent.ConcurrentHashMap<String, Long>()
        val effectiveTimeout = timeout.coerceAtLeast(MIN_PING_TIMEOUT_MS)

        data class ParsedEntry(val link: String, val outbound: Map<String, Any>)

        val parsed = mutableListOf<ParsedEntry>()
        val mainHandler0 = android.os.Handler(android.os.Looper.getMainLooper())
        links.forEach { link ->
            if (!isPingSessionActive(sessionId)) {
                return@forEach
            }
            val outbound = XrayConfigParser.parseLink(link)
            if (outbound != null) {
                parsed.add(ParsedEntry(link, outbound))
            } else {
                results[link] = -1L
                if (isPingSessionActive(sessionId)) {
                    mainHandler0.post {
                        if (isPingSessionActive(sessionId)) {
                            pingEventSink?.success(mapOf("link" to link, "latency" to -1L))
                        }
                    }
                }
            }
        }

        if (!isPingSessionActive(sessionId)) return results
        if (parsed.isEmpty()) return results

        ensureCoreEnvInitializedForPing()
        if (!isPingSessionActive(sessionId)) return results

        val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
        val threadCount = minOf(parsed.size, PING_MAX_PARALLEL_TASKS)
        val executor = newPingExecutor(threadCount, "v2ray-ping-batch")
        registerPingExecutor(executor)
        val latch = java.util.concurrent.CountDownLatch(parsed.size)
        val batches = (parsed.size + threadCount - 1) / threadCount
        val waitTimeoutMs = (batches.toLong() * (effectiveTimeout.toLong() + PING_TASK_GRACE_MS)) + 4000L

        parsed.forEach { entry ->
            try {
                executor.submit {
                    try {
                        if (!isPingSessionActive(sessionId)) {
                            results.putIfAbsent(entry.link, -1L)
                            return@submit
                        }
                        val config = buildPingMeasureConfig(entry.outbound)
                        val measured = measureOutboundDelayWithTimeout(
                            config,
                            Settings.pingTestUrl,
                            effectiveTimeout,
                            sessionId
                        )
                        if (!isPingSessionActive(sessionId)) {
                            results.putIfAbsent(entry.link, -1L)
                            return@submit
                        }
                        val elapsed = normalizeDelayValue(measured)
                        results[entry.link] = elapsed
                        mainHandler.post {
                            if (isPingSessionActive(sessionId)) {
                                pingEventSink?.success(mapOf("link" to entry.link, "latency" to elapsed))
                            }
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Ping failed for ${entry.link}: ${e.message}")
                        results[entry.link] = -1L
                        mainHandler.post {
                            if (isPingSessionActive(sessionId)) {
                                pingEventSink?.success(mapOf("link" to entry.link, "latency" to -1L))
                            }
                        }
                    } finally {
                        latch.countDown()
                    }
                }
            } catch (e: RejectedExecutionException) {
                Log.w(TAG, "Ping task rejected for ${entry.link}: ${e.message}")
                results[entry.link] = -1L
                mainHandler.post {
                    if (isPingSessionActive(sessionId)) {
                        pingEventSink?.success(mapOf("link" to entry.link, "latency" to -1L))
                    }
                }
                latch.countDown()
            } catch (e: Exception) {
                Log.w(TAG, "Unexpected ping submit error for ${entry.link}: ${e.message}")
                results[entry.link] = -1L
                mainHandler.post {
                    if (isPingSessionActive(sessionId)) {
                        pingEventSink?.success(mapOf("link" to entry.link, "latency" to -1L))
                    }
                }
                latch.countDown()
            }
        }

        var remainingMs = waitTimeoutMs
        while (latch.count > 0 && remainingMs > 0 && isPingSessionActive(sessionId)) {
            val step = minOf(250L, remainingMs)
            latch.await(step, java.util.concurrent.TimeUnit.MILLISECONDS)
            remainingMs -= step
        }
        val completed = latch.count == 0L
        if (!completed && isPingSessionActive(sessionId)) {
            Log.w(TAG, "Parallel ping timed out after ${waitTimeoutMs}ms")
        } else if (!isPingSessionActive(sessionId)) {
            Log.d(TAG, "Parallel ping cancelled")
        }
        executor.shutdownNow()
        runCatching {
            executor.awaitTermination(PING_EXECUTOR_DRAIN_WAIT_MS, TimeUnit.MILLISECONDS)
        }
        unregisterPingExecutor(executor)

        // Ensure caller always receives a result for each input link.
        if (isPingSessionActive(sessionId)) {
            parsed.forEach { entry ->
                if (!results.containsKey(entry.link)) {
                    results[entry.link] = -1L
                    mainHandler.post {
                        if (isPingSessionActive(sessionId)) {
                            pingEventSink?.success(mapOf("link" to entry.link, "latency" to -1L))
                        }
                    }
                }
            }
        }

        return results
    }

    private fun ensureCoreEnvInitializedForPing() {
        val context = applicationContext ?: return
        val workingDir = context.getExternalFilesDir(null) ?: context.filesDir
        workingDir.mkdirs()
        runCatching {
            Libv2ray.initCoreEnv(workingDir.path, "")
        }
    }

    private fun parsePingTimeout(value: Any?): Int {
        val timeout = (value as? Number)?.toInt() ?: DEFAULT_PING_TIMEOUT_MS
        return timeout.coerceIn(MIN_PING_TIMEOUT_MS, MAX_PING_TIMEOUT_MS)
    }

    private fun measureOutboundDelayWithTimeout(
        configJson: String,
        testUrl: String,
        timeoutMs: Int,
        sessionId: Long
    ): Long {
        if (!isPingSessionActive(sessionId)) return -1L
        val executor = newPingExecutor(1, "v2ray-ping-single")
        registerPingExecutor(executor)
        val future = executor.submit<Long> {
            measureOutboundDelay(configJson, testUrl)
        }
        return try {
            future.get(timeoutMs.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
        } catch (e: java.util.concurrent.TimeoutException) {
            Log.w(TAG, "measureOutboundDelay timeout after ${timeoutMs}ms")
            -1L
        } catch (e: Exception) {
            Log.e(TAG, "measureOutboundDelayWithTimeout failed: ${e.message}")
            -1L
        } finally {
            future.cancel(true)
            executor.shutdownNow()
            runCatching {
                executor.awaitTermination(PING_EXECUTOR_DRAIN_WAIT_MS, TimeUnit.MILLISECONDS)
            }
            unregisterPingExecutor(executor)
        }
    }

    private fun measureOutboundDelay(configJson: String, testUrl: String): Long {
        return try {
            Libv2ray.measureOutboundDelay(configJson, testUrl)
        } catch (e: Exception) {
            Log.e(TAG, "measureOutboundDelay failed: ${e.message}")
            -1L
        }
    }

    private fun normalizeDelayValue(delayMs: Long): Long {
        return if (delayMs <= 0L || delayMs >= 65000L) -1L else delayMs
    }

    private fun buildPingMeasureConfig(outbound: Map<String, Any>): String {
        val speedtestOutbound = outbound.toMutableMap().apply {
            remove("mux")
        }
        val config = mapOf(
            "log" to mapOf("loglevel" to "warning"),
            "outbounds" to listOf(
                speedtestOutbound,
                mapOf(
                    "tag" to "direct",
                    "protocol" to "freedom",
                    "settings" to mapOf("domainStrategy" to "UseIP")
                ),
                mapOf(
                    "tag" to "block",
                    "protocol" to "blackhole",
                    "settings" to mapOf("response" to mapOf("type" to "http"))
                )
            )
        )
        return gson.toJson(config)
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val kb = bytes / 1024.0
        if (kb < 1024) return String.format("%.1f KB", kb)
        val mb = kb / 1024.0
        if (mb < 1024) return String.format("%.1f MB", mb)
        val gb = mb / 1024.0
        return String.format("%.2f GB", gb)
    }
}

data class ServiceEvent(val status: Status, val alert: Alert? = null, val message: String? = null)
