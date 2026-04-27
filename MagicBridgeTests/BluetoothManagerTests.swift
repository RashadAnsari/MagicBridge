import XCTest

@testable import MagicBridge

class BluetoothManagerTests: XCTestCase {
    let bt = BluetoothManager()

    func testMagicMouseIsRecognised() {
        XCTAssertTrue(bt.isMagicDeviceName("Magic Mouse"))
        XCTAssertTrue(bt.isMagicDeviceName("Magic Mouse 2"))
    }

    func testMagicKeyboardIsRecognised() {
        XCTAssertTrue(bt.isMagicDeviceName("Magic Keyboard"))
        XCTAssertTrue(bt.isMagicDeviceName("Magic Keyboard with Touch ID"))
    }

    func testMagicTrackpadIsRecognised() {
        XCTAssertTrue(bt.isMagicDeviceName("Magic Trackpad"))
        XCTAssertTrue(bt.isMagicDeviceName("Magic Trackpad 2"))
    }

    func testNonMagicDeviceIsRejected() {
        XCTAssertFalse(bt.isMagicDeviceName("AirPods Pro"))
        XCTAssertFalse(bt.isMagicDeviceName("Bose QC45"))
        XCTAssertFalse(bt.isMagicDeviceName(""))
    }

    func testCaseInsensitiveMatching() {
        XCTAssertTrue(bt.isMagicDeviceName("magic mouse"))
        XCTAssertTrue(bt.isMagicDeviceName("MAGIC KEYBOARD"))
        XCTAssertTrue(bt.isMagicDeviceName("magic trackpad 2"))
    }
}
