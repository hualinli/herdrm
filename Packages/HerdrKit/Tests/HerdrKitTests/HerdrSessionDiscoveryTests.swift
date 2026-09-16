#if os(macOS)
import XCTest

@testable import HerdrKit

final class HerdrSessionDiscoveryTests: XCTestCase {
    private func makeConfigDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-disco-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSession(_ config: URL, _ name: String, socket: Bool) throws {
        let dir = config.appendingPathComponent("sessions/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if socket {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("herdr.sock").path, contents: nil)
        }
    }

    func testFindsNamedSessionsWithLiveSockets() throws {
        let config = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: config) }
        try makeSession(config, "work", socket: true)
        try makeSession(config, "review", socket: true)
        try makeSession(config, "stale", socket: false)   // no socket → skipped
        try makeSession(config, "default", socket: true)   // reserved → skipped

        let sessions = HerdrSessionDiscovery.namedSessions(configDirectory: config)
        XCTAssertEqual(sessions.map(\.name), ["review", "work"])   // sorted, no stale/default
        XCTAssertTrue(sessions.contains { $0.socketPath.hasSuffix("sessions/work/herdr.sock") })
    }

    func testNoSessionsDirectoryReturnsEmpty() throws {
        let config = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: config) }
        XCTAssertEqual(HerdrSessionDiscovery.namedSessions(configDirectory: config), [])
    }

    func testNamedSessionDeviceIsStableLocalWithSocketOverride() {
        let session = HerdrSessionDiscovery.NamedSession(name: "work", socketPath: "/tmp/x/herdr.sock")
        let device = HerdrSessionDiscovery.device(for: session)
        XCTAssertTrue(device.isLocal)
        XCTAssertTrue(device.isNamedSession)
        XCTAssertEqual(device.socketPath, "/tmp/x/herdr.sock")
        XCTAssertEqual(device.name, "work")
        // Deterministic id: same name → same id, different names → different ids.
        XCTAssertEqual(device.id, HerdrSessionDiscovery.device(for: session).id)
        XCTAssertNotEqual(
            device.id,
            HerdrSessionDiscovery.device(for: .init(name: "review", socketPath: "/tmp/y/herdr.sock")).id
        )
        XCTAssertNotEqual(device.id, Device.local.id)
    }
}
#endif
