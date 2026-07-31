import Foundation

/// The admin-only diagnostics gate, in one place:
/// `defaults write com.heyyorick.Yorick adminMode -bool true`
enum AdminMode {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "adminMode") }
}
