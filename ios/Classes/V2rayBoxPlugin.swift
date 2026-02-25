import Flutter
import UIKit
import NetworkExtension
import Network
import Libbox

public class V2rayBoxPlugin: NSObject, FlutterPlugin {
    private var methodChannel: FlutterMethodChannel?
    private var statusChannel: FlutterEventChannel?
    private var alertsChannel: FlutterEventChannel?
    private var statsChannel: FlutterEventChannel?
    private var pingChannel: FlutterEventChannel?
    private var logsChannel: FlutterEventChannel?
    
    private var statusEventSink: FlutterEventSink?
    private var alertsEventSink: FlutterEventSink?
    private var statsEventSink: FlutterEventSink?
    private var pingEventSink: FlutterEventSink?
    private var logsEventSink: FlutterEventSink?
    
    private var debugMode: Bool {
        get { UserDefaults.standard.bool(forKey: "v2ray_box_debug_mode") }
        set { UserDefaults.standard.set(newValue, forKey: "v2ray_box_debug_mode") }
    }
    
    private var pingTestUrl: String {
        get { UserDefaults.standard.string(forKey: "v2ray_box_ping_test_url") ?? "http://connectivitycheck.gstatic.com/generate_204" }
        set { UserDefaults.standard.set(newValue, forKey: "v2ray_box_ping_test_url") }
    }
    
    private var coreEngine: String {
        get { UserDefaults.standard.string(forKey: "v2ray_box_core_engine") ?? "singbox" }
        set { UserDefaults.standard.set(newValue, forKey: "v2ray_box_core_engine") }
    }
    
    private var vpnManager: NEVPNManager?
    private var tunnelManager: NETunnelProviderManager?
    private var vpnObserver: NSObjectProtocol?
    private var statsTimer: Timer?
    
    private var configOptions: String = "{}"
    private var activeConfigPath: String = ""
    private var activeProfileName: String = ""
    
    private var singboxConfigBuilder: ConfigBuilder {
        return ConfigBuilder(optionsJson: configOptions)
    }
    
    private var xrayConfigBuilder: XrayConfigBuilder {
        return XrayConfigBuilder(optionsJson: configOptions)
    }
    
    private var commandClient: LibboxCommandClient?
    
    private var lastSingboxUpload: Int64 = 0
    private var lastSingboxDownload: Int64 = 0
    private var lastXrayUpload: Int64 = 0
    private var lastXrayDownload: Int64 = 0
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "v2ray_box", binaryMessenger: registrar.messenger())
        let instance = V2rayBoxPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.methodChannel = channel
        
        // Status event channel
        let statusChannel = FlutterEventChannel(
            name: "v2ray_box/status",
            binaryMessenger: registrar.messenger(),
            codec: FlutterJSONMethodCodec.sharedInstance()
        )
        statusChannel.setStreamHandler(StatusStreamHandler(plugin: instance))
        instance.statusChannel = statusChannel
        
        // Alerts event channel
        let alertsChannel = FlutterEventChannel(
            name: "v2ray_box/alerts",
            binaryMessenger: registrar.messenger(),
            codec: FlutterJSONMethodCodec.sharedInstance()
        )
        alertsChannel.setStreamHandler(AlertsStreamHandler(plugin: instance))
        instance.alertsChannel = alertsChannel
        
        // Stats event channel
        let statsChannel = FlutterEventChannel(
            name: "v2ray_box/stats",
            binaryMessenger: registrar.messenger(),
            codec: FlutterJSONMethodCodec.sharedInstance()
        )
        statsChannel.setStreamHandler(StatsStreamHandler(plugin: instance))
        instance.statsChannel = statsChannel
        
        let pingChannel = FlutterEventChannel(
            name: "v2ray_box/ping",
            binaryMessenger: registrar.messenger(),
            codec: FlutterJSONMethodCodec.sharedInstance()
        )
        pingChannel.setStreamHandler(PingStreamHandler(plugin: instance))
        instance.pingChannel = pingChannel
        
        let logsChannel = FlutterEventChannel(
            name: "v2ray_box/logs",
            binaryMessenger: registrar.messenger(),
            codec: FlutterJSONMethodCodec.sharedInstance()
        )
        logsChannel.setStreamHandler(LogsStreamHandler(plugin: instance))
        instance.logsChannel = logsChannel
        
        instance.setupVPNObserver()
    }
    
    private func setupVPNObserver() {
        vpnObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            self?.handleVPNStatusChange(connection.status)
        }
    }
    
    private func handleVPNStatusChange(_ status: NEVPNStatus) {
        let statusString: String
        switch status {
        case .connecting, .reasserting:
            statusString = "Starting"
        case .connected:
            statusString = "Started"
        case .disconnecting:
            statusString = "Stopping"
        case .disconnected, .invalid:
            statusString = "Stopped"
        @unknown default:
            statusString = "Stopped"
        }
        statusEventSink?(["status": statusString])
    }
    
    deinit {
        if let observer = vpnObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        statsTimer?.invalidate()
        try? commandClient?.disconnect()
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)
            
        case "setup":
            setup(result: result)
            
        case "parse_config":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing link parameter", details: nil))
                return
            }
            let debug = args["debug"] as? Bool ?? false
            parseConfig(link: link, debug: debug, result: result)
            
        case "change_config_options":
            guard let options = call.arguments as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing options parameter", details: nil))
                return
            }
            configOptions = options
            result(true)
            
        case "generate_config":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing link parameter", details: nil))
                return
            }
            generateConfig(link: link, result: result)
            
        case "start":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing link parameter", details: nil))
                return
            }
            let name = args["name"] as? String ?? ""
            start(link: link, name: name, result: result)
            
        case "stop":
            stop(result: result)
            
        case "restart":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing link parameter", details: nil))
                return
            }
            let name = args["name"] as? String ?? ""
            restart(link: link, name: name, result: result)
            
        case "check_vpn_permission":
            // On iOS, VPN permission is always available (handled by system)
            result(true)
            
        case "request_vpn_permission":
            // On iOS, permission is requested when creating VPN configuration
            result(true)
            
        case "set_service_mode":
            // iOS only supports VPN mode
            result(true)
            
        case "get_service_mode":
            result("vpn")
            
        case "set_notification_stop_button_text":
            // Not applicable on iOS
            result(true)
            
        case "set_notification_title":
            // Not applicable on iOS
            result(true)
            
        case "get_installed_packages":
            // Not available on iOS
            result("[]")
            
        case "get_package_icon":
            // Not available on iOS
            result(nil)
            
        case "url_test":
            guard let args = call.arguments as? [String: Any],
                  let link = args["link"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing link parameter", details: nil))
                return
            }
            let timeout = args["timeout"] as? Int ?? 5000
            urlTest(link: link, timeout: timeout, result: result)
            
        case "url_test_all":
            guard let args = call.arguments as? [String: Any],
                  let links = args["links"] as? [String] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing links parameter", details: nil))
                return
            }
            let timeout = args["timeout"] as? Int ?? 5000
            urlTestAll(links: links, timeout: timeout, result: result)
            
        case "set_per_app_proxy_mode":
            // Not available on iOS
            result(true)
            
        case "get_per_app_proxy_mode":
            result("off")
            
        case "set_per_app_proxy_list":
            // Not available on iOS
            result(true)
            
        case "get_per_app_proxy_list":
            result([String]())
            
        case "set_notification_icon":
            result(true)
            
        case "get_total_traffic":
            result(["upload": 0, "download": 0])
            
        case "reset_total_traffic":
            result(true)
            
        case "set_core_engine":
            if let engine = call.arguments as? String,
               engine == "xray" || engine == "singbox" {
                coreEngine = engine
                result(true)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Engine must be 'xray' or 'singbox'", details: nil))
            }
            
        case "get_core_engine":
            result(coreEngine)
            
        case "get_core_info":
            if coreEngine == "xray" {
                var info: [String: Any] = ["engine": "xray", "core": "xray-core"]
                if let session = tunnelManager?.connection as? NETunnelProviderSession,
                   tunnelManager?.connection.status == .connected {
                    do {
                        try session.sendProviderMessage("xray_version".data(using: .utf8)!) { response in
                            if let response,
                               let version = String(data: response, encoding: .utf8),
                               !version.isEmpty {
                                info["version"] = version
                            }
                            result(info)
                        }
                        return
                    } catch {
                        // fall back to basic core info without version
                    }
                }
                result(info)
            } else {
                var info: [String: Any] = ["engine": "singbox", "core": "sing-box"]
                let version = LibboxVersion()
                if !version.isEmpty { info["version"] = version }
                result(info)
            }
            
        case "check_config_json":
            guard let configJson = call.arguments as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing config JSON", details: nil))
                return
            }
            var checkError: NSError?
            let ok = LibboxCheckConfig(configJson, &checkError)
            if !ok, let checkError = checkError {
                result(checkError.localizedDescription)
            } else {
                result("")
            }
            
        case "start_with_json":
            guard let args = call.arguments as? [String: Any],
                  let configJson = args["config"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing config parameter", details: nil))
                return
            }
            let name = args["name"] as? String ?? ""
            startWithJson(configJson: configJson, name: name, result: result)
            
        case "get_logs":
            result([String]())
            
        case "set_debug_mode":
            if let enabled = call.arguments as? Bool {
                debugMode = enabled
            }
            result(true)
            
        case "get_debug_mode":
            result(debugMode)
            
        case "format_bytes":
            if let bytes = call.arguments as? Int64 {
                result(LibboxFormatBytes(bytes))
            } else if let bytes = call.arguments as? Int {
                result(LibboxFormatBytes(Int64(bytes)))
            } else {
                result("0 B")
            }
            
        case "get_active_config":
            getActiveConfig(result: result)
            
        case "proxy_display_type":
            if let type = call.arguments as? String {
                result(LibboxProxyDisplayType(type))
            } else {
                result("")
            }
            
        case "format_config":
            guard let configJson = call.arguments as? String else {
                result("")
                return
            }
            var fmtError: NSError?
            let formatted = LibboxFormatConfig(configJson, &fmtError)
            if fmtError != nil {
                result(configJson)
            } else {
                result(formatted?.value ?? configJson)
            }
            
        case "available_port":
            let startPort: Int
            if let p = call.arguments as? Int { startPort = p }
            else if let p = call.arguments as? Int32 { startPort = Int(p) }
            else { result(-1); return }
            var portResult: Int32 = 0
            var portError: NSError?
            let portOk = LibboxAvailablePort(Int32(startPort), &portResult, &portError)
            result(portOk ? Int(portResult) : -1)
            
        case "select_outbound":
            result(false)
            
        case "set_clash_mode":
            result(false)
            
        case "parse_subscription":
            guard let link = call.arguments as? String else {
                result([String: Any]())
                return
            }
            var subError: NSError?
            if let profile = LibboxParseRemoteProfileImportLink(link, &subError) {
                result([
                    "name": profile.name,
                    "url": profile.url,
                    "host": profile.host
                ])
            } else {
                result([String: Any]())
            }
            
        case "generate_subscription_link":
            guard let args = call.arguments as? [String: Any],
                  let name = args["name"] as? String,
                  let url = args["url"] as? String else {
                result("")
                return
            }
            result(LibboxGenerateRemoteProfileImportLink(name, url))
            
        case "set_locale":
            if let locale = call.arguments as? String {
                LibboxSetLocale(locale)
            }
            result(true)
            
        case "set_ping_test_url":
            if let url = call.arguments as? String {
                pingTestUrl = url
            }
            result(true)
            
        case "get_ping_test_url":
            result(pingTestUrl)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Setup
    
    private func setup(result: @escaping FlutterResult) {
        Task {
            do {
                let fileManager = FileManager.default
                let baseDir = getBaseDirectory()
                let workingDir = getWorkingDirectory()
                let tempDir = getTempDirectory()
                
                try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: workingDir, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                let opts = LibboxSetupOptions()
                opts.basePath = baseDir.path
                opts.workingPath = workingDir.path
                opts.tempPath = tempDir.path
                opts.debug = debugMode
                
                var error: NSError?
                LibboxSetup(opts, &error)
                
                if let error = error {
                    await MainActor.run {
                        result(FlutterError(code: "SETUP_ERROR", message: error.localizedDescription, details: nil))
                    }
                    return
                }
                
                let stderrPath = tempDir.appendingPathComponent("stderr.log").path
                LibboxRedirectStderr(stderrPath, &error)
                
                #if !targetEnvironment(simulator)
                try await loadVPNPreference()
                #endif
                
                await MainActor.run {
                    result("")
                }
            } catch {
                await MainActor.run {
                    result(FlutterError(code: "SETUP_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
    
    // MARK: - VPN Management
    
    private func loadVPNPreference() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let manager = managers.first {
            tunnelManager = manager
            return
        }
        
        // Create new manager
        let newManager = NETunnelProviderManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = Bundle.main.bundleIdentifier! + ".PacketTunnel"
        tunnelProtocol.serverAddress = "V2RayBox"
        newManager.protocolConfiguration = tunnelProtocol
        newManager.localizedDescription = "V2Ray Box"
        
        try await newManager.saveToPreferences()
        try await newManager.loadFromPreferences()
        tunnelManager = newManager
    }
    
    private func enableVPNManager() async throws {
        guard let manager = tunnelManager else { return }
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }
    
    // MARK: - Parse Config
    
    private func parseConfig(link: String, debug: Bool, result: @escaping FlutterResult) {
        Task {
            do {
                // Write link to temp file for parsing
                let tempDir = getTempDirectory()
                let configPath = tempDir.appendingPathComponent("temp_config.txt")
                try link.write(to: configPath, atomically: true, encoding: .utf8)
                
                // For now, just validate the link format
                await MainActor.run {
                    result("")
                }
            } catch {
                await MainActor.run {
                    result(error.localizedDescription)
                }
            }
        }
    }
    
    // MARK: - Generate Config
    
    private func generateConfig(link: String, result: @escaping FlutterResult) {
        Task {
            do {
                let config: String
                if coreEngine == "xray" {
                    config = try xrayConfigBuilder.buildConfig(from: link)
                } else {
                    config = try singboxConfigBuilder.buildConfig(from: link)
                }
                
                await MainActor.run {
                    result(config)
                }
            } catch {
                await MainActor.run {
                    result(FlutterError(code: "BUILD_CONFIG", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
    
    // MARK: - Start VPN
    
    private func start(link: String, name: String, result: @escaping FlutterResult) {
        Task {
            do {
                #if targetEnvironment(simulator)
                await MainActor.run {
                    result(FlutterError(
                        code: "SIMULATOR_NOT_SUPPORTED",
                        message: "VPN is not supported on iOS Simulator. Please use a physical device to test VPN functionality.",
                        details: nil
                    ))
                }
                return
                #endif
                
                activeProfileName = name
                
                let config: String
                do {
                    if coreEngine == "xray" {
                        config = try xrayConfigBuilder.buildConfig(from: link, proxyOnly: true)
                    } else {
                        config = try singboxConfigBuilder.buildConfig(from: link)
                    }
                } catch {
                    await MainActor.run {
                        result(FlutterError(code: "BUILD_CONFIG", message: error.localizedDescription, details: nil))
                    }
                    return
                }
                
                if tunnelManager?.connection.status == .connected {
                    await MainActor.run {
                        result(true)
                    }
                    return
                }
                
                try await loadVPNPreference()
                try await enableVPNManager()
                
                let options: [String: NSObject] = [
                    "Config": config as NSString,
                    "CoreEngine": coreEngine as NSString,
                    "DisableMemoryLimit": "NO" as NSString
                ]
                
                try tunnelManager?.connection.startVPNTunnel(options: options)
                
                await MainActor.run {
                    result(true)
                }
            } catch {
                await MainActor.run {
                    result(FlutterError(code: "START_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
    
    // MARK: - Stop VPN
    
    private func stop(result: @escaping FlutterResult) {
        guard let manager = tunnelManager,
              manager.connection.status == .connected else {
            result(true)
            return
        }
        
        manager.connection.stopVPNTunnel()
        result(true)
    }
    
    // MARK: - Restart VPN
    
    private func restart(link: String, name: String, result: @escaping FlutterResult) {
        Task {
            // Stop first if running
            if tunnelManager?.connection.status == .connected {
                tunnelManager?.connection.stopVPNTunnel()
                
                // Wait for disconnection
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
            
            // Start with new config
            start(link: link, name: name, result: result)
        }
    }
    
    // MARK: - URL Test
    
    private func urlTest(link: String, timeout: Int, result: @escaping FlutterResult) {
        Task {
            let latency = await performURLTest(link: link, timeout: timeout)
            await MainActor.run {
                result(latency)
            }
        }
    }
    
    private func urlTestAll(links: [String], timeout: Int, result: @escaping FlutterResult) {
        Task {
            var results: [String: Int] = [:]
            
            await withTaskGroup(of: (String, Int).self) { group in
                for link in links {
                    group.addTask {
                        let latency = await self.performURLTest(link: link, timeout: timeout)
                        return (link, latency)
                    }
                }
                
                for await (link, latency) in group {
                    results[link] = latency
                    let eventData: [String: Any] = ["link": link, "latency": latency]
                    await MainActor.run {
                        self.pingEventSink?(eventData)
                    }
                }
            }
            
            await MainActor.run {
                result(results)
            }
        }
    }
    
    private func performURLTest(link: String, timeout: Int) async -> Int {
        // Parse server from link and do TCP test
        guard let (host, port) = parseServerFromLink(link),
              !host.isEmpty, port > 0 else {
            return -1
        }
        
        // Use NWConnection for more reliable connection test on iOS
        return await withCheckedContinuation { continuation in
            let startTime = CFAbsoluteTimeGetCurrent()
            
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port))
            )
            
            let parameters = NWParameters.tcp
            parameters.expiredDNSBehavior = .allow
            
            let connection = NWConnection(to: endpoint, using: parameters)
            
            var hasCompleted = false
            let lock = NSLock()
            
            // Timeout timer
            let timeoutWorkItem = DispatchWorkItem {
                lock.lock()
                if !hasCompleted {
                    hasCompleted = true
                    lock.unlock()
                    connection.cancel()
                    continuation.resume(returning: -1)
                } else {
                    lock.unlock()
                }
            }
            
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .milliseconds(timeout),
                execute: timeoutWorkItem
            )
            
            connection.stateUpdateHandler = { state in
                lock.lock()
                guard !hasCompleted else {
                    lock.unlock()
                    return
                }
                
                switch state {
                case .ready:
                    hasCompleted = true
                    lock.unlock()
                    timeoutWorkItem.cancel()
                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                    connection.cancel()
                    continuation.resume(returning: elapsed)
                    
                case .failed(_), .cancelled:
                    hasCompleted = true
                    lock.unlock()
                    timeoutWorkItem.cancel()
                    continuation.resume(returning: -1)
                    
                default:
                    lock.unlock()
                }
            }
            
            connection.start(queue: DispatchQueue.global())
        }
    }
    
    private func parseServerFromLink(_ link: String) -> (String, Int)? {
        if link.hasPrefix("vmess://") {
            return parseVmessServer(link)
        } else if link.hasPrefix("vless://") || link.hasPrefix("trojan://") || link.hasPrefix("ss://") {
            guard let url = URL(string: link),
                  let host = url.host else { return nil }
            let port = url.port ?? 443
            return (host, port)
        }
        return nil
    }
    
    private func parseVmessServer(_ link: String) -> (String, Int)? {
        let encoded = String(link.dropFirst("vmess://".count))
        guard let data = Data(base64Encoded: encoded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = json["add"] as? String else { return nil }
        let port: Int
        if let portNum = json["port"] as? Int {
            port = portNum
        } else if let portStr = json["port"] as? String, let portNum = Int(portStr) {
            port = portNum
        } else {
            port = 443
        }
        return (host, port)
    }
    
    // MARK: - Start With JSON
    
    private func startWithJson(configJson: String, name: String, result: @escaping FlutterResult) {
        Task {
            do {
                #if targetEnvironment(simulator)
                await MainActor.run {
                    result(FlutterError(
                        code: "SIMULATOR_NOT_SUPPORTED",
                        message: "VPN is not supported on iOS Simulator.",
                        details: nil
                    ))
                }
                return
                #endif
                
                if coreEngine == "singbox" {
                    var validateError: NSError?
                    let valid = LibboxCheckConfig(configJson, &validateError)
                    if !valid, let validateError = validateError {
                        await MainActor.run {
                            result(FlutterError(code: "INVALID_CONFIG", message: validateError.localizedDescription, details: nil))
                        }
                        return
                    }
                }
                
                activeProfileName = name
                
                if tunnelManager?.connection.status == .connected {
                    await MainActor.run { result(true) }
                    return
                }
                
                try await loadVPNPreference()
                try await enableVPNManager()
                
                let options: [String: NSObject] = [
                    "Config": configJson as NSString,
                    "CoreEngine": coreEngine as NSString,
                    "DisableMemoryLimit": "NO" as NSString
                ]
                
                try tunnelManager?.connection.startVPNTunnel(options: options)
                
                await MainActor.run { result(true) }
            } catch {
                await MainActor.run {
                    result(FlutterError(code: "START_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
    
    // MARK: - Get Active Config
    
    private func getActiveConfig(result: @escaping FlutterResult) {
        let workingDir = getWorkingDirectory()
        let configPath = workingDir.appendingPathComponent("profiles/active_config.json")
        if let content = try? String(contentsOf: configPath, encoding: .utf8) {
            result(content)
        } else {
            result("")
        }
    }
    
    // MARK: - Helper Methods
    
    private func getAppGroupIdentifier() -> String {
        // Try to find the app group from the main bundle
        if let bundleId = Bundle.main.bundleIdentifier {
            return "group.\(bundleId)"
        }
        return "group.com.example.v2rayBoxExample"
    }
    
    private func getBaseDirectory() -> URL {
        // Use App Group container for sharing with PacketTunnel extension
        if let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: getAppGroupIdentifier()) {
            return sharedContainer
        }
        // Fallback to documents directory
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDir.appendingPathComponent("v2ray_box", isDirectory: true)
    }
    
    private func getWorkingDirectory() -> URL {
        return getBaseDirectory().appendingPathComponent("working", isDirectory: true)
    }
    
    private func getTempDirectory() -> URL {
        return getBaseDirectory().appendingPathComponent("Library/Caches", isDirectory: true)
    }
    
    // MARK: - Event Sinks
    
    func setStatusEventSink(_ sink: FlutterEventSink?) {
        statusEventSink = sink
        if sink != nil {
            // Send current status
            if let status = tunnelManager?.connection.status {
                handleVPNStatusChange(status)
            }
        }
    }
    
    func setAlertsEventSink(_ sink: FlutterEventSink?) {
        alertsEventSink = sink
    }
    
    func setStatsEventSink(_ sink: FlutterEventSink?) {
        statsEventSink = sink
        if sink != nil {
            startStatsTimer()
        } else {
            stopStatsTimer()
        }
    }
    
    func setPingEventSink(_ sink: FlutterEventSink?) {
        pingEventSink = sink
    }
    
    func setLogsEventSink(_ sink: FlutterEventSink?) {
        logsEventSink = sink
    }
    
    private func startStatsTimer() {
        stopStatsTimer()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }
    
    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }
    
    private func updateStats() {
        guard tunnelManager?.connection.status == .connected else { return }
        
        if coreEngine == "singbox" {
            pollSingboxStats()
        } else {
            pollViaProvider()
        }
    }
    
    private func pollSingboxStats() {
        let clashApiPort = 9090
        guard let url = URL(string: "http://127.0.0.1:\(clashApiPort)/connections") else { return }
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)
        
        session.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, error == nil, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            let totalUpload = json["uploadTotal"] as? Int64 ?? 0
            let totalDownload = json["downloadTotal"] as? Int64 ?? 0
            
            let upPerSec = max(0, totalUpload - self.lastSingboxUpload)
            let downPerSec = max(0, totalDownload - self.lastSingboxDownload)
            
            self.lastSingboxUpload = totalUpload
            self.lastSingboxDownload = totalDownload
            
            DispatchQueue.main.async {
                self.statsEventSink?([
                    "connections-in": 0,
                    "connections-out": 0,
                    "uplink": upPerSec,
                    "downlink": downPerSec,
                    "uplink-total": totalUpload,
                    "downlink-total": totalDownload
                ])
            }
        }.resume()
    }
    
    private func pollViaProvider() {
        guard let session = tunnelManager?.connection as? NETunnelProviderSession else { return }
        
        do {
            try session.sendProviderMessage("stats".data(using: .utf8)!) { [weak self] response in
                guard let response = response,
                      let responseStr = String(data: response, encoding: .utf8) else { return }
                
                let components = responseStr.components(separatedBy: ",")
                guard components.count == 2,
                      let upload = Int64(components[0]),
                      let download = Int64(components[1]) else { return }
                
                guard let self = self else { return }
                let upPerSec = max(0, upload - self.lastXrayUpload)
                let downPerSec = max(0, download - self.lastXrayDownload)
                self.lastXrayUpload = upload
                self.lastXrayDownload = download
                
                DispatchQueue.main.async {
                    self.statsEventSink?([
                        "connections-in": 0,
                        "connections-out": 0,
                        "uplink": upPerSec,
                        "downlink": downPerSec,
                        "uplink-total": upload,
                        "downlink-total": download
                    ])
                }
            }
        } catch {
            // Ignore errors
        }
    }
}

// MARK: - Stream Handlers

class StatusStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: V2rayBoxPlugin?
    
    init(plugin: V2rayBoxPlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setStatusEventSink(events)
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setStatusEventSink(nil)
        return nil
    }
}

class AlertsStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: V2rayBoxPlugin?
    
    init(plugin: V2rayBoxPlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setAlertsEventSink(events)
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setAlertsEventSink(nil)
        return nil
    }
}

class StatsStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: V2rayBoxPlugin?
    
    init(plugin: V2rayBoxPlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setStatsEventSink(events)
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setStatsEventSink(nil)
        return nil
    }
}

class PingStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: V2rayBoxPlugin?
    
    init(plugin: V2rayBoxPlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setPingEventSink(events)
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setPingEventSink(nil)
        return nil
    }
}

class LogsStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: V2rayBoxPlugin?
    
    init(plugin: V2rayBoxPlugin) {
        self.plugin = plugin
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setLogsEventSink(events)
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setLogsEventSink(nil)
        return nil
    }
}
