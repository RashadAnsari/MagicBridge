import XCTest

@testable import MagicBridge

class AppStateTests: XCTestCase {
    var appState: AppState!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "enabled_device_ids")
        UserDefaults.standard.removeObject(forKey: "claimed_devices")
        appState = AppState()
    }

    func testToggleEnabledAddsDevice() {
        let device = MagicDevice(id: "aa-bb-cc-dd-ee-ff", name: "Magic Mouse", isConnected: true)
        appState.toggleEnabled(device)
        XCTAssertTrue(appState.isEnabled(device))
    }

    func testToggleEnabledRemovesDevice() {
        let device = MagicDevice(id: "aa-bb-cc-dd-ee-ff", name: "Magic Mouse", isConnected: true)
        appState.toggleEnabled(device)
        appState.toggleEnabled(device)
        XCTAssertFalse(appState.isEnabled(device))
    }

    func testToggleEnabledDoesNotAffectOtherDevices() {
        let mouse = MagicDevice(id: "aa-bb-cc-dd-ee-ff", name: "Magic Mouse", isConnected: true)
        let keyboard = MagicDevice(id: "11-22-33-44-55-66", name: "Magic Keyboard", isConnected: true)
        appState.toggleEnabled(mouse)
        appState.setScannedDevices([mouse, keyboard])
        XCTAssertTrue(appState.isEnabled(mouse))
        XCTAssertFalse(appState.isEnabled(keyboard))
    }

    func testScannedDevicesAreVisible() {
        let device = MagicDevice(id: "aa-bb-cc-dd-ee-ff", name: "Magic Mouse", isConnected: true)
        appState.setScannedDevices([device])
        XCTAssertEqual(appState.devices.count, 1)
        XCTAssertTrue(appState.devices[0].isConnected)
    }

    func testClaimedDeviceRemainsVisibleWhenAbsentFromScan() {
        let device = MagicDevice(id: "aa-bb-cc-dd-ee-ff", name: "Magic Mouse", isConnected: true)
        appState.toggleEnabled(device)
        appState.setScannedDevices([])
        XCTAssertEqual(appState.devices.count, 1)
        XCTAssertFalse(appState.devices[0].isConnected)
    }

    func testClaimedDeviceReflectsUpdatedConnectionState() {
        let connected = MagicDevice(id: "aa-bb-cc-dd-ee-ff", name: "Magic Mouse", isConnected: true)
        appState.toggleEnabled(connected)
        let disconnected = MagicDevice(id: "aa-bb-cc-dd-ee-ff", name: "Magic Mouse", isConnected: false)
        appState.setScannedDevices([disconnected])
        XCTAssertEqual(appState.devices.count, 1)
        XCTAssertFalse(appState.devices[0].isConnected)
    }

    func testUnclaimedDeviceIsNotRetainedAfterScanDisappears() {
        let device = MagicDevice(id: "aa-bb-cc-dd-ee-ff", name: "Magic Mouse", isConnected: true)
        appState.setScannedDevices([device])
        appState.setScannedDevices([])
        XCTAssertTrue(appState.devices.isEmpty)
    }

    func testEnabledDevicesOnlyReturnsEnabledOnes() {
        let mouse = MagicDevice(id: "aa-bb-cc-dd-ee-ff", name: "Magic Mouse", isConnected: true)
        let keyboard = MagicDevice(id: "11-22-33-44-55-66", name: "Magic Keyboard", isConnected: true)
        appState.toggleEnabled(mouse)
        appState.setScannedDevices([mouse, keyboard])
        XCTAssertEqual(appState.enabledDevices.map(\.id), [mouse.id])
    }

    func testEnabledDevicesIsEmptyWhenNoneEnabled() {
        let device = MagicDevice(id: "aa-bb-cc-dd-ee-ff", name: "Magic Mouse", isConnected: true)
        appState.setScannedDevices([device])
        XCTAssertTrue(appState.enabledDevices.isEmpty)
    }
}
