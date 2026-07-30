import KeyboardShortcuts
import SwiftUI

/// The panel's face: the same capture cards the app window shows, in a
/// roomy ink surface hanging off the menu bar. A conduit's control room —
/// status up top, the stream of things waiting to leave, and the exits on
/// every card. Nothing here invites dwelling; everything invites emptying.
struct MenuBarPanelView: View {
    unowned let controller: MenuBarPanelController
    @Environment(SessionManager.self) private var session
    @State private var pinned = false

    private var shortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .toggleSession).map(String.init(describing:)) ?? "⌥Space"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            statusLine
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 14)
            captureList
        }
        .frame(width: 420, height: 560)
        // The pill's glass recipe, pinned (PillGlass): same frost + black
        // 0.85 background, same bone rim 0.26→0.08 at 1pt — the panel and
        // the pills read as one material. Drop shadow stays the system
        // panel shadow (an NSPanel already casts one; doubling it up with
        // the pill's SwiftUI shadows read as a smudge).
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.85))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Theme.bone.opacity(0.26), Theme.bone.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 15, height: 15)
                .foregroundStyle(Theme.bone)
            Text("yorick")
                .font(Theme.mono(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                pinned.toggle()
                controller.setPinned(pinned)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pinned ? Theme.bone : Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pinned ? "Unpin — close when clicking away" : "Pin — stay open while you work")
            Menu {
                Button("Open Yorick") { openMainWindow() }
                Button("Settings…") { openSettings() }
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .checkForUpdates, object: nil)
                }
                Divider()
                Button("Quit Yorick") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusLine: some View {
        Group {
            switch session.state {
            case .idle:
                Text("Ready — hold \(shortcutLabel) anywhere")
                    .foregroundStyle(Theme.textTertiary)
            case .recording:
                HStack(spacing: 6) {
                    Circle().fill(Theme.bone).frame(width: 6, height: 6)
                    Text("Listening — \(session.formattedDuration)")
                        .monospacedDigit()
                        .foregroundStyle(Theme.bone)
                }
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(session.cleanupRunning ? "Cleaning up…" : "Transcribing…")
                        .foregroundStyle(Theme.textSecondary)
                }
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.accentAmber)
                    .lineLimit(2)
            }
        }
        .font(Theme.mono(10.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Captures

    private var groupedCaptures: [(label: String, captures: [Capture])] {
        let sorted = session.captureStore.captures.sorted { $0.timestamp > $1.timestamp }
        var out: [(String, [Capture])] = []
        for capture in sorted {
            let label = DayLabel.string(for: capture.timestamp)
            if out.last?.0 == label {
                out[out.count - 1].1.append(capture)
            } else {
                out.append((label, [capture]))
            }
        }
        return out
    }

    @ViewBuilder
    private var captureList: some View {
        if session.captureStore.captures.isEmpty {
            VStack(spacing: 8) {
                Image("MenuBarIcon")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Theme.textTertiary)
                Text("Nothing waiting.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textSecondary)
                Text("Hold \(shortcutLabel) and talk — anywhere.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                    ForEach(groupedCaptures, id: \.label) { group in
                        Text(group.label)
                            .font(Theme.mono(9, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 6)
                        ForEach(group.captures) { capture in
                            CaptureRow(
                                capture: capture,
                                captureStore: session.captureStore,
                                timeLabel: "\(DayLabel.string(for: capture.timestamp).lowercased()) \(DayLabel.timeFormatter.string(from: capture.timestamp)) · \(capture.appName)"
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .environment(session)
        }
    }

    // MARK: - Actions

    private func openMainWindow() {
        controller.hide()
        NSApp.activate(ignoringOtherApps: true)
        // Reuse the existing window — openWindow(id:) spawns duplicates
        // (same behaviour as AppDelegate.applicationShouldHandleReopen).
        if let existing = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
            existing.makeKeyAndOrderFront(nil)
        }
    }

    private func openSettings() {
        controller.hide()
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
            existing.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }
}
