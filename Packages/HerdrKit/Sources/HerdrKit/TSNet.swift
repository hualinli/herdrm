#if os(macOS)
import Foundation
import Security

/// A peer visible in the embedded Tailscale node's network map. The connection
/// field is the transport currently reported by magicsock: direct, peer-relay,
/// DERP, connecting, or offline.
public struct TailscalePeer: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let hostname: String
    public let dnsName: String
    public let os: String
    public let addresses: [String]
    public let online: Bool
    public let connection: String
    public let relay: String?
    public let peerRelay: String?
    public let currentAddress: String?
    public let pingMilliseconds: Double?

    public var displayName: String {
        if !hostname.isEmpty { return hostname }
        if !dnsName.isEmpty { return dnsName }
        return addresses.first ?? id
    }

    /// The address used by OpenSSH. Tailscale IPs avoid relying on the host
    /// operating system's DNS configuration, which tsnet intentionally does not
    /// install or modify.
    public var preferredAddress: String? {
        addresses.first ?? (dnsName.isEmpty ? nil : dnsName)
    }

    public var transportDescription: String {
        switch connection {
        case "direct": return "Direct"
        case "peer-relay": return "Peer relay"
        case "derp": return relay.map { "DERP · \($0)" } ?? "DERP"
        case "connecting": return "Connecting…"
        default: return "Offline"
        }
    }

    public var pingDescription: String? {
        guard let pingMilliseconds else { return nil }
        if pingMilliseconds < 1 { return "<1 ms" }
        return "\(Int(pingMilliseconds.rounded())) ms"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case hostname
        case dnsName = "dns_name"
        case os
        case addresses
        case online
        case connection
        case relay
        case peerRelay = "peer_relay"
        case currentAddress = "current_addr"
        case pingMilliseconds = "ping_ms"
    }

    public init(
        id: String,
        hostname: String,
        dnsName: String = "",
        os: String = "",
        addresses: [String] = [],
        online: Bool,
        connection: String,
        relay: String? = nil,
        peerRelay: String? = nil,
        currentAddress: String? = nil,
        pingMilliseconds: Double? = nil
    ) {
        self.id = id
        self.hostname = hostname
        self.dnsName = dnsName
        self.os = os
        self.addresses = addresses
        self.online = online
        self.connection = connection
        self.relay = relay
        self.peerRelay = peerRelay
        self.currentAddress = currentAddress
        self.pingMilliseconds = pingMilliseconds
    }
}

public struct TailscaleStatus: Codable, Sendable, Equatable {
    public let state: String
    public let version: String
    public let authURL: String?
    public let tailnet: String?
    public let magicDNS: String?
    public let tailscaleIPs: [String]
    public let peers: [TailscalePeer]

    public var isRunning: Bool { state == "Running" }

    enum CodingKeys: String, CodingKey {
        case state
        case version
        case authURL = "auth_url"
        case tailnet
        case magicDNS = "magic_dns"
        case tailscaleIPs = "tailscale_ips"
        case peers
    }

    public init(
        state: String,
        version: String,
        authURL: String? = nil,
        tailnet: String? = nil,
        magicDNS: String? = nil,
        tailscaleIPs: [String] = [],
        peers: [TailscalePeer] = []
    ) {
        self.state = state
        self.version = version
        self.authURL = authURL
        self.tailnet = tailnet
        self.magicDNS = magicDNS
        self.tailscaleIPs = tailscaleIPs
        self.peers = peers
    }
}

/// Stores the Tailscale auth key in the login Keychain. The key is only sent
/// over a pipe to the short-lived helper during startup; tsnet stores its node
/// identity in its own protected state directory and does not need the auth key
/// on subsequent starts.
public enum TailscaleCredentialStore {
    private static let service = "dev.bybee.herdrm.tailscale-auth-key"
    private static let account = "default"

    public static func authKey() throws -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw TailscaleCredentialError(status: status == errSecSuccess ? errSecDecode : status) }
        return value
    }

    public static func setAuthKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            try removeAuthKey()
            return
        }
        let data = Data(key.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let query = keychainQuery()
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw TailscaleCredentialError(status: update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw TailscaleCredentialError(status: add) }
    }

    public static func removeAuthKey() throws {
        let status = SecItemDelete(keychainQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TailscaleCredentialError(status: status)
        }
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct TailscaleCredentialError: LocalizedError, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "could not access the Tailscale auth key in Keychain: \(detail)"
    }
}

/// Owns the bundled tsnet helper. A helper is a userspace Tailscale node, not a
/// system daemon: it has no tunnel interface, does not alter DNS, and exits with
/// herdrm. Its private control socket also doubles as OpenSSH's ProxyCommand
/// byte pipe, so every SSH operation (including PTYs and file transfers) uses
/// tsnet's real Dial path.
public actor TSNetManager {
    public let helperURL: URL
    public let stateDirectory: URL
    public let controlSocketPath: String

    private var process: Process?
    private var configuredForceDERP = false

    public init(
        helperURL: URL,
        stateDirectory: URL? = nil
    ) {
        self.helperURL = helperURL
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM", isDirectory: true)
        let state = stateDirectory
            ?? applicationSupport.appendingPathComponent("Tailscale", isDirectory: true)
        self.stateDirectory = state
        self.controlSocketPath = state.appendingPathComponent("control.sock").path
    }

    deinit {
        process?.terminate()
    }

    /// The shell command OpenSSH runs for a tsnet device. The helper's daemon
    /// owns the other side of this socket and hands the connection to tsnet.Dial.
    /// This property is intentionally synchronous: TerminalCommand is created
    /// by SwiftTerm's NSViewRepresentable, while the daemon was started by the
    /// app model before a user can attach.
    public nonisolated var proxyCommand: String {
        "\(ShellQuoting.quoted(helperURL.path)) proxy --control \(ShellQuoting.quoted(controlSocketPath)) '%h' '%p'"
    }

    public func start(authKey: String? = nil, forceDERP: Bool) async throws -> TailscaleStatus {
        if let process, process.isRunning {
            if configuredForceDERP == forceDERP {
                return try await status()
            }
            stop()
        }

        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw HerdrError.tailscaleFailed(
                "bundled tsnet helper is missing at \(helperURL.path); rebuild herdrm"
            )
        }
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.removeItem(atPath: controlSocketPath)

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "daemon",
            "--control", controlSocketPath,
            "--state", stateDirectory.path,
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw HerdrError.tailscaleFailed("could not start tsnet helper: \(error.localizedDescription)")
        }
        self.process = process
        configuredForceDERP = forceDERP

        let key = authKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let config: [String: Any] = ["auth_key": key, "force_derp": forceDERP]
        do {
            try Task.checkCancellation()
            let data = try JSONSerialization.data(withJSONObject: config) + Data([0x0A])
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
            let line = try await Task.detached(priority: .userInitiated) {
                try Self.readLine(from: output.fileHandleForReading)
            }.value
            try Task.checkCancellation()
            let ready = try JSONDecoder().decode(ReadyResponse.self, from: line)
            guard ready.type == "ready" else {
                throw HerdrError.tailscaleFailed(ready.error ?? "tsnet helper failed to start")
            }
            return try await status()
        } catch {
            // A newer start can be in flight while this task is waiting for
            // the old helper's startup line. Never tear down that newer
            // process from this task's cleanup path.
            if self.process === process {
                process.terminate()
                self.process = nil
                try? FileManager.default.removeItem(atPath: controlSocketPath)
            }
            if let error = error as? HerdrError { throw error }
            throw HerdrError.tailscaleFailed(error.localizedDescription)
        }
    }

    public func status() async throws -> TailscaleStatus {
        guard let process, process.isRunning else {
            throw HerdrError.tailscaleFailed("Tailscale is not connected")
        }
        let result = try await send(["op": "status"])
        do {
            return try JSONDecoder().decode(TailscaleStatus.self, from: result)
        } catch {
            throw HerdrError.tailscaleFailed("invalid tsnet status: \(error.localizedDescription)")
        }
    }

    public func hasSavedState() -> Bool {
        FileManager.default.fileExists(
            atPath: stateDirectory.appendingPathComponent("tailscaled.state").path
        )
    }

    public func ensureRunning() throws {
        guard let process, process.isRunning,
              FileManager.default.fileExists(atPath: controlSocketPath)
        else { throw HerdrError.tailscaleFailed("Tailscale is not connected") }
    }

    public func stop() {
        let oldProcess = process
        process = nil
        oldProcess?.terminate()
        if oldProcess?.isRunning == true { oldProcess?.waitUntilExit() }
        try? FileManager.default.removeItem(atPath: controlSocketPath)
    }

    /// Removes the tsnet node identity as well as stopping the helper. This is
    /// the "Clear" action in Settings; the next connection creates a fresh node.
    public func reset() {
        stop()
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private func send(_ object: [String: Any]) async throws -> Data {
        let path = controlSocketPath
        return try await Task.detached(priority: .userInitiated) {
            let fd = try SocketRPC.connect(path: path)
            defer { close(fd) }
            let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
            try SocketRPC.writeLine(fd: fd, data: data)
            let line = try SocketRPC.readLine(fd: fd, timeoutSeconds: 15)
            do {
                let result = try SocketRPC.decodeResponse(line)
                return try JSONEncoder().encode(result)
            } catch let error as HerdrError {
                throw error
            }
        }.value
    }

    private struct ReadyResponse: Decodable {
        let type: String
        let error: String?
    }

    private static func readLine(from handle: FileHandle) throws -> Data {
        var result = Data()
        while true {
            let chunk = try handle.read(upToCount: 1) ?? Data()
            guard !chunk.isEmpty else { throw HerdrError.tailscaleFailed("tsnet helper exited before becoming ready") }
            result.append(chunk)
            if chunk.last == 0x0A { return Data(result.dropLast()) }
            if result.count > 16 * 1024 {
                throw HerdrError.tailscaleFailed("tsnet helper returned an oversized startup response")
            }
        }
    }
}
#endif  // os(macOS)
