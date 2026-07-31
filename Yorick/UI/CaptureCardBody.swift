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
/// the words, exactly as spoken. Surfaces keep their own chrome (headers,
/// actions, backgrounds); the content reads identically everywhere.
struct CaptureCardBody: View {
    let transcript: String
    /// The HUD card clamps long transcripts; the list shows everything.
    var transcriptLineLimit: Int?
    /// List rows copy on click; selection still works via drag.
    var onTranscriptTap: (() -> Void)?

    var body: some View {
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
}
