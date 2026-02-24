package com.example.v2ray_box.bg

import android.util.Log
import com.example.v2ray_box.Settings
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import com.example.v2ray_box.constant.PerAppProxyMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

class VPNService : VpnService(), PlatformInterfaceWrapper {

    companion object {
        private const val TAG = "V2Ray/VPNService"
        // Keep MTU conservative to avoid fragmentation/instability on mobile networks.
        private const val TUN_MTU = 1500
        private const val TUN_ADDR4 = "26.26.26.1"
        private const val TUN_ADDR6 = "da26:2626::1"
    }

    private val service = BoxService(this, this)
    private var tunPfd: ParcelFileDescriptor? = null
    private val connectivity by lazy { getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager }
    private val defaultNetworkRequest by lazy {
        NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
    }
    private val defaultNetworkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            runCatching { setUnderlyingNetworks(arrayOf(network)) }
        }

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
            runCatching { setUnderlyingNetworks(arrayOf(network)) }
        }

        override fun onLost(network: Network) {
            runCatching { setUnderlyingNetworks(null) }
        }
    }
    private var defaultNetworkCallbackRegistered = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) =
        service.onStartCommand(intent, flags, startId)

    override fun onBind(intent: Intent): IBinder {
        val binder = super.onBind(intent)
        if (binder != null) {
            return binder
        }
        return service.onBind(intent)
    }

    override fun onDestroy() {
        unregisterDefaultNetworkCallback()
        service.onDestroy()
        super.onDestroy()
    }

    override fun onRevoke() {
        runBlocking {
            withContext(Dispatchers.Main) {
                service.onRevoke()
            }
        }
        unregisterDefaultNetworkCallback()
        super.onRevoke()
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    private fun addIncludePackage(builder: Builder, packageName: String) {
        if (packageName == this.packageName) {
            Log.d(TAG, "Cannot include myself: $packageName")
            return
        }
        try {
            Log.d(TAG, "Including $packageName")
            builder.addAllowedApplication(packageName)
        } catch (e: NameNotFoundException) {
            Log.w(TAG, "Package not found: $packageName")
        }
    }

    private fun addExcludePackage(builder: Builder, packageName: String) {
        try {
            Log.d(TAG, "Excluding $packageName")
            builder.addDisallowedApplication(packageName)
        } catch (e: NameNotFoundException) {
            Log.w(TAG, "Package not found: $packageName")
        }
    }

    override fun createTun(): ParcelFileDescriptor? {
        Log.d(TAG, "createTun called")

        var hasPermission = false
        for (i in 0 until 20) {
            if (prepare(this) != null) {
                Log.w(TAG, "android: missing vpn permission, retrying...")
            } else {
                hasPermission = true
                break
            }
            Thread.sleep(50)
        }
        if (!hasPermission) {
            Log.e(TAG, "android: missing vpn permission")
            return null
        }

        val builder = Builder()
            .setSession("V2Ray Box")
            .setMtu(TUN_MTU)
            .addAddress(TUN_ADDR4, 30)
            .addAddress(TUN_ADDR6, 126)
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }
        registerDefaultNetworkCallback()

        if (Settings.perAppProxyEnabled) {
            val appList = Settings.perAppProxyList
            Log.d(TAG, "Per-app proxy enabled. Mode: ${Settings.perAppProxyMode}, Apps: ${appList.size}")

            if (Settings.perAppProxyMode == PerAppProxyMode.INCLUDE) {
                appList.forEach { addIncludePackage(builder, it) }
            } else {
                appList.forEach { addExcludePackage(builder, it) }
                addExcludePackage(builder, packageName)
            }
        } else {
            addExcludePackage(builder, packageName)
        }

        val pfd = builder.establish() ?: run {
            Log.e(TAG, "Failed to establish VPN")
            return null
        }
        tunPfd = pfd
        service.fileDescriptor = pfd
        Log.d(TAG, "TUN interface created, fd=${pfd.fd}")
        return pfd
    }

    override fun closeTun() {
        unregisterDefaultNetworkCallback()
        tunPfd?.let {
            try {
                it.close()
            } catch (e: Exception) {
                Log.w(TAG, "Error closing TUN", e)
            }
            tunPfd = null
        }
        service.fileDescriptor = null
    }

    private fun registerDefaultNetworkCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return
        }
        if (defaultNetworkCallbackRegistered) {
            return
        }
        try {
            connectivity.requestNetwork(defaultNetworkRequest, defaultNetworkCallback)
            defaultNetworkCallbackRegistered = true
        } catch (e: Exception) {
            Log.w(TAG, "Unable to register default network callback", e)
        }
    }

    private fun unregisterDefaultNetworkCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return
        }
        if (!defaultNetworkCallbackRegistered) {
            return
        }
        try {
            connectivity.unregisterNetworkCallback(defaultNetworkCallback)
        } catch (_: Exception) {
        } finally {
            defaultNetworkCallbackRegistered = false
            runCatching { setUnderlyingNetworks(null) }
        }
    }
}
