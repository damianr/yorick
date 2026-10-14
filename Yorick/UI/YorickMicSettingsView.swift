import SwiftUI
import WebKit

struct YorickMicSettingsView: View {
    @Bindable var mic: YorickMicController
    @State private var preview = "waiting"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: mic.attached ? "cable.connector" : "cable.connector.slash")
                Text(mic.status).fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.mono(10))
            .foregroundStyle(mic.controlsReady ? Theme.success : Theme.textSecondary)
            if mic.showEyeControls {
                Picker("Eye style", selection: $mic.settings.style) {
                    ForEach(YorickEyeStyle.allCases) { style in Text(style.title).tag(style) }
                }
                Text(mic.settings.style.detail)
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.textTertiary)
                YorickEyePreview(settings: mic.settings, preview: preview, reducedMotion: reduceMotion)
                    .frame(height: 150)
                    .accessibilityLabel("\(mic.settings.style.title) eyes. Simulated \(preview).")
                Picker("Preview state", selection: $preview) {
                    Text("Waiting").tag("waiting")
                    Text("Listening").tag("listening")
                    Text("Speech").tag("audio")
                }.pickerStyle(.segmented)
                Text("Preview only — does not record or activate the microphone. The small displays approximate these designs.")
                    .font(Theme.mono(9)).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                setting("Brightness", value: $mic.settings.brightness, range: 10...100)
                setting("Eye size", value: $mic.settings.size, range: 60...115)
                setting("Motion", value: $mic.settings.motion, range: 0...160)
                Toggle("Respond to my voice", isOn: $mic.settings.reactive)
                    .font(Theme.mono(10)).toggleStyle(.switch).controlSize(.small)
                if mic.settings.reactive {
                    setting("Voice response", value: $mic.settings.sensitivity, range: 25...200)
                }
                Text(mic.controlsReady
                     ? (mic.applied ? "Applied to the eyes. Listening follows dictation through the Yorick microphone; voice response follows the input level. Preferences stay on this Mac." : "Saving to this Mac and syncing with the eyes…")
                     : (mic.needsInputSelection
                        ? "Preview only. Choose the Yorick input above to apply these settings to the skull."
                        : "Saved on this Mac. These settings have not reached the skull yet. Check its power and connection, then retry."))
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Reset eye settings") { mic.settings = YorickEyeSettings() }
                    Spacer()
                    if !mic.controlsReady { Button("Retry connection") { mic.retry() } }
                }.font(Theme.mono(9.5))
            }
        }
        .padding(.vertical, 8)
    }

    private func setting(_ title: String, value: Binding<Int>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title); Spacer(); Text("\(value.wrappedValue)%").monospacedDigit()
            }.font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }), in: range, step: 5)
                .accessibilityLabel(title)
        }
    }
}

private struct YorickEyePreview: NSViewRepresentable {
    var settings: YorickEyeSettings
    var preview: String
    var reducedMotion: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        if let url = Bundle.main.url(forResource: "YorickEyePreview", withExtension: "html") {
            let resolved = url.resolvingSymlinksInPath()
            web.loadFileURL(resolved, allowingReadAccessTo: resolved.deletingLastPathComponent())
        }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        let s = settings.normalized()
        let payload: [String: Any] = ["style": s.style.rawValue, "brightness": s.brightness,
                                    "size": s.size, "motion": s.motion, "preview": preview,
                                    "reducedMotion": reducedMotion || s.motion == 0, "reactive": s.reactive, "sensitivity": s.sensitivity]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        context.coordinator.script = "window.updateEyes(\(json));"
        if !web.isLoading { context.coordinator.apply(web) }
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { web.stopLoading(); web.navigationDelegate = nil }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var script = ""
        func apply(_ web: WKWebView) { web.evaluateJavaScript(script, completionHandler: nil) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { apply(webView) }
    }
}
