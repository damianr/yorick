import SwiftUI

/// One capture action, capsule-styled — the same button on the HUD card and
/// the in-app list rows.
struct CardActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(.white.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The one capture presentation, shared by the HUD card and the saved list:
/// the machine's reading (marked by waveform + italics), the raw words, and
/// the evidence COLLAPSED behind a click — simplest first, enrichment on
/// request. Surfaces keep their own chrome (headers, actions, backgrounds);
/// the content reads identically everywhere.
struct CaptureCardBody: View {
    let transcript: String
    let readback: String?
    let context: CaptureContext?
    /// The HUD card clamps long transcripts; the list shows everything.
    var transcriptLineLimit: Int?
    /// List rows copy on click; selection still works via drag.
    var onTranscriptTap: (() -> Void)?

    @State private var evidenceExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let readback, !readback.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "waveform")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(readback)
                        .font(.system(size: 10.5))
                        .italic()
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                }
            }

            transcriptText

            if let context, !context.facts.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { evidenceExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: evidenceExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                        Text("context · \(context.facts.count)")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if evidenceExpanded {
                    let chips = Self.chips(for: context)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(chips.indices, id: \.self) { index in
                            let chip = chips[index]
                            HStack(spacing: 5) {
                                Image(systemName: chip.icon)
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .frame(width: 10)
                                Text(chip.text)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptText: some View {
        let text = Text(transcript)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(transcriptLineLimit)
            .fixedSize(horizontal: false, vertical: true)
        if let onTranscriptTap {
            text
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Selectable text swallows plain clicks — the simultaneous
                // recognizer restores click-to-copy while a DRAG still selects.
                .simultaneousGesture(TapGesture().onEnded { onTranscriptTap() })
        } else {
            text
        }
    }

    /// One compact line per fact kind — except pointing, which is a SWEEP:
    /// up to three pointed items in order, plus a "+n" tail.
    static func chips(for context: CaptureContext) -> [(icon: String, text: String)] {
        var chips: [(String, String)] = []
        var seen = Set<String>()
        var pointedShown = 0
        let pointedTotal = context.facts.filter { $0.kind == "pointedElement" }.count
        for fact in context.facts {
            switch fact.kind {
            case "pointedElement":
                guard pointedShown < 3 else { continue }
                pointedShown += 1
                let role = fact.detail.map { " (\($0))" } ?? ""
                chips.append(("cursorarrow.rays", "\(fact.value.prefix(80))\(role)"))
            case "pageURL" where !seen.contains(fact.kind):
                seen.insert(fact.kind)
                let display = URL(string: fact.value).map { ($0.host ?? "") + $0.path } ?? fact.value
                chips.append(("link", display))
            case "document" where !seen.contains(fact.kind):
                // Chrome reports AXDocument = the page URL; same dedupe rule
                // as the export renderer, so card and export agree.
                guard !context.facts.contains(where: { $0.kind == "pageURL" && $0.value == fact.value }) else { continue }
                seen.insert(fact.kind)
                chips.append(("doc.text", (fact.value as NSString).lastPathComponent))
            case "selection" where !seen.contains(fact.kind):
                seen.insert(fact.kind)
                chips.append(("text.quote", "“\(fact.value.prefix(80))”"))
            default:
                continue
            }
        }
        if pointedTotal > pointedShown {
            chips.append(("cursorarrow.rays", "+\(pointedTotal - pointedShown) more pointed at"))
        }
        return chips
    }
}
