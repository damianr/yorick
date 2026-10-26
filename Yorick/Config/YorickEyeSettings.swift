import Foundation

enum YorickEyeStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case ember, curious, wisp, fireflies, ribbon, starstruck, resonance, equalizer, circular, blaze, torch, soft, hearts, orbit, comet, starburst, lanterns, bubbles, aurora, confetti, bloom, prism, ripples, lava
    static let allCases: [Self] = [.ember, .soft, .wisp, .blaze, .torch, .equalizer, .circular, .hearts, .starburst, .lanterns, .bubbles, .ripples, .confetti, .bloom, .lava]
    static let groups: [(String, [Self])] = [
        ("Eyes", [.ember, .soft]),
        ("Flames & atmosphere", [.wisp, .blaze, .torch, .ripples]),
        ("Equalizers", [.equalizer, .circular]),
        ("Particles", [.hearts, .starburst, .lanterns, .bubbles, .confetti]),
        ("Gradients", [.bloom, .lava])
    ]
    var id: String { rawValue }
    // Keep the existing saved/wire key so installed receivers and preferences
    // remain compatible when Wisp is replaced by the Flame artwork.
    var title: String { self == .wisp ? "Flame" : self == .circular ? "Circular EQ" : rawValue.capitalized }
    var detail: String {
        switch self {
        case .blaze: "A wide, restless bed of fire."
        case .torch: "Tall, curling tongues of warm light."
        case .soft: "Simple mint-colored pill eyes, with soft blinks."
        case .hearts: "Small drifting hearts that burst outward with speech."
        case .bloom: "Full-screen pools of color bloom with speech and fade when idle."
        case .ripples: "Concentric blue waves carry the energy of your voice outward."
        case .lava: "Warm flowing blobs brighten and merge with speech."
        case .prism: "Sound-driven gradient bands fill the displays."
        case .starburst: "Tiny golden stars scatter outward with speech."
        case .lanterns: "A quiet firefly swarm that wakes and spreads with your voice."
        case .bubbles: "Floating cyan bubbles expand into a lively cloud."
        case .aurora: "Three colored curtains swell and ripple with speech."
        case .confetti: "Colorful little fragments tumble outward with your voice."
        case .orbit: "A small moon surrounded by orbiting lights."
        case .comet: "A warm comet with a trailing tail."
        case .ember: "Warm, sleepy embers that perk up when listening."
        case .curious: "Small sage eyes with a soft, attentive gaze."
        case .wisp: "Broad, overlapping flames that rise with your voice."
        case .fireflies: "Golden lights that gather and respond to sound."
        case .ribbon: "Lilac waves that expand with each syllable."
        case .starstruck: "Small stars that unfold and stretch with speech."
        case .circular: "A round field of dots that lights from the center outward and upward."
        case .equalizer: "Yorick’s warm dotted voice meter, in both eyes."
        case .resonance: "Blue irises with ripples that follow your voice."
        }
    }
}

struct YorickEyeSettings: Codable, Equatable, Sendable {
    var style: YorickEyeStyle = .ember
    var brightness: Int = 70
    var size: Int = 85
    var motion: Int = 80
    var sensitivity: Int = 100
    var reactive: Bool = true
    static let defaultsKey = "yorickMic.eyes.v1"

    func normalized() -> Self {
        var s = self
        if !YorickEyeStyle.allCases.contains(s.style) { s.style = .ember }
        s.brightness = min(100, max(10, brightness))
        s.size = min(115, max(60, size))
        s.motion = min(160, max(0, motion))
        s.sensitivity = min(200, max(25, sensitivity))
        return s
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings.normalized()
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(normalized()), forKey: Self.defaultsKey)
    }
    func command(sequence: UInt32) -> String {
        let s = normalized()
        return "YORICK SET \(sequence) \(s.style.rawValue) \(s.brightness) \(s.size) \(s.motion)\n"
    }
    func level(_ input: Float) -> Int {
        guard reactive, input.isFinite else { return 0 }
        return Int(min(100, max(0, input * Float(sensitivity))))
    }
}

enum YorickEyeProtocol {
    static let hello = "YORICK HELLO 1\n"
    static let ready = "YORICK EYES 1"
    static func acknowledgedSequence(_ line: String) -> UInt32? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "YORICK", parts[1] == "OK" else { return nil }
        return UInt32(parts[2])
    }
    #if YORICK_HARDWARE_LAB
    /// Wired skulls (USB, or the 2.4 GHz receiver) appear as ordinary audio
    /// inputs and serial ports, matched by their USB product names.
    static func controlProduct(forMicrophoneName name: String) -> String? {
        switch name {
        case "Yorick Microphone", "Yorick Desk Microphone": "Yorick Desk Microphone"
        case "Yorick Wireless Microphone": "Yorick Wireless Microphone"
        default: nil
        }
    }
    static func isControlProduct(_ name: String) -> Bool {
        ["Yorick Desk Microphone", "Yorick Wireless Microphone"].contains(name)
    }
    static func isMicrophoneName(_ name: String) -> Bool {
        ["Yorick Microphone", "Yorick Desk Microphone", "Yorick Wireless Microphone", SkullBluetoothProtocol.deviceName, SkullMiniBluetoothProtocol.deviceName].contains(name)
    }
    #endif
    static let bluetoothDeviceUID = SkullBluetoothProtocol.deviceUID
}
