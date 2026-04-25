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
        refreshDevices()
        startRefreshTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        network.stop()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = icon(active: false)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func icon(active: Bool) -> NSImage? {
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

        // Peer asked us to release all devices
        network.onReceiveRelease = { [weak self] acknowledge in
            guard let self else { return }
            self.appState.statusMessage = "Releasing for other Mac..."
            self.bluetooth.releaseAll(devices: self.appState.enabledDevices) { success in
                self.appState.statusMessage =
                    success ? "Released" : "Some devices failed to release"
                self.refreshDevices()
                acknowledge()
            }
        }
    }

    // MARK: - Actions

    // Per-device connect button
    private func handleConnect(_ device: MagicDevice) {
        appState.isSwitching = true
        appState.statusMessage = "Connecting \(device.name)..."

        if appState.peerConnected {
            network.sendRelease { [weak self] in
                guard let self else { return }
                self.bluetooth.connect(device: device) { _ in
                    self.appState.isSwitching = false
                    self.refreshDevices()
                }
            }
        } else {
            bluetooth.connect(device: device) { [weak self] _ in
                guard let self else { return }
                self.appState.isSwitching = false
                self.refreshDevices()
            }
        }
    }

    // Per-device release button
    private func handleRelease(_ device: MagicDevice) {
        appState.statusMessage = "Releasing \(device.name)..."
        bluetooth.release(device: device) { [weak self] _ in
            self?.refreshDevices()
        }
    }

    // "Switch selected to this Mac" button
    private func handleSwitchAll() {
        let targets = appState.enabledDevices
        guard !targets.isEmpty else { return }

        appState.isSwitching = true
        appState.statusMessage = "Switching..."

        if appState.peerConnected {
            network.sendRelease { [weak self] in
                guard let self else { return }
                self.bluetooth.connectAll(devices: targets) {
                    self.appState.isSwitching = false
                    self.refreshDevices()
                }
            }
        } else {
            bluetooth.connectAll(devices: targets) { [weak self] in
                guard let self else { return }
                self.appState.isSwitching = false
                self.refreshDevices()
            }
        }
    }

    private func handleReleaseAll() {
        let targets = appState.enabledDevices.filter { $0.isConnected }
        guard !targets.isEmpty else { return }

        appState.isSwitching = true
        appState.statusMessage = "Releasing selected..."

        bluetooth.releaseAll(devices: targets) { [weak self] success in
            guard let self else { return }
            self.appState.isSwitching = false
            self.appState.statusMessage =
                success ? "Released selected" : "Some selected devices failed to release"
            self.refreshDevices()
        }
    }

    // MARK: - Device refresh

    private func refreshDevices() {
        bluetooth.scanForMagicDevices { [weak self] devices in
            guard let self else { return }
            self.appState.setScannedDevices(devices)
            let anyHere = self.appState.devices.contains { $0.isConnected }
            self.appState.statusMessage = anyHere ? "Devices on this Mac" : "Devices on other Mac"
            self.statusItem.button?.image = self.icon(active: anyHere)
        }
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshDevices()
        }
    }
}
