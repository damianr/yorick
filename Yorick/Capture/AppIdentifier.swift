import AppKit

/// Identifies the app/site context from accessibility data and window titles.
/// For native apps, returns the app name. For browsers, extracts the website
/// name from the window title (e.g. "InfuseFlow" from "InfuseFlow - Google Chrome").
enum AppIdentifier {
    private static let browsers: Set<String> = [
        "Google Chrome", "Safari", "Firefox", "Arc",
        "Brave Browser", "Microsoft Edge", "Opera"
    ]

    /// Determine the best app/site name from a window title and app name.
    /// For browsers, extracts the site from the window title.
    /// For native apps, returns the app name as-is.
    static func identify(appName: String, windowTitle: String) -> (name: String, isBrowser: Bool) {
        guard browsers.contains(appName) else {
            return (appName, false)
        }

        // Browser window titles are typically "Page Title - Browser Name"
        // or "Page Title — Browser Name"
        if let siteName = extractSiteFromWindowTitle(windowTitle, browserName: appName) {
            return (siteName, true)
        }

        // If the window title doesn't contain the browser name at all,
        // it's likely already the site/app name (e.g. "InfuseFlow" from
        // a PWA or simplified Chrome title)
        let trimmed = windowTitle.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != appName {
            return (trimmed, true)
        }

        return (appName, true)
    }

    /// Extract a meaningful site/page name from a browser window title.
    /// "InfuseFlow | Calendar - Google Chrome" → "InfuseFlow"
    /// "GitHub - yorick: Local capture tool - Google Chrome" → "GitHub"
    private static func extractSiteFromWindowTitle(_ title: String, browserName: String) -> String? {
        guard !title.isEmpty else { return nil }

        // Remove the browser name suffix
        var cleaned = title
        for separator in [" - \(browserName)", " — \(browserName)", " – \(browserName)"] {
            if let range = cleaned.range(of: separator, options: .backwards) {
                cleaned = String(cleaned[..<range.lowerBound])
                break
            }
        }

        guard cleaned != title else { return nil } // No browser suffix found

        // Take the first segment before common separators as the site name
        // "InfuseFlow | Calendar" → "InfuseFlow"
        // "GitHub - yorick" → "GitHub"
        for separator in [" | ", " - ", " — ", " – ", " · ", " :: "] {
            if let range = cleaned.range(of: separator) {
                let first = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !first.isEmpty { return first }
            }
        }

        let result = cleaned.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
}
