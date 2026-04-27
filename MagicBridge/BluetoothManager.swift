import CoreBluetooth
import Foundation
import IOBluetooth

enum ConnectError {
    case pairFailed
    case connectFailed
}

class BluetoothManager: NSObject, CBCentralManagerDelegate {
    private let btQueue = DispatchQueue(
        label: "me.ansarihamedani.magicbridge.bluetooth", qos: .userInitiated)
    private var centralManager: CBCentralManager?

    var onDeviceStateChanged: (() -> Void)?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    func requestPermission() {
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func startNotifications() {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:)))
    }

    func registerDisconnectNotifications(for devices: [MagicDevice]) {
        for device in devices where device.isConnected {
            guard disconnectNotifications[device.id] == nil,
                let btDevice = IOBluetoothDevice(addressString: device.id)
            else { continue }
            disconnectNotifications[device.id] = btDevice.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDidDisconnect(_:device:)))
        }
    }

    @objc private func deviceDidConnect(
        _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
    ) {
        guard isMagicDevice(device) else { return }
        let address = device.addressString ?? ""
        if !address.isEmpty {
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDidDisconnect(_:device:)))
        }
        onDeviceStateChanged?()
    }

    @objc private func deviceDidDisconnect(
        _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
    ) {
        if let address = device.addressString {
            disconnectNotifications.removeValue(forKey: address)
        }
        onDeviceStateChanged?()
    }

    func scanForMagicDevices(completion: @escaping ([MagicDevice]) -> Void) {
        btQueue.async {
            let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
                .filter { self.isMagicDevice($0) }
                .map { btDevice -> MagicDevice in
                    MagicDevice(
                        id: btDevice.addressString,
                        name: btDevice.name ?? btDevice.nameOrAddress ?? "Magic Device",
                        isConnected: btDevice.isConnected()
                    )
                }
            DispatchQueue.main.async { completion(devices) }
        }
    }

    func connect(device: MagicDevice, completion: @escaping (ConnectError?) -> Void) {
        btQueue.async {
            let error = self.connectSync(address: device.id)
            DispatchQueue.main.async { completion(error) }
        }
    }

    func release(device: MagicDevice, completion: @escaping (Bool) -> Void) {
        btQueue.async {
            let success = self.unpair(device.id)
            DispatchQueue.main.async { completion(success) }
        }
    }

    func releaseAll(devices: [MagicDevice], completion: @escaping (Bool) -> Void) {
        btQueue.async {
            let success = devices.allSatisfy { self.unpair($0.id) }
            DispatchQueue.main.async { completion(success) }
        }
    }

    func connectAll(devices: [MagicDevice], completion: @escaping (ConnectError?) -> Void) {
        btQueue.async {
            var firstError: ConnectError?
            for device in devices {
                let error = self.connectSync(address: device.id)
                if error != nil && firstError == nil { firstError = error }
            }
            DispatchQueue.main.async { completion(firstError) }
        }
    }

    private func connectSync(address: String) -> ConnectError? {
        guard let device = IOBluetoothDevice(addressString: address) else {
            return .connectFailed
        }

        // After a remote `remove`, the device resets its pairing and Mac B sees
        // isPaired() as false. Route through IOBluetoothDevicePair so our delegate
        // auto-confirms the SSP request before macOS can show the system dialog.
        // If still paired (device was just disconnected), openConnection() directly.
        if device.isPaired() {
            let result = device.openConnection()
            return result == kIOReturnSuccess ? nil : .connectFailed
        }

        guard pairWithDeviceSync(device) else { return .pairFailed }
        return device.openConnection() == kIOReturnSuccess ? nil : .connectFailed
    }

    private func pairWithDeviceSync(_ device: IOBluetoothDevice) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var succeeded = false

        DispatchQueue.main.async {
            guard let pairer = IOBluetoothDevicePair(device: device) else {
                semaphore.signal()
                return
            }
            let delegate = PairDelegate { result in
                succeeded = result
                semaphore.signal()
            }
            pairer.delegate = delegate
            // Retain delegate for the pairing lifetime; IOBluetoothDevicePair holds it weakly
            objc_setAssociatedObject(pairer, "pairDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            pairer.start()
        }

        return semaphore.wait(timeout: .now() + 10) == .success && succeeded
    }

    private func unpair(_ address: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        let sel = NSSelectorFromString("remove")
        guard device.responds(to: sel) else { return false }
        device.perform(sel)
        return true
    }

    private func isMagicDevice(_ device: IOBluetoothDevice) -> Bool {
        isMagicDeviceName(device.name ?? device.nameOrAddress ?? "")
    }

    func isMagicDeviceName(_ name: String) -> Bool {
        name.contains("Magic Mouse")
            || name.contains("Magic Keyboard")
            || name.contains("Magic Trackpad")
    }
}

private class PairDelegate: NSObject, IOBluetoothDevicePairDelegate {
    private let onFinished: (Bool) -> Void

    init(onFinished: @escaping (Bool) -> Void) {
        self.onFinished = onFinished
        super.init()
    }

    func devicePairingUserConfirmationRequest(
        _ sender: Any!, numericValue: BluetoothNumericValue
    ) {
        // Auto-confirm SSP numeric comparison — this is what suppresses the system dialog
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        // Magic devices don't use PINs; reply with empty code as a safety fallback
        var pin = BluetoothPINCode()
        (sender as? IOBluetoothDevicePair)?.replyPINCode(0, pinCode: &pin)
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        onFinished(error == kIOReturnSuccess)
    }
}
