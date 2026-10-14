import Foundation

enum YorickEyeStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case ember, curious, wisp, fireflies, ribbon, starstruck, resonance, equalizer, circular
    var id: String { rawValue }
    // Keep the existing saved/wire key so installed receivers and preferences
    // remain compatible when Wisp is replaced by the Flame artwork.
    var title: String { self == .wisp ? "Flame" : self == .circular ? "Circular EQ" : rawValue.capitalized }
    var detail: String {
        switch self {
        case .ember: "Warm, sleepy embers that perk up when listening."
        case .curious: "Small sage eyes with a soft, attentive gaze."
        case .wisp: "Little amber flames that flicker and rise with your voice."
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
        ["Yorick Microphone", "Yorick Desk Microphone", "Yorick Wireless Microphone"].contains(name)
    }
}
