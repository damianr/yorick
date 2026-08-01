import XCTest

/// Regression coverage for the OAuth callback listener actually binding.
///
/// Field-reported 2026-08-01: Linear accepted the loopback redirect and
/// returned a valid code, and the browser got ERR_CONNECTION_REFUSED —
/// nothing was listening. Every other piece of the flow was exercised by
/// unit tests; the one part that had to hold a socket was not, because it
/// looked like plumbing. This test is that gap closed.
final class LinearCallbackListenerTests: XCTestCase {

    /// Bind, hit the callback URL the way a browser would, and confirm the
    /// listener hands back the request path with its query intact.
    func testListenerBindsAndReceivesTheCallback() async throws {
        let listener = LinearCallbackListener()
        try await listener.start()
        defer { Task { await listener.stop() } }

        async let received = listener.waitForCallback(timeout: .seconds(10))

        let url = URL(string: "\(LinearOAuth.redirectURI)?code=test-code&state=test-state")!
        let (data, response) = try await URLSession.shared.data(from: url)

        // The browser must land on a finished page, not a connection reset.
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Connected to Linear"))

        let path = try await received
        let code = try LinearOAuth.authorizationCode(from: path, expectedState: "test-state")
        XCTAssertEqual(code, "test-code")
    }

    /// The port is fixed because Linear registers redirect URIs ahead of
    /// time, so a second bind has to fail loudly rather than silently
    /// landing somewhere the browser will never reach.
    func testSecondListenerOnTheSamePortFails() async throws {
        let first = LinearCallbackListener()
        try await first.start()
        defer { Task { await first.stop() } }

        let second = LinearCallbackListener()
        do {
            try await second.start()
            await second.stop()
            XCTFail("Expected the second bind on the same port to fail")
        } catch {
            // Any error is acceptable; silence is not.
        }
    }

    /// Loopback only. A listener reachable from the LAN is a different
    /// security posture than "the browser on this machine".
    func testListenerIsNotReachableOffLoopback() async throws {
        let listener = LinearCallbackListener()
        try await listener.start()
        defer { Task { await listener.stop() } }

        guard let lanAddress = Self.primaryLANAddress() else {
            throw XCTSkip("No non-loopback IPv4 address on this machine")
        }
        var request = URLRequest(
            url: URL(string: "http://\(lanAddress):\(LinearOAuth.redirectPort)/oauth/callback?code=x&state=y")!
        )
        request.timeoutInterval = 3
        do {
            _ = try await URLSession.shared.data(for: request)
            XCTFail("Listener answered on \(lanAddress); it must bind loopback only")
        } catch {
            // Refused or timed out — both mean not listening there.
        }
    }

    private static func primaryLANAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidate: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = pointer.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidate = String(cString: host)
            break
        }
        return candidate
    }
}
