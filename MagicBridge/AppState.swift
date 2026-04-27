import Foundation
import ServiceManagement

struct MagicDevice: Identifiable, Equatable {
    let id: String
    let name: String
    var isConnected: Bool
}

private struct StoredMagicDevice: Codable {
    let id: String
    let name: String
}

struct Peer: Identifiable, Equatable {
    let id: String
    let name: String
}

class AppState: ObservableObject {
    private let enabledDevicesKey = "enabled_device_ids"
    private let claimedDevicesKey = "claimed_devices"

    @Published var devices: [MagicDevice] = []
    @Published var peers: [Peer] = []
    @Published var statusMessage: String = "Scanning..."
    @Published var isSwitching: Bool = false

    var peerConnected: Bool { !peers.isEmpty }

    @Published var enabledDeviceIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(enabledDeviceIDs), forKey: enabledDevicesKey)
        }
    }

    private var claimedDevicesByID: [String: MagicDevice] = [:] {
        didSet { saveClaimedDevices() }
    }

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: enabledDevicesKey) ?? []
        enabledDeviceIDs = Set(saved)
        claimedDevicesByID = loadClaimedDevices()
        devices = claimedDevicesByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var enabledDevices: [MagicDevice] {
        devices.filter { enabledDeviceIDs.contains($0.id) }
    }

    func isEnabled(_ device: MagicDevice) -> Bool {
        enabledDeviceIDs.contains(device.id)
    }

    func toggleEnabled(_ device: MagicDevice) {
        if enabledDeviceIDs.contains(device.id) {
            enabledDeviceIDs.remove(device.id)
            claimedDevicesByID.removeValue(forKey: device.id)
        } else {
            enabledDeviceIDs.insert(device.id)
            claimedDevicesByID[device.id] = device
        }

        updateVisibleDevices(scannedDevices: devices)
    }

    func setScannedDevices(_ scannedDevices: [MagicDevice]) {
        for device in scannedDevices where enabledDeviceIDs.contains(device.id) {
            claimedDevicesByID[device.id] = device
        }

        updateVisibleDevices(scannedDevices: scannedDevices)
    }

    private func updateVisibleDevices(scannedDevices: [MagicDevice]) {
        var merged = Dictionary(uniqueKeysWithValues: scannedDevices.map { ($0.id, $0) })

        for (id, device) in claimedDevicesByID where merged[id] == nil {
            merged[id] = MagicDevice(id: device.id, name: device.name, isConnected: false)
        }

        devices = merged.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func loadClaimedDevices() -> [String: MagicDevice] {
        guard let data = UserDefaults.standard.data(forKey: claimedDevicesKey),
            let storedDevices = try? JSONDecoder().decode([StoredMagicDevice].self, from: data)
        else {
            return [:]
        }

        return Dictionary(
            uniqueKeysWithValues: storedDevices.map {
                ($0.id, MagicDevice(id: $0.id, name: $0.name, isConnected: false))
            })
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            objectWillChange.send()
        } catch {
            // ignore registration errors silently
        }
    }

    private func saveClaimedDevices() {
        let storedDevices = claimedDevicesByID.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { StoredMagicDevice(id: $0.id, name: $0.name) }

        guard let data = try? JSONEncoder().encode(storedDevices) else { return }
        UserDefaults.standard.set(data, forKey: claimedDevicesKey)
    }
}
