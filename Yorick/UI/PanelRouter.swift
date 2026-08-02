import Foundation
import SwiftUI

/// Where the panel is. Stream is home; settings and a capture's detail are
/// pushes off it, and back always means the same thing.
///
/// This replaces a `showingSettings` boolean held as view `@State`, which had
/// two problems beyond being one destination short. It survived the panel
/// closing, so opening the panel could land you on whatever page you left —
/// field-reported: clicking a capture card opened Settings. And it lived
/// inside the panel's view, so nothing outside could say where to go. A
/// shared route fixes both by construction: the card doesn't open the panel
/// and hope, it navigates.
@MainActor
final class PanelRouter: ObservableObject {
    static let shared = PanelRouter()

    enum Route: Equatable {
        case stream
        case detail(UUID)
        case settings
    }

    @Published private(set) var route: Route = .stream

    var isHome: Bool { route == .stream }

    private init() {}

    func push(_ route: Route) {
        self.route = route
    }

    /// Home. Deliberately not a stack — the panel is two levels deep at most,
    /// and a conduit with navigation history would be a workspace.
    func popToStream() {
        route = .stream
    }

    /// Open a capture's detail, bringing the panel up if it isn't showing.
    /// The one entry point the HUD card uses, so "click the card" lands on
    /// the capture you clicked rather than wherever the panel was last.
    func openDetail(_ captureID: UUID) {
        route = .detail(captureID)
        NotificationCenter.default.post(name: .showMenuBarPanel, object: nil)
    }

    /// Called when a capture disappears underneath its own detail page —
    /// deleted here, or pruned by the ephemerality clock while open.
    func popIfShowing(_ captureID: UUID) {
        if route == .detail(captureID) { popToStream() }
    }
}
