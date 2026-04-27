import AppKit
import Foundation
import Network
import OSLog
import SystemConfiguration

private let logger = Logger(subsystem: "me.ansarihamedani.magicbridge", category: "network")

class NetworkManager: NSObject {
    private let serviceType = "_magicbridge._tcp"
    private let tcpPort: UInt16 = 57842

    private let helloIntervalSeconds: TimeInterval = 15
    private let helloTTLSeconds: TimeInterval = 45
    private let helloProtocolVersion: Int = 1

    private let instanceID: String
    private let displayName: String

    private var listener: NWListener?
    private var netService: NetService?
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var peerAddresses: [String: (host: String, port: Int)] = [:]
    private var peerLastHello: [String: Date] = [:]
    private var bonjourLivePeerIDs: Set<String> = []
    private var helloTimer: DispatchSourceTimer?
    private var sweepTimer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?

    weak var appState: AppState?
    var onReceiveRelease: (([String], @escaping () -> Void) -> Void)?

    override init() {
        let key = "magicbridge_instance_id"
        if let saved = UserDefaults.standard.string(forKey: key) {
            instanceID = saved
        } else {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: key)
            instanceID = id
        }
        displayName =
            SCDynamicStoreCopyComputerName(nil, nil) as String?
            ?? ProcessInfo.processInfo.hostName
        super.init()
    }

    func start() {
        startTCPListener()
        startMDNSAdvertising()
        startMDNSBrowsing()
        startHelloTimer()
        startSweepTimer()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sendHelloToAllPeers()
        }
    }

    func stop() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        helloTimer?.cancel()
        helloTimer = nil
        sweepTimer?.cancel()
        sweepTimer = nil
        listener?.cancel()
        netService?.stop()
        browser?.stop()
    }

    private func startTCPListener() {
        do {
            listener = try NWListener(
                using: .tcp,
                on: NWEndpoint.Port(rawValue: tcpPort) ?? .any)
            listener?.newConnectionHandler = { [weak self] conn in self?.handleIncoming(conn) }
            listener?.stateUpdateHandler = { state in
                if case .failed(let e) = state { logger.error("Listener failed: \(e)") }
            }
            listener?.start(queue: .global(qos: .utility))
        } catch {
            logger.error("TCP listener failed to start: \(error)")
        }
    }

    private func handleIncoming(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive(on: conn)
            case .failed, .cancelled: conn.cancel()
            default: break
            }
        }
        conn.start(queue: .global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { conn.cancel() }
    }

    private func startMDNSAdvertising() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.netService = NetService(
                domain: "local.", type: self.serviceType,
                name: self.instanceID, port: Int32(self.tcpPort))
            let txt: [String: Data] = [
                "id": self.instanceID.data(using: .utf8) ?? Data(),
                "name": self.displayName.data(using: .utf8) ?? Data(),
            ]
            self.netService?.setTXTRecord(NetService.data(fromTXTRecord: txt))
            self.netService?.delegate = self
            self.netService?.schedule(in: .main, forMode: .common)
            self.netService?.publish()
        }
    }

    private func startMDNSBrowsing() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.browser = NetServiceBrowser()
            self.browser?.delegate = self
            self.browser?.schedule(in: .main, forMode: .common)
            self.browser?.searchForServices(ofType: self.serviceType, inDomain: "local.")
        }
    }

    private func startHelloTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + helloIntervalSeconds, repeating: helloIntervalSeconds)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.sendHelloToAllPeers() }
        }
        timer.resume()
        helloTimer = timer
    }

    private func startSweepTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + helloIntervalSeconds, repeating: helloIntervalSeconds)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.evictStalePeers() }
        }
        timer.resume()
        sweepTimer = timer
    }

    private func sendHelloToAllPeers() {
        for (_, addr) in peerAddresses {
            sendHelloTo(host: addr.host, port: addr.port)
        }
    }

    private func sendHelloTo(host: String, port: Int) {
        let payload: [String: Any] = [
            "action": "hello",
            "id": instanceID,
            "name": displayName,
            "version": helloProtocolVersion,
        ]
        sendOneShot(payload, to: host, port: port)
    }

    private func sendOneShot(_ msg: [String: Any], to host: String, port: Int) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        let framed = frame(data)
        guard port > 0, port <= Int(UInt16.max),
            let nwPort = NWEndpoint.Port(rawValue: UInt16(port))
        else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort)
        let conn = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue.global(qos: .utility)
        let finishQueue = DispatchQueue(label: "me.ansarihamedani.magicbridge.network.oneshot")
        var done = false
        let finish = {
            finishQueue.async {
                guard !done else { return }
                done = true
                conn.cancel()
            }
        }
        queue.asyncAfter(deadline: .now() + 3) { finish() }
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                conn.send(content: framed, completion: .contentProcessed { _ in finish() })
            } else if case .failed = state {
                finish()
            }
        }
        conn.start(queue: queue)
    }

    private func evictStalePeers() {
        let cutoff = Date().addingTimeInterval(-helloTTLSeconds)
        let staleIDs = peerLastHello.compactMap { (id, lastSeen) -> String? in
            guard lastSeen < cutoff, !bonjourLivePeerIDs.contains(id) else { return nil }
            return id
        }
        for id in staleIDs {
            peerAddresses.removeValue(forKey: id)
            peerLastHello.removeValue(forKey: id)
            appState?.peers.removeAll { $0.id == id }
        }
    }

    func sendRelease(devices: [MagicDevice], completion: @escaping (_ allConfirmed: Bool) -> Void) {
        let targets = peerAddresses
        guard !targets.isEmpty else {
            completion(true)
            return
        }

        let deviceIDs = devices.map { $0.id }
        let group = DispatchGroup()
        var allConfirmed = true
        let lock = NSLock()
        for (_, addr) in targets {
            group.enter()
            sendReleaseTo(host: addr.host, port: addr.port, deviceIDs: deviceIDs) { confirmed in
                lock.lock()
                if !confirmed { allConfirmed = false }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(allConfirmed) }
    }

    private func sendReleaseTo(
        host: String, port: Int, deviceIDs: [String], completion: @escaping (Bool) -> Void
    ) {
        guard port > 0, port <= Int(UInt16.max),
            let nwPort = NWEndpoint.Port(rawValue: UInt16(port))
        else {
            completion(false)
            return
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort)
        let conn = NWConnection(to: endpoint, using: .tcp)
        let finishQueue = DispatchQueue(label: "me.ansarihamedani.magicbridge.network.finish")
        var done = false
        let finish = { (confirmed: Bool) in
            finishQueue.async {
                guard !done else { return }
                done = true
                conn.cancel()
                completion(confirmed)
            }
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { finish(false) }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.send(
                    [
                        "action": "release_devices", "sender": self?.instanceID ?? "",
                        "devices": deviceIDs,
                    ], on: conn)
                self?.receive(on: conn, onDevicesReleased: { finish(true) })
            case .failed: finish(false)
            default: break
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    private func frame(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(data)
        return framed
    }

    private func send(_ msg: [String: Any], on conn: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        conn.send(content: frame(data), completion: .contentProcessed { _ in })
    }

    private func receive(on conn: NWConnection, onDevicesReleased: (() -> Void)? = nil) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, _ in
            guard let self, let header, header.count == 4 else { return }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0, length <= 1_048_576 else { return }
            conn.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) {
                [weak self] payload, _, _, _ in
                guard let self, let payload, !payload.isEmpty else { return }
                guard let msg = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                    let action = msg["action"] as? String
                else { return }
                let deviceIDs = msg["devices"] as? [String] ?? []
                switch action {
                case "release_devices":
                    DispatchQueue.main.async {
                        self.onReceiveRelease?(deviceIDs) {
                            self.send(
                                [
                                    "action": "devices_released", "sender": self.instanceID,
                                    "devices": deviceIDs,
                                ], on: conn)
                        }
                    }
                case "devices_released":
                    onDevicesReleased?()
                case "hello":
                    let senderID = msg["id"] as? String ?? ""
                    let senderName = msg["name"] as? String ?? ""
                    guard !senderID.isEmpty, senderID != self.instanceID else { return }
                    if let host = self.remoteHost(of: conn) {
                        DispatchQueue.main.async {
                            self.peerLastHello[senderID] = Date()
                            self.peerAddresses[senderID] = (host: host, port: Int(self.tcpPort))
                            if !(self.appState?.peers.contains(where: { $0.id == senderID })
                                ?? false)
                            {
                                self.appState?.peers.append(Peer(id: senderID, name: senderName))
                            }
                        }
                    }
                default: break
                }
            }
        }
    }

    private func remoteHost(of conn: NWConnection) -> String? {
        guard case .hostPort(let host, _) = conn.endpoint else { return nil }
        switch host {
        case .name(let name, _): return name
        case .ipv4(let addr): return "\(addr)"
        case .ipv6(let addr): return "\(addr)"
        @unknown default: return nil
        }
    }
}

extension NetworkManager: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
    ) {
        guard service.name != instanceID else { return }
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 10)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool
    ) {
        let id = service.name
        resolving.removeAll { $0.name == id }
        bonjourLivePeerIDs.remove(id)

        // Only evict immediately if no recent hello — prevents flicker when Bonjour TTL
        // expires while the peer is still alive and sending heartbeats.
        let lastHello = peerLastHello[id] ?? .distantPast
        if Date().timeIntervalSince(lastHello) >= helloTTLSeconds {
            peerAddresses.removeValue(forKey: id)
            peerLastHello.removeValue(forKey: id)
            DispatchQueue.main.async { self.appState?.peers.removeAll { $0.id == id } }
        }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.startMDNSBrowsing()
        }
    }
}

extension NetworkManager: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let txt = sender.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        let id = txt["id"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.name
        let name = txt["name"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.name

        peerAddresses[id] = (host: host, port: sender.port)
        bonjourLivePeerIDs.insert(id)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !(self.appState?.peers.contains(where: { $0.id == id }) ?? false) {
                self.appState?.peers.append(Peer(id: id, name: name))
            }
            // Send an immediate hello so the peer learns our address without waiting
            // up to 15 s for the next heartbeat tick — critical for the asymmetric case.
            self.sendHelloTo(host: host, port: Int(self.tcpPort))
        }
        resolving.removeAll { $0.name == sender.name }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0.name == sender.name }
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        logger.error("mDNS publish failed: \(errorDict)")
    }
}
