import Foundation
import Network

class NetworkManager: NSObject {
    private let serviceType = "_magicbridge._tcp"
    private let tcpPort: UInt16 = 57842

    private let instanceID: String
    private let displayName: String

    private var listener: NWListener?
    private var netService: NetService?
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var peerAddresses: [String: (host: String, port: Int)] = [:]

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
        displayName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        super.init()
    }

    func start() {
        startTCPListener()
        startMDNSAdvertising()
        startMDNSBrowsing()
    }

    func stop() {
        listener?.cancel()
        netService?.stop()
        browser?.stop()
    }

    // MARK: - TCP Listener

    private func startTCPListener() {
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: tcpPort)!)
            listener?.newConnectionHandler = { [weak self] conn in self?.handleIncoming(conn) }
            listener?.stateUpdateHandler = { state in
                if case .failed(let e) = state { print("[Net] Listener: \(e)") }
            }
            listener?.start(queue: .global(qos: .utility))
        } catch {
            print("[Net] TCP listener failed: \(error)")
        }
    }

    private func handleIncoming(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receive(on: conn) }
        }
        conn.start(queue: .global(qos: .utility))
    }

    // MARK: - mDNS Advertising

    private func startMDNSAdvertising() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.netService = NetService(
                domain: "local.", type: self.serviceType,
                name: self.instanceID, port: Int32(self.tcpPort))
            let txt: [String: Data] = [
                "id": self.instanceID.data(using: .utf8)!,
                "name": self.displayName.data(using: .utf8)!,
            ]
            self.netService?.setTXTRecord(NetService.data(fromTXTRecord: txt))
            self.netService?.delegate = self
            self.netService?.schedule(in: .main, forMode: .common)
            self.netService?.publish()
        }
    }

    // MARK: - mDNS Browsing

    private func startMDNSBrowsing() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.browser = NetServiceBrowser()
            self.browser?.delegate = self
            self.browser?.schedule(in: .main, forMode: .common)
            self.browser?.searchForServices(ofType: self.serviceType, inDomain: "local.")
        }
    }

    // MARK: - Send release to all peers

    func sendRelease(devices: [MagicDevice], completion: @escaping () -> Void) {
        let targets = peerAddresses
        guard !targets.isEmpty else {
            completion()
            return
        }

        let deviceIDs = devices.map { $0.id }
        let group = DispatchGroup()
        for (_, addr) in targets {
            group.enter()
            sendReleaseTo(host: addr.host, port: addr.port, deviceIDs: deviceIDs) { group.leave() }
        }
        group.notify(queue: .main) { completion() }
    }

    private func sendReleaseTo(
        host: String, port: Int, deviceIDs: [String], completion: @escaping () -> Void
    ) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let conn = NWConnection(to: endpoint, using: .tcp)
        let finishQueue = DispatchQueue(label: "com.magicbridge.network.finish")
        var done = false
        let finish = {
            finishQueue.async {
                guard !done else { return }
                done = true
                conn.cancel()
                completion()
            }
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { finish() }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.send(
                    [
                        "action": "release_devices", "sender": self?.instanceID ?? "",
                        "devices": deviceIDs,
                    ], on: conn)
                self?.receive(on: conn, onDevicesReleased: finish)
            case .failed: finish()
            default: break
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    // MARK: - Messaging

    private func send(_ msg: [String: Any], on conn: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive(on conn: NWConnection, onDevicesReleased: (() -> Void)? = nil) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { return }
            guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            default: break
            }
        }
    }
}

// MARK: - NetServiceBrowserDelegate

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
        peerAddresses.removeValue(forKey: id)
        DispatchQueue.main.async { self.appState?.peers.removeAll { $0.id == id } }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.startMDNSBrowsing()
        }
    }
}

// MARK: - NetServiceDelegate

extension NetworkManager: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let txt = sender.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        let id = txt["id"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.name
        let name = txt["name"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.name

        peerAddresses[id] = (host: host, port: sender.port)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !(self.appState?.peers.contains(where: { $0.id == id }) ?? false) {
                self.appState?.peers.append(Peer(id: id, name: name))
            }
        }
        resolving.removeAll { $0.name == sender.name }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0.name == sender.name }
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("[Net] Publish failed: \(errorDict)")
    }
}
