import SwiftUI

struct MenuBarView: View {
    @Environment(SessionManager.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            statusSection
            Divider()
            bottomSection
        }
        .padding()
        .frame(width: 320)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        switch session.state {
        case .idle:
            Label("Ready — hold ⌥` to capture", systemImage: "mic.circle")
                .foregroundStyle(.secondary)
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
            }
        case .recording:
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Recording — \(session.formattedDuration)")
                    .monospacedDigit()
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .font(.caption)
        }
    }

    // MARK: - Bottom

    private var bottomSection: some View {
        VStack(spacing: 6) {
            HStack {
                Button("Open Yorick") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            HStack {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .checkForUpdates, object: nil)
                }
                .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.caption)
    }
}
