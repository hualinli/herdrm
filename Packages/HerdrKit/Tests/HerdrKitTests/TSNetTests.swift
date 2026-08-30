#if os(macOS)
import XCTest
@testable import HerdrKit

final class TSNetTests: XCTestCase {
    func testStatusDecodesHelperWireFormatAndPreservesPeerRelay() throws {
        let data = Data(
            """
            {
              "state": "Running",
              "version": "1.102.2",
              "tailnet": "example.com",
              "magic_dns": "example.ts.net",
              "tailscale_ips": ["100.64.0.2"],
              "peers": [{
                "id": "n123",
                "hostname": "build-box",
                "dns_name": "build-box.example.ts.net",
                "os": "linux",
                "addresses": ["100.64.0.3"],
                "online": true,
                "connection": "peer-relay",
                "peer_relay": "100.64.0.9:41641:3",
                "ping_ms": 23.5
              }]
            }
            """.utf8
        )
        let status = try JSONDecoder().decode(TailscaleStatus.self, from: data)
        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.peers.first?.preferredAddress, "100.64.0.3")
        XCTAssertEqual(status.peers.first?.transportDescription, "Peer relay")
        XCTAssertEqual(status.peers.first?.pingDescription, "24 ms")
        XCTAssertEqual(status.peers.first?.dnsName, "build-box.example.ts.net")
    }

    func testTailscaleDeviceBuildsSSHTargetFromStoredAddress() {
        let device = Device(
            name: "build-box",
            kind: .tailscale(
                peerID: "n123",
                hostname: "build-box.example.ts.net",
                address: "100.64.0.3",
                username: "vincent"
            )
        )
        XCTAssertTrue(device.isTailscale)
        XCTAssertEqual(device.sshTarget, "vincent@100.64.0.3")
        XCTAssertEqual(device.tailscalePeerID, "n123")
    }
}
#endif
