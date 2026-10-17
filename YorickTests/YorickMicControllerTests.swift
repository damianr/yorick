import XCTest
import Darwin

// Wired skull / receiver and eye tuning: hardware-lab builds only.
#if YORICK_HARDWARE_LAB

final class YorickMicControllerTests: XCTestCase {
    @MainActor func testHandshakeAcknowledgementAndActiveInput() async throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(openpty(&master, &slave, &name, nil, nil), 0)
        defer { close(master); close(slave) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let path = String(cString: name)
        let defaults = UserDefaults(suiteName: "YorickMicTests.\(UUID())")!
        let mic = YorickMicController(monitor: false, defaults: defaults, discover: { (1, [path]) })
        mic.tick()
        for _ in 0..<100 {
            if !mic.opening { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        mic.tick()
        XCTAssertTrue(mic.attached); XCTAssertFalse(mic.controlsReady)
        XCTAssertTrue(readText(master).contains("YORICK HELLO 1"))
        writeText(master, "YORICK EYES 1\n")
        mic.tick(); XCTAssertTrue(mic.controlsReady); XCTAssertFalse(mic.applied)
        let set = readText(master).split(separator: "\n").first { $0.hasPrefix("YORICK SET") }!
        let seq = set.split(separator: " ")[2]
        writeText(master, "YORICK OK 999\n"); mic.tick(); XCTAssertFalse(mic.applied)
        writeText(master, "YORICK OK \(seq)\n"); mic.tick(); XCTAssertTrue(mic.applied)
        _ = readText(master)
        // A receiver can stay attached while the skull reboots. Settings must
        // refresh, and only the skull's matching ACK can confirm delivery.
        try await Task.sleep(for: .milliseconds(2100))
        mic.tick()
        XCTAssertTrue(readText(master).contains("YORICK SET"))
        try await Task.sleep(for: .milliseconds(1100))
        mic.tick(); XCTAssertFalse(mic.applied)
        let retrySet = readText(master).split(separator: "\n").first { $0.hasPrefix("YORICK SET") }!
        let retrySeq = retrySet.split(separator: " ")[2]
        writeText(master, "YORICK OK \(seq)\n"); mic.tick(); XCTAssertFalse(mic.applied)
        writeText(master, "YORICK OK \(retrySeq)\n"); mic.tick(); XCTAssertTrue(mic.applied)
        _ = readText(master)
        mic.recording = true; mic.recordingMicName = "MacBook Microphone"; mic.audioLevel = 0.8
        mic.tick(); XCTAssertTrue(readText(master).contains("YORICK STATE 0 0"))
        mic.recordingMicName = "Yorick Microphone"
        mic.tick(); XCTAssertTrue(readText(master).contains("YORICK STATE 1 80"))
        mic.recordingMicName = "Yorick Wireless Microphone"
        mic.tick(); XCTAssertTrue(readText(master).contains("YORICK STATE 1 80"))
        mic.settings.reactive = false
        mic.tick(); XCTAssertTrue(readText(master).contains("YORICK STATE 1 0"))
        mic.settings.reactive = true; mic.settings.sensitivity = 50
        mic.tick(); XCTAssertTrue(readText(master).contains("YORICK STATE 1 40"))
        mic.stalled = true
        mic.tick(); XCTAssertTrue(readText(master).contains("YORICK STATE 0 0"))
        mic.settings.style = .ribbon
        XCTAssertFalse(mic.applied)
        writeText(master, "YORICK OK \(seq)\n"); mic.tick(); XCTAssertFalse(mic.applied)
        mic.retry(); XCTAssertFalse(mic.controlsReady); XCTAssertFalse(mic.applied)
        defaults.removeObject(forKey: YorickEyeSettings.defaultsKey)
    }
    @MainActor func testUnpluggedOrAmbiguousDevicesNeverOpenControl() {
        let defaults = UserDefaults(suiteName: "YorickMicTests.\(UUID())")!
        let absent = YorickMicController(monitor: false, defaults: defaults, discover: { (0, []) })
        absent.tick(); XCTAssertFalse(absent.attached); XCTAssertFalse(absent.controlsReady)
        let ambiguous = YorickMicController(monitor: false, defaults: defaults, discover: { (2, ["/dev/no-such-port", "/dev/another-port"]) })
        ambiguous.tick(); XCTAssertTrue(ambiguous.attached); XCTAssertFalse(ambiguous.controlsReady)
        XCTAssertTrue(ambiguous.needsInputSelection)
        XCTAssertTrue(ambiguous.status.contains("Choose the Yorick"))
    }
    @MainActor func testSelectedInputRoutesEyesWhenBothTransportsAreAttached() {
        let wired = YorickMicController.ControlPort(path: "/dev/wired", product: "Yorick Desk Microphone")
        let wireless = YorickMicController.ControlPort(path: "/dev/radio", product: "Yorick Wireless Microphone")
        let names = ["Yorick Microphone", "Yorick Wireless Microphone"]
        let radio = YorickMicController.resolveInventory(audioNames: names, ports: [wired, wireless], selectedMicrophoneName: "Yorick Wireless Microphone")
        XCTAssertEqual(radio.audioCount, 1); XCTAssertEqual(radio.ports, ["/dev/radio"])
        let usb = YorickMicController.resolveInventory(audioNames: names, ports: [wired, wireless], selectedMicrophoneName: "Yorick Microphone")
        XCTAssertEqual(usb.audioCount, 1); XCTAssertEqual(usb.ports, ["/dev/wired"])
        let ambiguous = YorickMicController.resolveInventory(audioNames: names, ports: [wired, wireless], selectedMicrophoneName: "MacBook Microphone")
        XCTAssertEqual(ambiguous.audioCount, 0); XCTAssertTrue(ambiguous.ports.isEmpty)
        let duplicate = YorickMicController.resolveInventory(audioNames: ["Yorick Wireless Microphone", "Yorick Wireless Microphone"], ports: [wireless, wireless], selectedMicrophoneName: "Yorick Wireless Microphone")
        XCTAssertEqual(duplicate.audioCount, 2); XCTAssertEqual(duplicate.ports.count, 2)
        let onlyUSB = YorickMicController.resolveInventory(audioNames: ["Yorick Microphone"], ports: [wired], selectedMicrophoneName: nil)
        XCTAssertEqual(onlyUSB.audioCount, 0); XCTAssertTrue(onlyUSB.ports.isEmpty)
    }
    @MainActor func testBlockedPortSetupDoesNotBlockUIOrApplyStaleOpen() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let mic = YorickMicController(monitor: false, discover: { (1, ["test-port"]) }, configurePort: { _ in
            _ = gate.wait(timeout: .now() + 2)
            return -1
        })
        mic.tick()
        XCTAssertTrue(mic.opening)
        try await Task.sleep(for: .milliseconds(30))
        mic.retry(); mic.tick()
        XCTAssertTrue(mic.opening) // retry cannot create additional blocked workers
        XCTAssertFalse(mic.controlsReady)
        gate.signal()
        for _ in 0..<100 {
            if !mic.opening { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(mic.opening)
        XCTAssertFalse(mic.controlsReady)
    }
    @MainActor func testPocketSelectionNeverFindsAttachedSkullControls() {
        let skull = YorickMicController.ControlPort(path: "/dev/skull", product: "Yorick Wireless Microphone")
        for selected in ["Yorick Pocket Wireless", "Yorick Pocket Microphone", "MacBook Microphone"] {
            let result = YorickMicController.resolveInventory(
                audioNames: ["Yorick Wireless Microphone", selected], ports: [skull], selectedMicrophoneName: selected)
            XCTAssertEqual(result.audioCount, 0)
            XCTAssertTrue(result.ports.isEmpty)
        }
        let unavailable = YorickMicController.resolveInventory(audioNames: ["Yorick Wireless Microphone"], ports: [skull], selectedMicrophoneName: "Yorick Microphone")
        XCTAssertEqual(unavailable.audioCount, 0)
        XCTAssertTrue(unavailable.ports.isEmpty)
    }

    @MainActor func testEyeVisibilityRequiresSelectedSkullAndFreshReply() async throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(openpty(&master, &slave, &name, nil, nil), 0)
        defer { close(master); close(slave) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let path = String(cString: name)
        var selectedSkull = true
        var now = Date()
        let mic = YorickMicController(monitor: false,
            discover: { selectedSkull ? (1, [path]) : (0, []) }, clock: { now })
        mic.tick()
        for _ in 0..<100 {
            if !mic.opening { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        mic.tick()
        XCTAssertTrue(mic.attached)
        XCTAssertFalse(mic.showEyeControls) // USB receiver alone is insufficient.
        writeText(master, "YORICK EYES 1\n"); mic.tick()
        XCTAssertTrue(mic.showEyeControls)
        now = now.addingTimeInterval(4.1)
        mic.tick()
        XCTAssertFalse(mic.showEyeControls) // Skull disappeared; receiver stays attached.
        mic.retry(); mic.tick()
        for _ in 0..<100 {
            if !mic.opening { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        mic.tick(); writeText(master, "YORICK EYES 1\n"); mic.tick()
        XCTAssertTrue(mic.showEyeControls)
        selectedSkull = false
        mic.inputSelectionChanged()
        XCTAssertFalse(mic.showEyeControls) // Picker change hides without a polling delay.
        XCTAssertFalse(mic.attached)
    }

    private func writeText(_ fd: Int32, _ value: String) {
        let data = Array(value.utf8)
        XCTAssertEqual(data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, data.count)
    }
    private func readText(_ fd: Int32) -> String {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        return n > 0 ? String(decoding: bytes.prefix(n), as: UTF8.self) : ""
    }
}
#endif
