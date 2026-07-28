import SceneKit
import SwiftUI

/// EXPERIMENT: the 3D skull that watches your cursor while a contextual
/// recording runs. It's the honest affordance for pointer-derived context —
/// the skull looks only while Yorick is actually reading what you point at
/// (recording, no field focused), and stops when the recording stops.
///
/// The model loads from Application Support (`skull.usdz`), NOT the repo or
/// bundle: the current export is a 32MB / 487k-triangle sculpt — fine for a
/// resident experiment, wrong to bake into a public repo's history. Absent
/// file = absent feature; the flat mark simply stays.
struct SkullGazeView: NSViewRepresentable {
    static let modelURL = AppPaths.root.appendingPathComponent("skull.usdz")

    /// The pill must appear at hotkey speed, and EVERY cost here is paid at
    /// launch, never at pill time: the 32MB parse happens off-main, then one
    /// persistent SCNView is created and GPU-warmed (geometry upload +
    /// shader compile, via SceneKit's prepare API). `isReady` turns true
    /// only after ALL of that — the pill mounts a fully warm view or shows
    /// the flat mark, and never blocks on either.
    @MainActor private static var sharedView: SCNView?
    @MainActor private static var warm = false
    @MainActor private static var preloadStarted = false

    /// True only when the skull can appear with ZERO pill-time cost.
    @MainActor static var isReady: Bool { warm && sharedView != nil }

    @MainActor
    static func preload() {
        guard !preloadStarted else { return }
        preloadStarted = true
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return }
        Task.detached(priority: .utility) {
            guard let scene = makeScene() else { return } // background parse
            await MainActor.run {
                let view = SCNView()
                view.backgroundColor = .clear
                view.antialiasingMode = .multisampling4X
                view.scene = scene
                view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
                sharedView = view
                // Upload geometry and compile shaders NOW, off the render
                // path — first mount must not pay for 487k triangles.
                view.prepare([scene.rootNode]) { _ in
                    Task { @MainActor in warm = true }
                }
            }
        }
    }

    func makeNSView(context: Context) -> SCNView {
        // The one warm view, reused across every mount — SwiftUI reparents
        // it; creating a fresh SCNView per mount would re-pay the Metal
        // setup at pill time. (isReady gates mounting, so the fallback
        // empty view exists only for type-safety.)
        let view = Self.sharedView ?? SCNView()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// Scene graph: gaze node (rotates) → model node (axis fix + centered
    /// pivot). The USDZ is authored Z-up; -90° about X puts the face on +Z,
    /// upright — verified by offscreen render. Pivot at the bounding-box
    /// center makes rotation read as looking around, not orbiting.
    nonisolated private static func makeScene() -> SCNScene? {
        guard let loaded = try? SCNScene(url: modelURL, options: nil) else { return nil }
        let scene = SCNScene()

        let model = SCNNode()
        for child in loaded.rootNode.childNodes { model.addChildNode(child) }
        let (minB, maxB) = model.boundingBox
        model.pivot = SCNMatrix4MakeTranslation((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
        model.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)

        let gaze = SCNNode()
        gaze.name = "gaze"
        gaze.addChildNode(model)
        scene.rootNode.addChildNode(gaze)

        // Orthographic so the head doesn't change size as it turns.
        let cam = SCNNode()
        cam.name = "camera"
        cam.camera = SCNCamera()
        cam.camera!.usesOrthographicProjection = true
        cam.camera!.orthographicScale = 44
        cam.camera!.automaticallyAdjustsZRange = true
        cam.position = SCNVector3(0, 0, 160)
        scene.rootNode.addChildNode(cam)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.position = cam.position
        key.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 150
        scene.rootNode.addChildNode(ambient)

        return scene
    }

    /// Drives the gaze at ~30fps while the view is on screen. Euler math,
    /// no constraints: yaw about Y toward the cursor's horizontal offset,
    /// pitch about X toward its vertical offset (+X euler moves the +Z face
    /// toward -Y, i.e. down — so pitch is negated), clamped so the skull
    /// never shows its back, smoothed so it feels like attention, not
    /// tracking hardware.
    @MainActor
    final class Coordinator {
        private weak var view: SCNView?
        private var loop: Task<Void, Never>?

        func attach(_ view: SCNView) {
            self.view = view
            loop = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }
        }

        nonisolated func stop() {
            Task { @MainActor [self] in loop?.cancel() }
        }

        private func tick() {
            guard let view, let window = view.window,
                  let gaze = view.scene?.rootNode.childNode(withName: "gaze", recursively: false)
            else { return }
            let frameInWindow = view.convert(view.bounds, to: nil)
            let frameOnScreen = window.convertToScreen(frameInWindow)
            let dx = NSEvent.mouseLocation.x - frameOnScreen.midX
            let dy = NSEvent.mouseLocation.y - frameOnScreen.midY
            let reach: CGFloat = 260 // virtual distance: how far a screen offset turns the head
            let yaw = Float(max(-0.55, min(0.55, atan2(dx, reach))))
            let pitch = Float(max(-0.45, min(0.45, atan2(dy, reach))))
            let currentX = Float(gaze.eulerAngles.x)
            let currentY = Float(gaze.eulerAngles.y)
            let nextX = currentX + (-pitch - currentX) * 0.25
            let nextY = currentY + (yaw - currentY) * 0.25
            gaze.eulerAngles = SCNVector3(CGFloat(nextX), CGFloat(nextY), 0)
        }
    }
}
