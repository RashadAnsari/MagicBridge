import AppKit
import SwiftUI

@main
struct MagicBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var refreshTimer: Timer?

    let appState = AppState()
    let bluetooth = BluetoothManager()
    let network = NetworkManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupNetworkCallbacks()
        network.start()
        bluetooth.requestPermission()
        refreshDevices()
        startRefreshTimer()
        promptLaunchAtLoginIfNeeded()
    }

    private func promptLaunchAtLoginIfNeeded() {
        let key = "launchAtLoginPrompted"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = "Launch MagicBridge at Login?"
        alert.informativeText =
            "MagicBridge can start automatically when you log in so your devices are always ready."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            appState.setLaunchAtLogin(true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        network.stop()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = icon()
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func icon() -> NSImage? {
        if let img = NSImage(named: NSImage.Name("AppIcon")) {
            img.isTemplate = true
            img.size = NSSize(width: 16, height: 16)
            return img
        }
        return nil
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                onConnect: { [weak self] device in self?.handleConnect(device) },
                onRelease: { [weak self] device in self?.handleRelease(device) },
                onSwitchAll: { [weak self] in self?.handleSwitchAll() },
                onReleaseAll: { [weak self] in self?.handleReleaseAll() },
                onQuit: { NSApp.terminate(nil) }
            )
            .environmentObject(appState)
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Network callbacks

    private func setupNetworkCallbacks() {
        network.appState = appState

        network.onReceiveRelease = { [weak self] deviceIDs, acknowledge in
            guard let self else { return }
            self.appState.statusMessage = "Releasing devices for another MacBook..."
            let toRelease = self.appState.enabledDevices.filter { deviceIDs.contains($0.id) }
            self.bluetooth.releaseAll(devices: toRelease) { success in
                self.appState.statusMessage =
                    success ? "Devices released" : "Some devices could not be released"
                self.refreshDevices()
                acknowledge()
            }
        }
    }

    // MARK: - Actions

    private func handleConnect(_ device: MagicDevice) {
        appState.isSwitching = true
        appState.statusMessage = "Connecting \(device.name)..."

        let finish = { [weak self] (error: ConnectError?) in
            guard let self else { return }
            self.appState.isSwitching = false
            if error != nil {
                self.appState.statusMessage = "Failed to connect. Try again."
            } else {
                self.refreshDevices()
            }
        }

        if appState.peerConnected {
            network.sendRelease(devices: [device]) { [weak self] confirmed in
                guard let self else { return }
                if !confirmed {
                    self.appState.statusMessage =
                        "Some MacBooks did not respond — connecting anyway..."
                }
                self.bluetooth.connect(device: device, completion: finish)
            }
        } else {
            bluetooth.connect(device: device, completion: finish)
        }
    }

    private func handleRelease(_ device: MagicDevice) {
        appState.statusMessage = "Releasing \(device.name)..."
        bluetooth.release(device: device) { [weak self] _ in
            self?.refreshDevices()
        }
    }

    private func handleSwitchAll() {
        let targets = appState.enabledDevices
        guard !targets.isEmpty else { return }

        appState.isSwitching = true
        appState.statusMessage = "Switching..."

        let finish = { [weak self] (error: ConnectError?) in
            guard let self else { return }
            self.appState.isSwitching = false
            if error != nil {
                self.appState.statusMessage = "Failed to connect. Try again."
            } else {
                self.refreshDevices()
            }
        }

        if appState.peerConnected {
            network.sendRelease(devices: targets) { [weak self] confirmed in
                guard let self else { return }
                if !confirmed {
                    self.appState.statusMessage =
                        "Some MacBooks did not respond — connecting anyway..."
                }
                self.bluetooth.connectAll(devices: targets, completion: finish)
            }
        } else {
            bluetooth.connectAll(devices: targets, completion: finish)
        }
    }

    private func handleReleaseAll() {
        let targets = appState.enabledDevices.filter { $0.isConnected }
        guard !targets.isEmpty else { return }

        appState.isSwitching = true
        appState.statusMessage = "Releasing selected devices..."

        bluetooth.releaseAll(devices: targets) { [weak self] success in
            guard let self else { return }
            self.appState.isSwitching = false
            self.appState.statusMessage =
                success ? "Selected devices released" : "Some devices could not be released"
            self.refreshDevices()
        }
    }

    // MARK: - Device refresh

    private func refreshDevices() {
        bluetooth.scanForMagicDevices { [weak self] devices in
            guard let self else { return }
            self.appState.setScannedDevices(devices)
            let anyHere = self.appState.devices.contains { $0.isConnected }
            self.appState.statusMessage =
                anyHere ? "Devices on this MacBook" : "Devices on another MacBook"
            self.statusItem.button?.image = self.icon()
        }
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshDevices()
        }
    }
}
