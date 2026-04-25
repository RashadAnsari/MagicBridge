import Foundation

class BluetoothManager {
    private let btQueue = DispatchQueue(label: "com.magicbridge.bluetooth", qos: .userInitiated)

    private var blueutilURL: URL {
        #if arch(arm64)
            let name = "blueutil_arm64"
        #else
            let name = "blueutil_amd64"
        #endif
        if let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url
        }
        for path in ["/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        fatalError("blueutil not found")
    }

    // MARK: - blueutil runner

    @discardableResult
    private func run(_ args: [String]) -> (output: String, success: Bool) {
        let proc = Process()
        proc.executableURL = blueutilURL
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            print("[BT] Error: \(error)")
            return ("", false)
        }
        let out =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (out, proc.terminationStatus == 0)
    }

    // MARK: - Public API

    func scanForMagicDevices(completion: @escaping ([MagicDevice]) -> Void) {
        btQueue.async {
            let (output, ok) = self.run(["--paired"])
            guard ok else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let devices = output.components(separatedBy: "\n").compactMap { self.parseLine($0) }
            DispatchQueue.main.async { completion(devices) }
        }
    }

    // Release: unpair locally, but keep the device in app state so it can be claimed again later.
    func release(device: MagicDevice, completion: @escaping (Bool) -> Void) {
        btQueue.async {
            let (_, ok) = self.run(["--unpair", device.id])
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // Claim: pair then connect — exact port of MonkeySwitcher's main.command
    func connect(device: MagicDevice, completion: @escaping (Bool) -> Void) {
        btQueue.async {
            self.run(["--pair", device.id])
            Thread.sleep(forTimeInterval: 1.0)
            let (_, ok) = self.run(["--connect", device.id])
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func releaseAll(devices: [MagicDevice], completion: @escaping (Bool) -> Void) {
        btQueue.async {
            var allSucceeded = true

            for d in devices {
                let (_, ok) = self.run(["--unpair", d.id])
                allSucceeded = allSucceeded && ok
            }

            DispatchQueue.main.async { completion(allSucceeded) }
        }
    }

    func connectAll(devices: [MagicDevice], completion: @escaping () -> Void) {
        btQueue.async {
            for d in devices {
                self.run(["--pair", d.id])
                Thread.sleep(forTimeInterval: 1.0)
                self.run(["--connect", d.id])
            }
            DispatchQueue.main.async { completion() }
        }
    }

    func isConnected(device: MagicDevice) -> Bool {
        let (out, _) = run(["--is-connected", device.id])
        return out == "1"
    }

    // MARK: - Parser
    // Format: address: xx-xx-xx-xx-xx-xx, connected (...) | not connected, ..., name: "Device Name", ...

    private func parseLine(_ line: String) -> MagicDevice? {
        guard
            line.contains("Magic Mouse")
                || line.contains("Magic Keyboard")
                || line.contains("Magic Trackpad")
        else { return nil }

        guard
            let addrRange = line.range(
                of: #"([0-9a-f]{2}-){5}[0-9a-f]{2}"#, options: .regularExpression)
        else {
            return nil
        }
        let address = String(line[addrRange])

        var name = "Magic Device"
        if let nameRange = line.range(of: #"name: "([^"]+)""#, options: .regularExpression) {
            name = String(line[nameRange])
                .replacingOccurrences(of: "name: \"", with: "")
                .replacingOccurrences(of: "\"", with: "")
        }

        let isConnected = !line.contains("not connected") && line.contains("connected")
        return MagicDevice(id: address, name: name, isConnected: isConnected)
    }
}
