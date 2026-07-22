import Foundation

/// The app's Application Support root (`~/Library/Application Support/Yorick`),
/// created on first access. Home for captures, models, and routing corrections.
enum AppPaths {
    static let root: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Yorick", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
