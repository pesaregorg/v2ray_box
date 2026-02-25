# V2Ray Box

A Flutter plugin for VPN functionality with dual-core support: [Xray-core](https://github.com/XTLS/Xray-core) and [sing-box](https://github.com/SagerNet/sing-box). Switch between cores at runtime without reinstalling.

## Platform Support

| Platform | Status | Mode |
|----------|--------|------|
| Android  | Supported | VPN / Proxy |
| iOS      | Supported | VPN (via NetworkExtension) |
| macOS    | Supported | Proxy (system proxy) |

## Features

- **Dual Core Engine** — Xray-core and sing-box with runtime switching
- Multiple V2Ray protocols (VMess, VLESS, Trojan, Shadowsocks, Hysteria, Hysteria2, TUIC, WireGuard, SSH)
- Multiple transports (WebSocket, gRPC, HTTP/H2, HTTPUpgrade, xHTTP, QUIC)
- TLS, Reality, uTLS fingerprint, Multiplex support
- VPN and Proxy modes
- Real-time traffic statistics (Xray stats API / sing-box Clash API)
- Connection status monitoring
- Config link parsing and validation
- Single and parallel batch ping testing with streaming results
- Per-app proxy (Android only)
- Customizable notification (Android)
- Persistent total traffic storage

## Installation

```yaml
dependencies:
  v2ray_box:
    path: ../v2ray_box
```

## Platform Setup

> **Important:** Core files are not bundled with this package. Build them with the scripts below in your app project.
> Manual copy flow for iOS core files is deprecated in this package README.

### Android Core Build (Script-Based)

For Android apps using this package, build cores with these scripts:

1. Copy `example/scripts/build_android_libxray.sh` and/or `example/scripts/build_android_libsingbox.sh` into your app repo (for example: `scripts/`)
2. Run from app root (or pass `--project-root`)

Example:

```bash
bash ./scripts/build_android_libxray.sh
bash ./scripts/build_android_libsingbox.sh
```

Output paths:

- Android Xray: `android/app/libs/libxray.aar`
- Android sing-box: `android/app/src/main/jniLibs/<abi>/libsingbox.so`

For command usage, flags, and ready-to-run examples, see [`example/scripts/README.md`](example/scripts/README.md).

### iOS Core Build (Script-Based)

For iOS apps using this package, build cores with these scripts:

1. Copy `example/scripts/build_ios_libxray.sh` and/or `example/scripts/build_ios_libsingbox.sh` into your app repo (for example: `scripts/`)
2. Run from app root (or pass `--project-root`)

Example:

```bash
bash ./scripts/build_ios_libxray.sh
bash ./scripts/build_ios_libsingbox.sh
```

Output paths:

- iOS Xray: `ios/Frameworks/LibXray.xcframework`
- iOS sing-box: `ios/Frameworks/Libbox.xcframework`

For command usage, flags, and ready-to-run examples, see [`example/scripts/README.md`](example/scripts/README.md).

### Android — Required Manifest & Gradle Settings

Add these Android settings (same as the example app).

1. Required permissions in `android/app/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

    <uses-permission
        android:name="android.permission.QUERY_ALL_PACKAGES"
        tools:ignore="QueryAllPackagesPermission" />
</manifest>
```

2. Service declarations + cleartext inside `<application>`:

```xml
<application
    android:usesCleartextTraffic="true"
    tools:targetApi="31"
    ...>

    <service
        android:name="com.example.v2ray_box.bg.VPNService"
        android:exported="false"
        android:foregroundServiceType="specialUse"
        android:permission="android.permission.BIND_VPN_SERVICE">
        <intent-filter>
            <action android:name="android.net.VpnService" />
        </intent-filter>
        <property
            android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
            android:value="vpn" />
    </service>

    <service
        android:name="com.example.v2ray_box.bg.ProxyService"
        android:exported="false"
        android:foregroundServiceType="specialUse">
        <property
            android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
            android:value="proxy" />
    </service>
</application>
```

3. Required Gradle settings in `android/app/build.gradle` or `build.gradle.kts`:

```groovy
android {
    defaultConfig {
        multiDexEnabled true
    }
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    implementation fileTree(dir: 'libs', include: ['*.aar'])
}
```

Kotlin DSL:

```kotlin
android {
    defaultConfig {
        multiDexEnabled = true
    }
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar"))))
}
```

Notes:
- `android:usesCleartextTraffic="true"` is required for local HTTP endpoints (e.g. `127.0.0.1:9090`).
- Keep `android:permission="android.permission.BIND_VPN_SERVICE"` on `VPNService`.
- `QUERY_ALL_PACKAGES` is only needed for Per-App Proxy.

### iOS Notes

- PacketTunnel in this package supports both cores:
  - sing-box via `Libbox.xcframework`
  - Xray via `LibXray.xcframework`
- Minimum version: iOS 15.0+.
- Real VPN test must run on a physical iPhone (VPN is not supported on iOS Simulator).

### iOS — Xcode & CocoaPods Setup

After building iOS cores with scripts:

1. Update CocoaPods (recommended: `1.16.2`) and run:

```bash
cd example/ios
pod install
```

2. Open `Runner.xcworkspace` (not `Runner.xcodeproj`).
3. In target `PacketTunnel`, verify these frameworks are linked:
   - `Libbox.xcframework`
   - `LibXray.xcframework`
   - `NetworkExtension.framework`
   - `UIKit.framework`
4. Test real VPN behavior on a physical iPhone.

### macOS Notes

- Place `xray` and/or `sing-box` under `macos/Frameworks/`.
- Ensure executability (`chmod +x`).
- Minimum version: macOS 10.15+.

## Usage

### Initialize

```dart
import 'package:v2ray_box/v2ray_box.dart';

final v2rayBox = V2rayBox();
await v2rayBox.initialize(
  notificationStopButtonText: 'Disconnect',
);
```

### Switch Core Engine

```dart
// Set core engine (disconnect VPN first if connected)
await v2rayBox.setCoreEngine('xray');    // Xray-core (default)
await v2rayBox.setCoreEngine('singbox'); // sing-box

// Get current core engine
final engine = await v2rayBox.getCoreEngine();
```

### Connect / Disconnect

```dart
await v2rayBox.connect('vless://uuid@server:port?...#Name', name: 'My Config');
await v2rayBox.disconnect();
```

### Monitor Status

```dart
v2rayBox.watchStatus().listen((status) {
  // VpnStatus.stopped, starting, started, stopping
});
```

### Monitor Traffic

```dart
v2rayBox.watchStats().listen((stats) {
  print('Up: ${stats.formattedUplink}, Down: ${stats.formattedDownlink}');
});
```

### Core Info

```dart
final info = await v2rayBox.getCoreInfo();
// Returns: { "core": "xray", "engine": "xray-core", "version": "26.2.6" }
// or:      { "core": "singbox", "engine": "sing-box", "version": "1.12.22" }
```

### Ping

```dart
// Single (timeout is optional, default: 7000ms)
final latency = await v2rayBox.ping(configLink);
final latencyFastFail = await v2rayBox.ping(configLink, timeout: 4000);

// Parallel batch (timeout is optional, default: 7000ms per config)
final sub = v2rayBox.watchPingResults().listen((result) {
  print('${result["link"]}: ${result["latency"]}ms');
});
final results = await v2rayBox.pingAll(links);
final resultsSlowNetwork = await v2rayBox.pingAll(links, timeout: 10000);
await sub.cancel();
```

### VPN Mode

```dart
await v2rayBox.setServiceMode(VpnMode.vpn);   // route all traffic
await v2rayBox.setServiceMode(VpnMode.proxy);  // local proxy only
```

### Per-App Proxy (Android)

```dart
await v2rayBox.setPerAppProxyMode(PerAppProxyMode.exclude);
await v2rayBox.setPerAppProxyList(['com.example.app'], PerAppProxyMode.exclude);
```

### Total Traffic

```dart
final traffic = await v2rayBox.getTotalTraffic();
print('Total: ${traffic.formattedTotal}');
await v2rayBox.resetTotalTraffic();
```

## Supported Protocols

| Protocol | Link Format |
|----------|-------------|
| VLESS | `vless://uuid@server:port?params#name` |
| VMess | `vmess://base64_json` |
| Trojan | `trojan://password@server:port?params#name` |
| Shadowsocks | `ss://base64(method:password)@server:port#name` |
| Hysteria2 | `hy2://auth@server:port?params#name` |
| Hysteria | `hy://server:port?params#name` |
| TUIC | `tuic://uuid:password@server:port?params#name` |
| WireGuard | `wg://private_key@server:port?params#name` |
| SSH | `ssh://user:password@server:port?params#name` |

### Transports

`type=ws` | `type=grpc` | `type=http` | `type=h2` | `type=httpupgrade` | `type=xhttp` | `type=quic`

### TLS Options

`security=tls` | `security=reality` | `fp=chrome` | `alpn=h2,http/1.1` | `pbk=...&sid=...`

### Multiplex

`mux=1` | `mux-max-streams=4`

## Architecture

### Core Engines by Platform

| | Android | iOS | macOS |
|---|---------|-----|-------|
| **Xray-core integration** | AAR library (in-process) | xcframework (via PacketTunnel) | CLI binary (subprocess) |
| **sing-box integration** | CLI binary (subprocess) | Libbox.xcframework (via PacketTunnel) | CLI binary (subprocess) |
| **VPN Mode** | Android VpnService + TUN | NetworkExtension PacketTunnel | N/A (proxy mode only) |
| **Proxy Mode** | SOCKS/HTTP local proxy | N/A (VPN mode only) | System proxy via `networksetup` |
| **Traffic Stats** | Xray stats API / Clash API | Clash API / PacketTunnel IPC | Clash API (sing-box) |
| **Config Format** | Xray JSON / sing-box JSON | Xray JSON / sing-box JSON | Xray JSON / sing-box JSON |

### How Android sing-box VPN Mode Works

On Android, the plugin uses Xray-core as a TUN bridge for sing-box:

1. Android `VpnService` creates a TUN interface
2. Xray-core reads from TUN and forwards traffic to sing-box's local SOCKS proxy (`127.0.0.1:10808`)
3. sing-box handles the actual proxy connection to the remote server

This avoids the need for sing-box to manage TUN directly (which requires root on Android when running as a CLI binary).

### How iOS VPN Works

On iOS, the VPN runs as a PacketTunnel Network Extension:

1. The main app generates the config JSON (sing-box or Xray format) and passes it to the PacketTunnel extension
2. The PacketTunnel extension receives the config + core engine type via VPN tunnel options
3. The extension uses `Libbox.xcframework` for sing-box and `LibXray.xcframework` for Xray
4. All device traffic is routed through the tunnel interface

### How macOS Proxy Works

On macOS, both cores run as CLI binaries (subprocesses):

1. The plugin starts the selected core binary (`sing-box` or `xray`) with the generated config
2. The core opens a local SOCKS/HTTP proxy port
3. The plugin configures macOS system proxy settings via `networksetup` to route traffic through the local proxy
4. When stopped, system proxy settings are restored to their previous state

## API Reference

### Initialization

| Method | Returns | Description |
|--------|---------|-------------|
| `initialize({notificationStopButtonText, notificationIconName})` | `Future<void>` | Initialize the VPN core. Must be called first. |
| `setConfigOptions(options)` | `Future<bool>` | Set configuration options for the VPN service |
| `configOptions` | `ConfigOptions` | Get current configuration options (getter) |

### Connection

| Method | Returns | Description |
|--------|---------|-------------|
| `connect(link, {name, notificationTitle})` | `Future<bool>` | Start VPN with a config link |
| `connectWithJson(configJson, {name})` | `Future<bool>` | Start VPN with raw JSON config |
| `disconnect()` | `Future<bool>` | Stop VPN connection |
| `restart(link, {name})` | `Future<bool>` | Restart VPN connection |

### Status & Streams

| Method | Returns | Description |
|--------|---------|-------------|
| `watchStatus()` | `Stream<VpnStatus>` | Watch VPN status changes |
| `watchStats()` | `Stream<VpnStats>` | Watch real-time traffic statistics |
| `watchAlerts()` | `Stream<Map<String, dynamic>>` | Watch VPN alerts |
| `watchLogs()` | `Stream<Map<String, dynamic>>` | Watch live log stream |
| `getLogs()` | `Future<List<String>>` | Get current log buffer |

### Core Engine

| Method | Returns | Description |
|--------|---------|-------------|
| `getCoreInfo()` | `Future<Map<String, dynamic>>` | Get core engine info (name, version) |
| `setCoreEngine(engine)` | `Future<bool>` | Set active core (`'xray'` or `'singbox'`) |
| `getCoreEngine()` | `Future<String>` | Get active core engine name |

### Ping & Testing

| Method | Returns | Description |
|--------|---------|-------------|
| `ping(link, {timeout})` | `Future<int>` | Test latency of a single config (ms). `timeout` is optional, default `7000` ms. |
| `pingAll(links, {timeout})` | `Future<Map<String, int>>` | Test latency of multiple configs in parallel. `timeout` is optional, default `7000` ms per config. |
| `watchPingResults()` | `Stream<Map<String, dynamic>>` | Watch individual ping results during `pingAll` |
| `setPingTestUrl(url)` | `Future<bool>` | Set custom URL for ping testing |
| `getPingTestUrl()` | `Future<String>` | Get current ping test URL |

### VPN Mode & Permissions

| Method | Returns | Description |
|--------|---------|-------------|
| `setServiceMode(mode)` | `Future<bool>` | Set VPN mode (`VpnMode.vpn` or `VpnMode.proxy`) |
| `getServiceMode()` | `Future<VpnMode>` | Get current VPN mode |
| `checkVpnPermission()` | `Future<bool>` | Check if VPN permission is granted |
| `requestVpnPermission()` | `Future<bool>` | Request VPN permission from user |

### Per-App Proxy (Android)

| Method | Returns | Description |
|--------|---------|-------------|
| `setPerAppProxyMode(mode)` | `Future<bool>` | Set per-app proxy mode |
| `getPerAppProxyMode()` | `Future<PerAppProxyMode>` | Get current per-app proxy mode |
| `setPerAppProxyList(packages, mode)` | `Future<bool>` | Set list of packages for per-app proxy |
| `getPerAppProxyList(mode)` | `Future<List<String>>` | Get list of packages for per-app proxy |
| `getInstalledApps()` | `Future<List<AppInfo>>` | Get list of installed applications |
| `getAppIcon(packageName)` | `Future<String?>` | Get app icon as base64 PNG |

### Traffic

| Method | Returns | Description |
|--------|---------|-------------|
| `getTotalTraffic()` | `Future<TotalTraffic>` | Get persistent total traffic stats |
| `resetTotalTraffic()` | `Future<bool>` | Reset total traffic to zero |

### Config Utilities

| Method | Returns | Description |
|--------|---------|-------------|
| `parseConfig(link, {debug})` | `Future<String>` | Validate config link (empty = valid) |
| `generateConfig(link)` | `Future<String>` | Generate full JSON config from link |
| `checkConfigJson(configJson)` | `Future<String>` | Validate raw JSON config |
| `getActiveConfig()` | `Future<String>` | Get currently active JSON config |
| `formatConfig(configJson)` | `Future<String>` | Prettify a JSON config |
| `parseConfigLink(link)` | `VpnConfig` | Parse link into `VpnConfig` object |
| `isValidConfigLink(link)` | `bool` | Check if link is a valid config |

### Notification (Android)

| Method | Returns | Description |
|--------|---------|-------------|
| `setNotificationStopButtonText(text)` | `Future<bool>` | Set stop button text |
| `setNotificationTitle(title)` | `Future<bool>` | Set custom notification title |
| `setNotificationIcon(iconName)` | `Future<bool>` | Set notification icon (drawable name) |

### Subscription

| Method | Returns | Description |
|--------|---------|-------------|
| `parseSubscription(link)` | `Future<Map<String, dynamic>>` | Parse subscription import link |
| `generateSubscriptionLink(name, url)` | `Future<String>` | Generate subscription link |

### Misc

| Method | Returns | Description |
|--------|---------|-------------|
| `setDebugMode(enabled)` | `Future<bool>` | Enable/disable verbose logging |
| `getDebugMode()` | `Future<bool>` | Get current debug mode state |
| `formatBytes(bytes)` | `Future<String>` | Format bytes to human-readable string |
| `proxyDisplayType(type)` | `Future<String>` | Get display name for proxy type |
| `availablePort({startPort})` | `Future<int>` | Find an available network port |
| `selectOutbound(groupTag, outboundTag)` | `Future<bool>` | Select outbound in a group |
| `setClashMode(mode)` | `Future<bool>` | Set clash routing mode |
| `setLocale(locale)` | `Future<bool>` | Set locale for the core library |
| `getPlatformVersion()` | `Future<String?>` | Get platform version string |

## Reducing App Size (Single Core Mode)

If you want a smaller app, you can ship only one of the two cores on any platform:

**Android:**
- **Xray-core only** — Keep only `android/app/libs/libxray.aar` and remove `libsingbox.so` from `jniLibs/`.
- **sing-box only** — Keep only `libsingbox.so` in `jniLibs/` and remove `android/app/libs/libxray.aar`.

**iOS:**
- **sing-box only** — Keep `ios/Frameworks/Libbox.xcframework`, remove `ios/Frameworks/LibXray.xcframework`, and remove `LibXray.xcframework` from `PacketTunnel` linked frameworks.
- **Xray-core only** — Keep `ios/Frameworks/LibXray.xcframework`, remove `ios/Frameworks/Libbox.xcframework`, and remove `Libbox.xcframework` from `PacketTunnel` linked frameworks.

**macOS:**
- Only place the binary you need (`sing-box` or `xray`) in `macos/Frameworks/`.

> **Important:** When shipping a single core, make sure you do **not** expose the core switching option to users in your app's UI. If a user tries to switch to a core that isn't bundled, the VPN connection will fail. Set the default core engine to the one you've included and hide the engine selector from your settings page.

```dart
// Example: sing-box only app — set once at startup, no UI switch needed
await v2rayBox.setCoreEngine('singbox');
```

## Credits

- [Xray-core](https://github.com/XTLS/Xray-core)
- [sing-box](https://github.com/SagerNet/sing-box)
- [libXray](https://github.com/XTLS/libXray)
