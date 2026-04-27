import CoreBluetooth
import Foundation
import IOBluetooth

enum ConnectError {
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
            guard let btDevice = IOBluetoothDevice(addressString: device.id) else {
                DispatchQueue.main.async { completion(.connectFailed) }
                return
            }
            let result = btDevice.openConnection()
            DispatchQueue.main.async {
                completion(result == kIOReturnSuccess ? nil : .connectFailed)
            }
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
                guard let btDevice = IOBluetoothDevice(addressString: device.id) else {
                    if firstError == nil { firstError = .connectFailed }
                    continue
                }
                let result = btDevice.openConnection()
                if result != kIOReturnSuccess && firstError == nil { firstError = .connectFailed }
                Thread.sleep(forTimeInterval: 1.0)
            }
            DispatchQueue.main.async { completion(firstError) }
        }
    }

    // MARK: - Private

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
