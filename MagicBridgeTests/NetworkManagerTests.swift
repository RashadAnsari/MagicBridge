import Network
import XCTest

@testable import MagicBridge

class NetworkManagerTests: XCTestCase {

    var manager: NetworkManager!
    var appState: AppState!

    private var testDone = false
    private var tcpListenerIsOurs = false
    private var peersAtTestStart = 0

    private let port: NWEndpoint.Port = 57842

    override func setUp() {
        super.setUp()
        testDone = false
        tcpListenerIsOurs = false
        UserDefaults.standard.removeObject(forKey: "magicbridge_instance_id")
        UserDefaults.standard.removeObject(forKey: "enabled_device_ids")
        UserDefaults.standard.removeObject(forKey: "claimed_devices")
        appState = AppState()
        manager = NetworkManager()
        manager.appState = appState
        manager.start()
        Thread.sleep(forTimeInterval: 0.3)

        // Send a probe hello and spin the run loop up to 0.5 s to see if our
        // manager receives it. If the real app is running on port 57842 our
        // listener falls back to a random port, the probe goes to the wrong
        // process, and TCP-based tests are skipped automatically.
        let probeID = "probe-\(UUID().uuidString)"
        sendToListener(["action": "hello", "id": probeID, "name": "probe", "version": 1])
        let probeDeadline = Date().addingTimeInterval(0.5)
        while Date() < probeDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if appState.peers.contains(where: { $0.id == probeID }) {
                tcpListenerIsOurs = true
                break
            }
        }
        peersAtTestStart = appState.peers.count
    }

    override func tearDown() {
        testDone = true
        manager.stop()
        manager = nil
        appState = nil
        super.tearDown()
    }

    func testSendReleaseWithNoPeersCompletesImmediately() {
        let exp = expectation(description: "completion called")
        manager.sendRelease(devices: []) { allConfirmed in
            XCTAssertTrue(allConfirmed)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testHelloMessageRegistersPeerInAppState() throws {
        try XCTSkipUnless(tcpListenerIsOurs, "Port 57842 not owned by test manager")
        let peerID = UUID().uuidString
        let exp = expectation(description: "peer appears in appState")

        sendToListener(["action": "hello", "id": peerID, "name": "Test Mac", "version": 1])
        pollMain(until: { [weak self] in
            self?.appState?.peers.contains(where: { $0.id == peerID }) ?? false
        }, fulfill: exp)

        wait(for: [exp], timeout: 5)
    }

    func testHelloMessageStoresPeerName() throws {
        try XCTSkipUnless(tcpListenerIsOurs, "Port 57842 not owned by test manager")
        let peerID = UUID().uuidString
        let exp = expectation(description: "peer name stored")

        sendToListener(["action": "hello", "id": peerID, "name": "Studio Mac", "version": 1])
        pollMain(until: { [weak self] in
            self?.appState?.peers.first(where: { $0.id == peerID })?.name == "Studio Mac"
        }, fulfill: exp)

        wait(for: [exp], timeout: 5)
    }

    func testHelloFromSelfIsIgnored() throws {
        try XCTSkipUnless(tcpListenerIsOurs, "Port 57842 not owned by test manager")
        let ownID = UserDefaults.standard.string(forKey: "magicbridge_instance_id") ?? ""
        XCTAssertFalse(ownID.isEmpty, "instance ID must be persisted after init")

        sendToListener(["action": "hello", "id": ownID, "name": "Self", "version": 1])

        let pause = expectation(description: "processing window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pause.fulfill() }
        wait(for: [pause], timeout: 1)

        XCTAssertFalse(appState.peers.contains(where: { $0.id == ownID }),
                       "manager must not register itself as a peer")
    }

    func testDuplicateHelloDoesNotAddDuplicatePeer() throws {
        try XCTSkipUnless(tcpListenerIsOurs, "Port 57842 not owned by test manager")
        let peerID = UUID().uuidString
        let firstSeen = expectation(description: "first hello registered")

        sendToListener(["action": "hello", "id": peerID, "name": "Test Mac", "version": 1])
        pollMain(until: { [weak self] in
            self?.appState?.peers.contains(where: { $0.id == peerID }) ?? false
        }, fulfill: firstSeen)
        wait(for: [firstSeen], timeout: 5)

        sendToListener(["action": "hello", "id": peerID, "name": "Test Mac", "version": 1])

        let pause = expectation(description: "second hello processing window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pause.fulfill() }
        wait(for: [pause], timeout: 1)

        XCTAssertEqual(appState.peers.filter { $0.id == peerID }.count, 1,
                       "duplicate hello must not create a second peer entry")
    }

    func testHelloWithEmptyIDIsIgnored() throws {
        try XCTSkipUnless(tcpListenerIsOurs, "Port 57842 not owned by test manager")
        sendToListener(["action": "hello", "id": "", "name": "Ghost", "version": 1])

        let pause = expectation(description: "processing window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pause.fulfill() }
        wait(for: [pause], timeout: 1)

        XCTAssertEqual(appState.peers.count, peersAtTestStart,
                       "empty-ID hello must not add a peer")
    }

    func testReleaseDevicesTriggersOnReceiveRelease() throws {
        try XCTSkipUnless(tcpListenerIsOurs, "Port 57842 not owned by test manager")
        let deviceIDs = ["aa:bb:cc:dd:ee:ff", "11:22:33:44:55:66"]
        let exp = expectation(description: "onReceiveRelease called")

        manager.onReceiveRelease = { receivedIDs, acknowledge in
            XCTAssertEqual(Set(receivedIDs), Set(deviceIDs))
            acknowledge()
            exp.fulfill()
        }

        sendToListener(["action": "release_devices", "devices": deviceIDs])
        wait(for: [exp], timeout: 5)
    }

    func testReleaseDevicesAcknowledgmentSendsDevicesReleased() throws {
        try XCTSkipUnless(tcpListenerIsOurs, "Port 57842 not owned by test manager")
        let deviceIDs = ["aa:bb:cc:dd:ee:ff"]
        let exp = expectation(description: "devices_released received")

        manager.onReceiveRelease = { _, acknowledge in acknowledge() }

        let conn = makeConnection()
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            sendFrame(["action": "release_devices", "devices": deviceIDs], on: conn)
            readOneMessage(on: conn) { msg in
                if msg["action"] as? String == "devices_released" {
                    XCTAssertEqual(msg["devices"] as? [String], deviceIDs)
                    exp.fulfill()
                }
            }
        }
        conn.start(queue: .global(qos: .utility))
        wait(for: [exp], timeout: 5)
        conn.cancel()
    }

    func testReleaseDevicesWithNoHandlerDoesNotCrash() throws {
        try XCTSkipUnless(tcpListenerIsOurs, "Port 57842 not owned by test manager")
        manager.onReceiveRelease = nil
        sendToListener(["action": "release_devices", "devices": ["aa:bb:cc:dd:ee:ff"]])

        let pause = expectation(description: "processing window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pause.fulfill() }
        wait(for: [pause], timeout: 1)
    }

    func testOversizedFrameIsRejectedGracefully() throws {
        try XCTSkipUnless(tcpListenerIsOurs, "Port 57842 not owned by test manager")
        let conn = makeConnection()
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                var length = UInt32(2_097_152).bigEndian
                let header = Data(bytes: &length, count: 4)
                conn.send(content: header, completion: .contentProcessed { _ in })
            }
        }
        conn.start(queue: .global(qos: .utility))

        let pause = expectation(description: "processing window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pause.fulfill() }
        wait(for: [pause], timeout: 1)
        conn.cancel()

        XCTAssertEqual(appState.peers.count, peersAtTestStart,
                       "oversized frame must not register a peer")
    }

    func testUnknownActionIsIgnoredGracefully() throws {
        try XCTSkipUnless(tcpListenerIsOurs, "Port 57842 not owned by test manager")
        sendToListener(["action": "unknown_action", "id": UUID().uuidString])

        let pause = expectation(description: "processing window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pause.fulfill() }
        wait(for: [pause], timeout: 1)

        XCTAssertEqual(appState.peers.count, peersAtTestStart,
                       "unknown action must not register a peer")
    }

    private func makeConnection() -> NWConnection {
        NWConnection(to: NWEndpoint.hostPort(host: "127.0.0.1", port: port), using: .tcp)
    }

    private func sendToListener(_ msg: [String: Any]) {
        let conn = makeConnection()
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.sendFrame(msg, on: conn) }
        }
        conn.start(queue: .global(qos: .utility))
    }

    private func sendFrame(_ msg: [String: Any], on conn: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        var length = UInt32(data.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(data)
        conn.send(content: framed, completion: .contentProcessed { _ in })
    }

    private func readOneMessage(on conn: NWConnection, handler: @escaping ([String: Any]) -> Void) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else { return }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0, length <= 1_048_576 else { return }
            conn.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) {
                payload, _, _, _ in
                guard let payload,
                    let msg = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
                else { return }
                handler(msg)
            }
        }
    }

    private func pollMain(until condition: @escaping () -> Bool, fulfill exp: XCTestExpectation) {
        func check() {
            guard !testDone else { return }
            if condition() {
                exp.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
    }
}
