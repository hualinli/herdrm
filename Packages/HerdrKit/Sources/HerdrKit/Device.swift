import Foundation

/// A machine running herdr. `local` talks straight to the Unix socket;
/// `ssh` reaches the remote socket through an OpenSSH stream-local forward.
public struct Device: Codable, Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: Codable, Sendable, Equatable, Hashable {
        case local
        case ssh(target: String)   // e.g. "vincent@10.10.10.87" or "vincent@mac-studio.tail"
        /// A host reached through the embedded tsnet userspace network. The
        /// Tailscale IP is stored separately from the display hostname so SSH
        /// never depends on the Mac's system DNS configuration.
        case tailscale(peerID: String, hostname: String, address: String, username: String)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Socket path override; nil means the default session socket (~/.config/herdr/herdr.sock).
    public var socketPath: String?
    /// Sniffed operating system id ("macos", "ubuntu", "debian", …); cached after first probe.
    public var osID: String?

    public init(id: UUID = UUID(), name: String, kind: Kind, socketPath: String? = nil, osID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.socketPath = socketPath
        self.osID = osID
    }

    public static let local = Device(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Local",
        kind: .local,
        osID: "macos"
    )

    public var isLocal: Bool {
        if case .local = kind { return true }
        return false
    }

    public var sshTarget: String? {
        switch kind {
        case .ssh(let target): return target
        case .tailscale(_, _, let address, let username):
            guard !address.isEmpty, !username.isEmpty else { return nil }
            let host = address.contains(":") && !address.hasPrefix("[")
                ? "[\(address)]"
                : address
            return "\(username)@\(host)"
        case .local: return nil
        }
    }

    public var isTailscale: Bool {
        if case .tailscale = kind { return true }
        return false
    }

    public var tailscalePeerID: String? {
        if case .tailscale(let peerID, _, _, _) = kind { return peerID }
        return nil
    }

    public var subtitle: String {
        switch kind {
        case .local: return "This Mac · herdr.sock"
        case .ssh(let target): return "\(target) · SSH"
        case .tailscale(_, let hostname, _, let username):
            return "\(username)@\(hostname) · Tailscale"
        }
    }
}

/// Persists the device list as JSON under Application Support.
public final class DeviceStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.bybee.herdrm.devices")

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("devices.json")
    }

    public func load() -> [Device] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let devices = try? JSONDecoder().decode([Device].self, from: data),
                  !devices.isEmpty
            else { return [.local] }
            // Local is always present and always first.
            var list = devices.filter { !$0.isLocal }
            list.insert(.local, at: 0)
            return list
        }
    }

    public func save(_ devices: [Device]) {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(devices) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
