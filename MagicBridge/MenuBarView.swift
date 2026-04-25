import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    var onConnect: (MagicDevice) -> Void
    var onRelease: (MagicDevice) -> Void
    var onSwitchAll: () -> Void
    var onReleaseAll: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            otherMacsSection
            Divider()
            deviceRows
            Divider()
            switchAllButton
            releaseAllButton
            Divider()
            quitButton
        }
        .padding(16)
        .frame(width: 300)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("MagicBridge")
                .font(.system(size: 15, weight: .bold))
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var otherMacsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Other MacBooks")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            if appState.peers.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(Color.gray).frame(width: 8, height: 8)
                    Text("No other MacBooks found")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(appState.peers) { peer in
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text(peer.name)
                            .font(.system(size: 12))
                    }
                }
            }
        }
    }

    private var deviceRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Devices")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            if appState.devices.isEmpty {
                Text("No Magic devices found")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(appState.devices) { device in
                    DeviceRow(
                        device: device,
                        isEnabled: appState.isEnabled(device),
                        onToggle: { appState.toggleEnabled(device) },
                        onConnect: { onConnect(device) },
                        onRelease: { onRelease(device) }
                    )
                }
            }
        }
    }

    private var switchAllButton: some View {
        Button(action: onSwitchAll) {
            HStack {
                if appState.isSwitching {
                    ProgressView().scaleEffect(0.7).progressViewStyle(.circular)
                }
                Text(appState.isSwitching ? "Switching..." : "Switch selected to this Mac")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            appState.isSwitching
                || appState.enabledDevices.isEmpty
                || appState.enabledDevices.allSatisfy { $0.isConnected })
    }

    private var releaseAllButton: some View {
        Button(action: onReleaseAll) {
            Text("Release all selected")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(
            appState.isSwitching
                || appState.enabledDevices.isEmpty
                || appState.enabledDevices.allSatisfy { !$0.isConnected })
    }

    private var quitButton: some View {
        Button("Quit MagicBridge", action: onQuit)
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device: MagicDevice
    let isEnabled: Bool
    var onToggle: () -> Void
    var onConnect: () -> Void
    var onRelease: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isEnabled ? .accentColor : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)

            Circle()
                .fill(device.isConnected ? Color.green : Color.gray)
                .frame(width: 7, height: 7)

            Text(device.name)
                .font(.system(size: 12))
                .foregroundColor(isEnabled ? .primary : .secondary)
                .lineLimit(1)
                .help(device.name)

            Spacer()

            if isEnabled {
                if device.isConnected {
                    Button("Release", action: onRelease)
                        .buttonStyle(.bordered)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .controlSize(.small)
                } else {
                    Button("Connect", action: onConnect)
                        .buttonStyle(.bordered)
                        .font(.system(size: 11))
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
