import SwiftUI

/// The stream — a log, not a queue. Everything you said outside a text field,
/// full raw text, newest first; the whole row is a copy button. Typed
/// dictations hide behind one quiet filter. Nothing to clear, nothing to
/// tend: items fade on their own clocks.
struct StreamView: View {
    @Environment(SessionManager.self) private var session
    @AppStorage("showDictations") private var showDictations = false

    private var visibleCaptures: [Capture] {
        session.captureStore.captures.filter { capture in
            // Legacy cleared items stay hidden until their fade finishes.
            if capture.state == .done { return false }
            if capture.kind == .dictation { return showDictations }
            return true
        }
    }

    private var typedCount: Int {
        session.captureStore.captures.filter { $0.kind == .dictation && $0.state != .done }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle().fill(Theme.borderSubtle).frame(height: 1)
                .padding(.horizontal, 20)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if visibleCaptures.isEmpty {
                        emptyState
                    } else {
                        rows
                        Text("items fade on their own — saved after 30 days, typed after 7")
                            .font(Theme.mono(8.5))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .frame(width: 15, height: 15)
                .foregroundStyle(Theme.accentPurple)
            Text("yorick")
                .font(Theme.mono(12, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Button(action: { showDictations.toggle() }) {
                Text(showDictations ? "HIDE TYPED" : (typedCount > 0 ? "SHOW TYPED · \(typedCount)" : "SHOW TYPED"))
                    .font(Theme.mono(9))
                    .tracking(0.8)
                    .foregroundStyle(showDictations ? .cyan : Theme.textTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        let items = visibleCaptures
        ForEach(Array(items.enumerated()), id: \.element.id) { index, capture in
            let day = Calendar.current.startOfDay(for: capture.timestamp)
            let prevDay = index > 0 ? Calendar.current.startOfDay(for: items[index - 1].timestamp) : nil
            if day != prevDay {
                Text(DayLabel.string(for: day))
                    .font(Theme.mono(8.5))
                    .tracking(1.4)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, index == 0 ? 8 : 16)
                    .padding(.bottom, 6)
            }
            CaptureRow(
                capture: capture,
                captureStore: session.captureStore,
                timeLabel: "\(DayLabel.string(for: capture.timestamp).lowercased()) \(DayLabel.timeFormatter.string(from: capture.timestamp)) · \(capture.appName)"
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Nothing saved")
                .font(Theme.mono(13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Anything you say without a text field focused shows up here.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }
}
