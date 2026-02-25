import Foundation
import NetworkExtension
import Libbox
import LibXray

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private var platformInterface: TunnelPlatformInterface?

    private var coreEngine: String = "singbox"
    private var uploadTotal: Int64 = 0
    private var downloadTotal: Int64 = 0
    private var xrayMetricsListen: String = "127.0.0.1:49227"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let configString = options?["Config"] as? String else {
            completionHandler(NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "Config not provided"]))
            return
        }

        coreEngine = (options?["CoreEngine"] as? String ?? "singbox").lowercased()
        let disableMemoryLimit = (options?["DisableMemoryLimit"] as? String ?? "NO") == "YES"

        Task {
            do {
                switch coreEngine {
                case "xray":
                    try await startXrayTunnel(config: configString)
                default:
                    try await startSingboxTunnel(config: configString, disableMemoryLimit: disableMemoryLimit)
                }
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    private func startSingboxTunnel(config: String, disableMemoryLimit: Bool) async throws {
        let fileManager = FileManager.default
        let workingDir = getWorkingDirectory()
        let cacheDir = getCacheDirectory()
        let sharedDir = getSharedDirectory()

        try fileManager.createDirectory(at: workingDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        let setup = LibboxSetupOptions()
        setup.basePath = sharedDir.path
        setup.workingPath = workingDir.path
        setup.tempPath = cacheDir.path

        var error: NSError?
        LibboxSetup(setup, &error)
        if let error {
            throw error
        }

        LibboxRedirectStderr(cacheDir.appendingPathComponent("stderr.log").path, &error)
        LibboxSetMemoryLimit(!disableMemoryLimit)

        let platform = TunnelPlatformInterface(tunnel: self)
        platformInterface = platform

        guard let server = LibboxNewCommandServer(nil, platform, &error) else {
            if let error {
                throw error
            }
            throw NSError(domain: "V2rayBox", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create command server"])
        }

        do {
            _ = try server.start()
            _ = try server.startOrReloadService(config, options: nil)
        } catch {
            server.close()
            throw error
        }

        commandServer = server
    }

    private func startXrayTunnel(config: String) async throws {
        let fileManager = FileManager.default
        let workingDir = getWorkingDirectory()
        let cacheDir = getCacheDirectory()
        let sharedDir = getSharedDirectory()

        try fileManager.createDirectory(at: workingDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        let preparedConfig = prepareXrayConfig(config)
        xrayMetricsListen = extractXrayMetricsListen(preparedConfig) ?? "127.0.0.1:49227"

        let (socksPort, httpPort) = extractXrayProxyPorts(preparedConfig)
        try await applyXrayNetworkSettings(socksPort: socksPort, httpPort: httpPort)

        var requestError: NSError?
        let request = LibXrayNewXrayRunFromJSONRequest(
            sharedDir.path,
            cacheDir.appendingPathComponent("xray.mph").path,
            preparedConfig,
            &requestError
        )
        if let requestError {
            throw requestError
        }

        guard let response = decodeLibXrayCallResponse(LibXrayRunXrayFromJSON(request)), response.success else {
            let message = decodeLibXrayCallResponse(LibXrayRunXrayFromJSON(request))?.error ?? "runXrayFromJSON failed"
            throw NSError(domain: "V2rayBox", code: -20, userInfo: [NSLocalizedDescriptionKey: message])
        }

        _ = refreshXrayTotals()
    }

    private func stopSingboxTunnel() {
        if let server = commandServer {
            do {
                _ = try server.closeService()
            } catch {
                NSLog("closeService error: \(error.localizedDescription)")
            }
            server.close()
            commandServer = nil
        }
        platformInterface?.reset()
    }

    private func stopXrayTunnel() {
        if let response = decodeLibXrayCallResponse(LibXrayStopXray()), !response.success {
            NSLog("stopXray error: \(response.error ?? "unknown")")
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        if coreEngine == "xray" {
            stopXrayTunnel()
        } else {
            stopSingboxTunnel()
        }
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }

        if message == "stats" {
            if coreEngine == "xray" {
                _ = refreshXrayTotals()
            }
            completionHandler?("\(uploadTotal),\(downloadTotal)".data(using: .utf8))
            return
        }

        if message == "xray_version" {
            let version = coreEngine == "xray" ? queryXrayVersion() : ""
            completionHandler?(version.data(using: .utf8))
            return
        }

        completionHandler?(nil)
    }

    func writeMessage(_ message: String) {
        commandServer?.writeMessage(1, message: message)
        NSLog(message)
    }

    func writeFatalError(_ message: String) {
        NSLog("FATAL: \(message)")
        cancelTunnelWithError(NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    func updateTraffic(upload: Int64, download: Int64) {
        uploadTotal = upload
        downloadTotal = download
    }

    private func getSharedDirectory() -> URL {
        let groupId = getAppGroupIdentifier()
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId)!
    }

    private func getWorkingDirectory() -> URL {
        getSharedDirectory().appendingPathComponent("working", isDirectory: true)
    }

    private func getCacheDirectory() -> URL {
        getSharedDirectory()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    }

    private func getAppGroupIdentifier() -> String {
        if let groupId = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String {
            return groupId
        }
        let mainBundleId = Bundle.main.bundleIdentifier?.replacingOccurrences(of: ".PacketTunnel", with: "") ?? "com.example.v2raybox"
        return "group.\(mainBundleId)"
    }

    private func applyXrayNetworkSettings(socksPort: Int, httpPort: Int) async throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: 1500)

        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])

        let proxy = NEProxySettings()
        if httpPort > 0 {
            let server = NEProxyServer(address: "127.0.0.1", port: httpPort)
            proxy.httpServer = server
            proxy.httpsServer = server
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
        }
        proxy.matchDomains = [""]
        settings.proxySettings = proxy

        try await setTunnelNetworkSettings(settings)
    }

    private func prepareXrayConfig(_ rawConfig: String) -> String {
        guard
            let data = rawConfig.data(using: .utf8),
            var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return rawConfig
        }

        var inbounds = (root["inbounds"] as? [[String: Any]]) ?? []
        inbounds = inbounds.filter { ($0["protocol"] as? String)?.lowercased() != "tun" }

        if !inbounds.contains(where: { ($0["protocol"] as? String)?.lowercased() == "socks" }) {
            inbounds.append([
                "tag": "socks",
                "port": 10808,
                "listen": "127.0.0.1",
                "protocol": "socks",
                "settings": ["auth": "noauth", "udp": true]
            ])
        }

        if !inbounds.contains(where: { ($0["protocol"] as? String)?.lowercased() == "http" }) {
            inbounds.append([
                "tag": "http",
                "port": 10809,
                "listen": "127.0.0.1",
                "protocol": "http",
                "settings": [:] as [String: Any]
            ])
        }

        root["inbounds"] = inbounds

        var policy = (root["policy"] as? [String: Any]) ?? [:]
        var systemPolicy = (policy["system"] as? [String: Any]) ?? [:]
        systemPolicy["statsInboundDownlink"] = true
        systemPolicy["statsInboundUplink"] = true
        systemPolicy["statsOutboundDownlink"] = true
        systemPolicy["statsOutboundUplink"] = true
        policy["system"] = systemPolicy
        root["policy"] = policy
        root["stats"] = (root["stats"] as? [String: Any]) ?? [:]
        root["metrics"] = ["tag": "metrics", "listen": "127.0.0.1:49227"]

        guard
            let newData = try? JSONSerialization.data(withJSONObject: root),
            let json = String(data: newData, encoding: .utf8)
        else {
            return rawConfig
        }

        return json
    }

    private func extractXrayProxyPorts(_ config: String) -> (socks: Int, http: Int) {
        guard
            let data = config.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let inbounds = root["inbounds"] as? [[String: Any]]
        else {
            return (10808, 10809)
        }

        var socksPort = 10808
        var httpPort = 10809

        for inbound in inbounds {
            guard let protocolName = (inbound["protocol"] as? String)?.lowercased() else { continue }
            let port = intValue(inbound["port"])
            if protocolName == "socks", let port {
                socksPort = port
            } else if protocolName == "http", let port {
                httpPort = port
            }
        }

        return (socksPort, httpPort)
    }

    private func extractXrayMetricsListen(_ config: String) -> String? {
        guard
            let data = config.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let metrics = root["metrics"] as? [String: Any],
            let listen = metrics["listen"] as? String,
            !listen.isEmpty
        else {
            return nil
        }
        return listen
    }

    private func refreshXrayTotals() -> (Int64, Int64) {
        let listen = xrayMetricsListen.isEmpty ? "127.0.0.1:49227" : xrayMetricsListen
        let metricsURL = listen.hasPrefix("http://") || listen.hasPrefix("https://")
            ? "\(listen.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/debug/vars"
            : "http://\(listen)/debug/vars"

        let encodedURL = Data(metricsURL.utf8).base64EncodedString()
        guard
            let response = decodeLibXrayCallResponse(LibXrayQueryStats(encodedURL)),
            response.success,
            let body = response.dataString(),
            let data = body.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (uploadTotal, downloadTotal)
        }

        let statsRoot: [String: Any]
        if let stats = root["stats"] as? [String: Any] {
            statsRoot = stats
        } else {
            statsRoot = root
        }

        var totalUp: Int64 = 0
        var totalDown: Int64 = 0

        if let outbound = statsRoot["outbound"] as? [String: Any],
           let proxy = outbound["proxy"] as? [String: Any] {
            totalUp = int64Value(proxy["uplink"]) ?? totalUp
            totalDown = int64Value(proxy["downlink"]) ?? totalDown
        }

        if totalUp == 0 {
            totalUp = int64Value(statsRoot["outbound>>>proxy>>>traffic>>>uplink"]) ?? totalUp
        }
        if totalDown == 0 {
            totalDown = int64Value(statsRoot["outbound>>>proxy>>>traffic>>>downlink"]) ?? totalDown
        }

        uploadTotal = max(0, totalUp)
        downloadTotal = max(0, totalDown)
        return (uploadTotal, downloadTotal)
    }

    private func queryXrayVersion() -> String {
        guard
            let response = decodeLibXrayCallResponse(LibXrayXrayVersion()),
            response.success,
            let version = response.dataString(),
            !version.isEmpty
        else {
            return ""
        }
        return version
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let int32Value = value as? Int32 { return Int(int32Value) }
        if let int64Value = value as? Int64 { return Int(int64Value) }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let intValue = value as? Int { return Int64(intValue) }
        if let int32Value = value as? Int32 { return Int64(int32Value) }
        if let int64Value = value as? Int64 { return int64Value }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String, let parsed = Int64(string) { return parsed }
        return nil
    }

    private struct LibXrayCallResponse {
        let success: Bool
        let data: Any?
        let error: String?

        func dataString() -> String? {
            if let value = data as? String { return value }
            if let number = data as? NSNumber { return number.stringValue }
            return nil
        }
    }

    private func decodeLibXrayCallResponse(_ encoded: String?) -> LibXrayCallResponse? {
        guard let encoded,
              !encoded.isEmpty,
              let raw = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return nil
        }
        return LibXrayCallResponse(
            success: object["success"] as? Bool ?? false,
            data: object["data"],
            error: object["error"] as? String
        )
    }
}

final class TunnelPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {

    private weak var tunnel: PacketTunnelProvider?
    private var networkSettings: NEPacketTunnelNetworkSettings?

    init(tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    func reset() {
        networkSettings = nil
    }

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [self] in
            try await openTunAsync(options, ret0_)
        }
    }

    private func openTunAsync(_ options: (any LibboxTunOptionsProtocol)?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let options = options else {
            throw NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil options"])
        }
        guard let ret0_ = ret0_ else {
            throw NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil return pointer"])
        }
        guard let tunnel = tunnel else {
            throw NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "tunnel is nil"])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            var dnsServers = ["1.1.1.1", "8.8.8.8"]
            do {
                let dnsBox = try options.getDNSServerAddress()
                let dnsStr = dnsBox.value
                if !dnsStr.isEmpty {
                    dnsServers = dnsStr.components(separatedBy: "\n").filter { !$0.isEmpty }
                }
            } catch {}
            settings.dnsSettings = NEDNSSettings(servers: dnsServers)

            var ipv4Addresses: [String] = []
            var ipv4Masks: [String] = []
            if let iterator = options.getInet4Address() {
                while iterator.hasNext() {
                    if let prefix = iterator.next() {
                        ipv4Addresses.append(prefix.address())
                        ipv4Masks.append(prefix.mask())
                    }
                }
            }

            if !ipv4Addresses.isEmpty {
                let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)
                var routes: [NEIPv4Route] = []

                if let routeIterator = options.getInet4RouteAddress(), routeIterator.hasNext() {
                    while routeIterator.hasNext() {
                        if let prefix = routeIterator.next() {
                            routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                        }
                    }
                } else {
                    routes.append(NEIPv4Route.default())
                }

                ipv4Settings.includedRoutes = routes
                settings.ipv4Settings = ipv4Settings
            }

            var ipv6Addresses: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            if let iterator = options.getInet6Address() {
                while iterator.hasNext() {
                    if let prefix = iterator.next() {
                        ipv6Addresses.append(prefix.address())
                        ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
                    }
                }
            }

            if !ipv6Addresses.isEmpty {
                let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes)
                ipv6Settings.includedRoutes = [NEIPv6Route.default()]
                settings.ipv6Settings = ipv6Settings
            }
        }

        if options.isHTTPProxyEnabled() {
            let proxySettings = NEProxySettings()
            let proxyServer = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            proxySettings.httpServer = proxyServer
            proxySettings.httpsServer = proxyServer
            proxySettings.httpEnabled = true
            proxySettings.httpsEnabled = true
            settings.proxySettings = proxySettings
        }

        networkSettings = settings
        try await tunnel.setTunnelNetworkSettings(settings)

        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            return
        }

        let tunFdFromLoop = LibboxGetTunnelFileDescriptor()
        if tunFdFromLoop != -1 {
            ret0_.pointee = tunFdFromLoop
        } else {
            throw NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "missing file descriptor"])
        }
    }

    func usePlatformAutoDetectControl() -> Bool { true }
    func autoDetectControl(_ fd: Int32) throws {}

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "not implemented"])
    }

    func packageName(byUid uid: Int32, error: NSErrorPointer) -> String { "" }

    func uid(byPackageName packageName: String?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "not implemented"])
    }

    func useProcFS() -> Bool { false }

    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {}
    func closeDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {}

    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        throw NSError(domain: "V2rayBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "not implemented"])
    }

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }

    func clearDNSCache() {
        guard let settings = networkSettings, let tunnel = tunnel else { return }
        tunnel.reasserting = true
        tunnel.setTunnelNetworkSettings(nil) { _ in }
        tunnel.setTunnelNetworkSettings(settings) { _ in }
        tunnel.reasserting = false
    }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func send(_ notification: LibboxNotification?) throws {}
}

private func runBlocking<T>(_ block: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!

    Task.detached {
        do {
            let value = try await block()
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }

    semaphore.wait()
    return try result.get()
}
