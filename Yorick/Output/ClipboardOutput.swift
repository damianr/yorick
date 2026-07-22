import AppKit

enum ClipboardOutput {
    /// Copy plain text to clipboard.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copy just an image to clipboard.
    static func copy(image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// Copy text + image as a rich HTML bundle for Electron apps like Claude Mac.
    ///
    /// Strategy: put HTML on the clipboard with the image inline as base64 data URL,
    /// plus plain text and PNG data as fallbacks. Electron-based apps (including
    /// Claude Mac) often handle rich HTML paste and will render the image inline
    /// alongside the text. Text-only apps fall back to the plain text type.
    static func copyBundle(text: String, images: [NSImage]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // 1. Plain text — universal fallback
        pasteboard.setString(text, forType: .string)

        guard let image = images.first,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            print("[Clipboard] Bundle: \(text.count) chars, no image")
            return
        }

        // 2. PNG image data — for apps that accept image paste
        pasteboard.setData(pngData, forType: .png)

        // 3. HTML with inline base64 image — for Electron/web apps that handle rich paste
        let base64 = pngData.base64EncodedString()
        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let html = """
        <div>\(escapedText)<br><br><img src="data:image/png;base64,\(base64)"></div>
        """
        pasteboard.setString(html, forType: .html)

        // 4. RTF with embedded image — for native macOS rich text apps (Notes, TextEdit)
        if let rtfData = makeRTF(text: text, pngData: pngData) {
            pasteboard.setData(rtfData, forType: .rtf)
        }

        print("[Clipboard] Bundle: \(text.count) chars + \(pngData.count / 1024)KB PNG + HTML + RTF")
    }

    /// Build an RTF document with the image embedded inline after the text.
    private static func makeRTF(text: String, pngData: Data) -> Data? {
        // Build an NSAttributedString with text + newline + inline image attachment
        let attachment = NSTextAttachment()
        attachment.image = NSImage(data: pngData)

        let combined = NSMutableAttributedString(string: text + "\n\n")
        combined.append(NSAttributedString(attachment: attachment))

        // Plain RTF, not RTFD: RTFD is a file-wrapper format and is malformed
        // when declared under the .rtf pasteboard type. The image still travels
        // via the PNG and HTML representations above.
        return try? combined.data(
            from: NSRange(location: 0, length: combined.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
}
