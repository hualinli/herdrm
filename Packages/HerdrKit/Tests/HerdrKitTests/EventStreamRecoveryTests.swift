import Darwin
import Foundation
import XCTest
@testable import HerdrKit

final class EventStreamRecoveryTests: XCTestCase {
    /// Uses a private fake server: no user's panes or agents are touched.
    func testIdleStreamDeliversScopedStatusAndCancellationClosesSocket() async throws {
        let server = try EventTestServer()
        let finished = expectation(description: "done arrived after the old 15 second timeout")
        let closed = expectation(description: "cancel wakes the blocked socket reader")
        let worker = expectation(description: "server finished")
        DispatchQueue.global().async {
            defer { worker.fulfill() }
            do {
                let fd = try server.acceptClient()
                defer { close(fd) }
                let request = try XCTUnwrap(SocketRPC.readLine(fd: fd, timeoutSeconds: 3))
                let json = try JSONDecoder().decode(JSONValue.self, from: request)
                XCTAssertEqual(json["params"], SocketRPC.eventSubscriptionParams(
                    kinds: ["pane.updated"], statusPaneIDs: ["p1"]
                ))
                // Ack and the first status deliberately share a single write.
                try SocketRPC.writeLine(fd: fd, data: Data((
                    "{\"id\":\"events\",\"result\":{}}\n" +
                    "{\"event\":\"pane.agent_status_changed\",\"data\":{\"pane_id\":\"p1\",\"agent_status\":\"working\"}}\n"
                ).utf8))
                Thread.sleep(forTimeInterval: 16)
                try SocketRPC.writeLine(fd: fd, data: Data(
                    "{\"event\":\"pane.agent_status_changed\",\"data\":{\"pane_id\":\"p1\",\"agent_status\":\"done\"}}\n".utf8
                ))
                // The client is idle in read(); cancelling it must wake that read.
                XCTAssertNil(try SocketRPC.readLine(fd: fd, timeoutSeconds: 3))
                closed.fulfill()
            } catch { XCTFail("fake server: \(error)") }
        }
        let collector = Task {
            var statuses: [String] = []
            do {
                for try await event in SocketRPC(socketPath: server.path).events(
                    kinds: ["pane.updated"], statusPaneIDs: ["p1"]
                ) {
                    if let status = event.payload["data"]?["agent_status"]?.stringValue {
                        statuses.append(status)
                        if status == "done" {
                            XCTAssertEqual(statuses, ["working", "done"])
                            finished.fulfill()
                        }
                    }
                }
            } catch { XCTFail("idle event stream failed: \(error)") }
        }
        await fulfillment(of: [finished], timeout: 20)
        collector.cancel()
        await fulfillment(of: [closed, worker], timeout: 4)
        await collector.value
    }

    func testMissingPaneFallsBackToLifecycleOnRealSocket() async throws {
        let server = try EventTestServer()
        let received = expectation(description: "lifecycle delivered after rejected pane")
        let worker = expectation(description: "fallback server finished")
        DispatchQueue.global().async {
            defer { worker.fulfill() }
            do {
                let first = try server.acceptClient()
                _ = try SocketRPC.readLine(fd: first, timeoutSeconds: 3)
                try SocketRPC.writeLine(fd: first, data: Data(
                    "{\"id\":\"events\",\"error\":{\"code\":\"pane_not_found\",\"message\":\"gone\"}}\n".utf8
                ))
                close(first)
                let second = try server.acceptClient()
                defer { close(second) }
                let request = try XCTUnwrap(SocketRPC.readLine(fd: second, timeoutSeconds: 3))
                let json = try JSONDecoder().decode(JSONValue.self, from: request)
                XCTAssertEqual(json["params"], SocketRPC.eventSubscriptionParams(
                    kinds: ["pane.created"], statusPaneIDs: []
                ))
                try SocketRPC.writeLine(fd: second, data: Data(
                    "{\"id\":\"events\",\"result\":{}}\n{\"event\":\"pane_created\",\"data\":{}}\n".utf8
                ))
            } catch { XCTFail("fallback server: \(error)") }
        }
        let collector = Task {
            do {
                for try await event in SocketRPC(socketPath: server.path).events(
                    kinds: ["pane.created"], statusPaneIDs: ["gone"]
                ) {
                    if event.kind == "pane.created" { received.fulfill() }
                }
            } catch { XCTFail("fallback failed: \(error)") }
        }
        await fulfillment(of: [received, worker], timeout: 5)
        collector.cancel()
        await collector.value
    }

    func testSilentSnapshotsRetryTransientFailureAndDetectPersistentFailure() async {
        let probe = RecoveryProbe(results: [false, true, false, false])
        let healthy = await SnapshotRecovery.run(intervalNanoseconds: 1_000_000) {
            await probe.refresh()
        }
        XCTAssertFalse(healthy)
        let count = await probe.count
        XCTAssertEqual(count, 4, "one failed snapshot must not reconnect a healthy stream")
    }

    func testCancellingRecoveryStopsPollingWithoutRequestingReconnect() async {
        let probe = RecoveryProbe(results: [true])
        let task = Task {
            await SnapshotRecovery.run(intervalNanoseconds: 30_000_000_000) {
                await probe.refresh()
            }
        }
        task.cancel()
        let healthy = await task.value
        XCTAssertTrue(healthy)
        let count = await probe.count
        XCTAssertEqual(count, 0)
    }
}

private actor RecoveryProbe {
    var count = 0
    let results: [Bool]
    init(results: [Bool]) { self.results = results }
    func refresh() -> Bool {
        defer { count += 1 }
        return results[min(count, results.count - 1)]
    }
}

private final class EventTestServer: @unchecked Sendable {
    let path = "/tmp/hke-\(UUID().uuidString.prefix(8))"
    let fd: Int32
    init() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.connectionFailed("test socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw HerdrError.connectionFailed("test bind/listen: \(String(cString: strerror(errno)))")
        }
    }
    func acceptClient() throws -> Int32 {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 5_000) > 0 else {
            throw HerdrError.connectionFailed("test accept timed out")
        }
        let client = accept(fd, nil, nil)
        guard client >= 0 else { throw HerdrError.connectionFailed("test accept") }
        var enabled: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        return client
    }
    deinit { close(fd); unlink(path) }
}
