#if os(macOS)
import Foundation

/// Discovers herdr *named* sessions (`herdr --session <name>` / `HERDR_SESSION`).
///
/// Each named session is a separate server with its own socket at
/// `~/.config/herdr/sessions/<name>/herdr.sock` (herdr's `data_dir_for`). The
/// default session lives at `~/.config/herdr/herdr.sock`. herdrm's Local device
/// only ever talked to the default socket, so named sessions — where several
/// agent-orchestration skills isolate their work — were invisible (issue #81).
/// This surfaces each live named session as an extra Local device.
public enum HerdrSessionDiscovery {
    public struct NamedSession: Equatable, Sendable {
        public let name: String
        public let socketPath: String
    }

    /// Named sessions with a live socket file, sorted by name. `default` is the
    /// reserved name for the primary session and is skipped (it is the built-in
    /// Local device).
    public static func namedSessions(
        configDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [NamedSession] {
        let base = configDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".config/herdr", isDirectory: true)
        let sessionsDir = base.appendingPathComponent("sessions", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [NamedSession] = []
        for dir in entries {
            let name = dir.lastPathComponent
            guard name != "default" else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            let socket = dir.appendingPathComponent("herdr.sock")
            // Only sessions whose server is (or was) up: a socket file exists.
            // A stale socket for a dead server surfaces as a normal connection
            // failure, the same as any other Local server that is not running.
            guard fileManager.fileExists(atPath: socket.path) else { continue }
            result.append(NamedSession(name: name, socketPath: socket.path))
        }
        return result.sorted { $0.name < $1.name }
    }

    /// A Local device for a named session. The id is derived from the name so
    /// the device filter and selection survive relaunch and never collide with
    /// the built-in Local device.
    public static func device(for session: NamedSession) -> Device {
        Device(
            id: deterministicID(for: session.name),
            name: session.name,
            kind: .local,
            socketPath: session.socketPath,
            osID: "macos"
        )
    }

    /// A stable UUID from the session name (FNV-1a over two rounds). Not
    /// cryptographic — just a deterministic, collision-resistant device id.
    static func deterministicID(for name: String) -> UUID {
        func fnv(_ seed: UInt64, _ string: String) -> UInt64 {
            var hash = seed
            for byte in string.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            return hash
        }
        let low = fnv(14_695_981_039_346_656_037, "herdr-session:\(name)")
        let high = fnv(low ^ 0x9E37_79B9_7F4A_7C15, name)
        let hex = String(format: "%016llx%016llx", high, low)
        let uuidString = [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20).prefix(12),
        ].joined(separator: "-")
        return UUID(uuidString: uuidString) ?? UUID()
    }
}
#endif  // os(macOS)
