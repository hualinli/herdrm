#if os(macOS)
import Darwin
import Foundation

struct SSHAuthenticationConfiguration {
    let arguments: [String]
    let environment: [String: String]
    let authorizationID: UUID?

    func discardAuthorization() {
        guard let authorizationID else { return }
        try? SSHCredentialStore.removeAuthorization(authorizationID)
    }
}

/// Collects asynchronous OpenSSH diagnostics without blocking its stderr pipe.
private final class SSHErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > 16_384 {
            data = data.suffix(16_384)
        }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Forwards a remote herdr Unix socket to a local one using the system OpenSSH client
/// (`ssh -N -L local.sock:remote.sock target`), so remote devices reuse SocketRPC as-is.
/// Auth uses OpenSSH config/agent/Tailscale SSH, with Keychain-backed askpass as a fallback.
public actor SSHTunnel {
    static let maximumUploadBytes = 50 * 1024 * 1024

    public let target: String
    public private(set) var localSocketPath: String?
    private let credentialID: UUID?
    private let tailscale: TSNetManager?
    private var process: Process?
    private var errorOutput: Pipe?
    private var errorBuffer: SSHErrorBuffer?
    private var remoteHome: String?

    /// PATH prepended on the remote side; sshd exec is not a login shell (mirrors Heeler).
    public static let remotePathExport =
        "for d in \"$HOME\"/.nvm/versions/node/*/bin; do [ -d \"$d\" ] && PATH=\"$d:$PATH\"; done; "
        + "export PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\""

    public init(
        target: String,
        credentialID: UUID? = nil,
        tailscale: TSNetManager? = nil
    ) {
        self.target = target
        self.credentialID = credentialID
        self.tailscale = tailscale
    }

    deinit {
        process?.terminate()
    }

    // MARK: - Probing

    /// Resolves the remote $HOME once; also proves SSH reachability.
    public func probeRemoteHome() async throws -> String {
        if let remoteHome { return remoteHome }
        let output = try await Self.runSSH(
            target: target,
            command: "echo \"$HOME\"",
            timeout: 12,
            credentialID: credentialID,
            tailscale: tailscale
        )
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") else {
            throw HerdrError.tunnelFailed("could not resolve remote home (got: \(output))")
        }
        remoteHome = home
        return home
    }

    public func remoteSocketPath() async throws -> String {
        let home = try await probeRemoteHome()
        return "\(home)/.config/herdr/herdr.sock"
    }

    // MARK: - Tunnel lifecycle

    /// Ensures the forward is up and returns the local socket path.
    public func ensureUp() async throws -> String {
        if let localSocketPath, let process, process.isRunning {
            return localSocketPath
        }
        process?.terminate()
        process = nil
        resetErrorCapture()

        try await tailscale?.ensureRunning()
        let remoteSock = try await remoteSocketPath()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-tunnels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep the path short: sockaddr_un caps at 104 bytes.
        let localSock = dir.appendingPathComponent("\(abs(target.hashValue) % 100_000).sock").path
        try? FileManager.default.removeItem(atPath: localSock)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let authentication = Self.authenticationConfiguration(for: credentialID)
        defer { authentication.discardAuthorization() }
        proc.arguments = ["-N"] + authentication.arguments + Self.proxyArguments(for: tailscale) + [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "StreamLocalBindUnlink=yes",
            "-L", "\(localSock):\(remoteSock)",
            Self.sshDestination(target),
        ]
        proc.environment = ProcessInfo.processInfo.environment.merging(authentication.environment) { _, new in new }
        let errorOutput = Pipe()
        let errorBuffer = SSHErrorBuffer()
        errorOutput.fileHandleForReading.readabilityHandler = { handle in
            errorBuffer.append(handle.availableData)
        }
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errorOutput
        self.errorOutput = errorOutput
        self.errorBuffer = errorBuffer
        // The probe above can suspend for seconds; if the session was cancelled meanwhile
        // (app quitting), spawning here would leak an ssh nobody is left to tear down.
        do {
            try Task.checkCancellation()
            try proc.run()
        } catch {
            resetErrorCapture()
            throw error
        }
        process = proc

        // Wait for the local socket to appear (ssh creates it once the session is up).
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath: localSock) {
                localSocketPath = localSock
                return localSock
            }
            if !proc.isRunning {
                let errorText = finishErrorCapture()
                throw HerdrError.tunnelFailed(Self.failureReason(status: proc.terminationStatus, stderr: errorText))
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        proc.terminate()
        process = nil
        resetErrorCapture()
        throw HerdrError.tunnelFailed("timed out waiting for forwarded socket")
    }

    public func tearDown() {
        process?.terminate()
        process = nil
        resetErrorCapture()
        if let localSocketPath {
            try? FileManager.default.removeItem(atPath: localSocketPath)
        }
        localSocketPath = nil
    }

    /// Returns an asynchronous forwarding error emitted after a client used the local socket.
    public func forwardingFailure() async -> String? {
        // OpenSSH writes channel failures just after the forwarded connection closes.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard let errorBuffer else { return nil }
        return Self.forwardingFailure(in: errorBuffer.text)
    }

    static func forwardingFailure(in stderr: String) -> String? {
        stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.contains("open failed:") }
    }

    private func finishErrorCapture() -> String {
        guard let errorOutput, let errorBuffer else { return "" }
        errorOutput.fileHandleForReading.readabilityHandler = nil
        errorBuffer.append(errorOutput.fileHandleForReading.readDataToEndOfFile())
        let text = errorBuffer.text
        self.errorOutput = nil
        self.errorBuffer = nil
        return text
    }

    private func resetErrorCapture() {
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        errorOutput = nil
        errorBuffer = nil
    }

    /// Turns "user@host:2222" into an OpenSSH `ssh://` URI so a custom port
    /// survives being passed as the single destination argument (there is no
    /// separate `-p` in the argv). Anything else — config aliases, plain
    /// user@host, existing ssh:// URIs, bare IPv6 addresses — passes through
    /// untouched; bracketed IPv6 with a port ("[::1]:2222") is recognized.
    public static func sshDestination(_ target: String) -> String {
        if target.hasPrefix("ssh://") { return target }
        guard let lastColon = target.lastIndex(of: ":") else { return target }
        let port = target[target.index(after: lastColon)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber),
              let portNumber = Int(port), (1...65535).contains(portNumber)
        else { return target }
        let hostPart = target[..<lastColon]
        let hostStart = hostPart.lastIndex(of: "@").map { hostPart.index(after: $0) } ?? hostPart.startIndex
        let host = hostPart[hostStart...]
        guard !host.isEmpty else { return target }
        if host.contains(":"), !(host.hasPrefix("[") && host.hasSuffix("]")) { return target }
        return "ssh://\(target)"
    }

    // MARK: - TCP latency

    /// Measures the network RTT needed to establish a TCP connection to the
    /// device's SSH endpoint. This deliberately stops at TCP connect: it does
    /// not include SSH authentication, a remote command, or herdr RPC time.
    /// `ssh -G` resolves user@host aliases and configured ports without making
    /// a network connection, then a non-blocking BSD socket performs the actual
    /// connect with a short timeout.
    public static func tcpLatency(
        target: String,
        timeout: TimeInterval = 3
    ) async -> Double? {
        await Task.detached(priority: .utility) {
            guard let endpoint = Self.resolveSSHEndpoint(target: target) else { return nil }
            return Self.connectLatency(
                host: endpoint.host,
                port: endpoint.port,
                timeout: timeout
            )
        }.value
    }

    private static func resolveSSHEndpoint(target: String) -> (host: String, port: UInt16)? {
        let destination = sshDestination(target)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-o", "BatchMode=yes", destination]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return fallbackSSHEndpoint(destination)
        }
        guard process.terminationStatus == 0 else {
            return fallbackSSHEndpoint(destination)
        }
        var host: String?
        var port: UInt16 = 22
        for line in String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(whereSeparator: \.isNewline) ?? [] {
            let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            switch fields[0].lowercased() {
            case "hostname": host = fields[1]
            case "port": port = UInt16(fields[1]) ?? port
            default: break
            }
        }
        guard let host, !host.isEmpty, host != "none" else {
            return fallbackSSHEndpoint(destination)
        }
        return (host, port)
    }

    private static func fallbackSSHEndpoint(_ destination: String) -> (host: String, port: UInt16)? {
        let uri = destination.hasPrefix("ssh://") ? destination : "ssh://\(destination)"
        guard let components = URLComponents(string: uri),
              let host = components.host, !host.isEmpty,
              !host.contains("/")
        else { return nil }
        return (host, UInt16(components.port ?? 22))
    }

    private static func connectLatency(
        host: String,
        port: UInt16,
        timeout: TimeInterval
    ) -> Double? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var addresses: UnsafeMutablePointer<addrinfo>?
        let service = String(port)
        let result = host.withCString { hostPointer in
            service.withCString { servicePointer in
                getaddrinfo(hostPointer, servicePointer, &hints, &addresses)
            }
        }
        guard result == 0, let first = addresses else { return nil }
        defer { freeaddrinfo(first) }

        let timeoutMilliseconds = Int32(max(1, min(timeout * 1_000, Double(Int32.max))))
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let address = current {
            let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            guard fd >= 0 else {
                current = address.pointee.ai_next
                continue
            }
            defer { close(fd) }
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                current = address.pointee.ai_next
                continue
            }
            let started = DispatchTime.now().uptimeNanoseconds
            let connected = Darwin.connect(
                fd,
                address.pointee.ai_addr,
                address.pointee.ai_addrlen
            )
            if connected == 0 {
                return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            }
            guard errno == EINPROGRESS else {
                current = address.pointee.ai_next
                continue
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else {
                current = address.pointee.ai_next
                continue
            }
            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                fd,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorLength
            ) == 0, socketError == 0 else {
                current = address.pointee.ai_next
                continue
            }
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }
        return nil
    }

    // MARK: - Silent-forward diagnosis

    /// Explains a forward that answers with silence: ssh accepted the local connection,
    /// failed to open the far side, and closed it, so the first read hit EOF before any
    /// reply. The session itself is fine — the home probe and the tunnel both came up —
    /// which points at the remote end of the forward. One extra round-trip tells the two
    /// cases apart: no socket file (herdr isn't running over there, by far the common
    /// case) vs a socket that exists but stays mute. OpenSSH's own stderr can't be
    /// relied on here: a stock remote sshd reports the failed channel as just
    /// "connect failed: open failed", and when the user's ssh config muxes the
    /// connection (ControlMaster), the message lands on the master's stderr, not ours.
    public func diagnoseSilentForward() async -> HerdrError? {
        guard let remoteSock = try? await remoteSocketPath(),
              let output = try? await Self.runSSH(
                  target: target,
                  command: "test -S \"\(remoteSock)\" && echo exists || echo missing",
                  timeout: 10,
                  credentialID: credentialID,
                  tailscale: tailscale
              )
        else { return nil }
        return Self.silentForwardDiagnosis(
            probeOutput: output,
            target: target,
            remoteSocketPath: remoteSock
        )
    }

    static func silentForwardDiagnosis(
        probeOutput: String,
        target: String,
        remoteSocketPath: String
    ) -> HerdrError? {
        switch probeOutput.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "missing":
            return .remoteHerdrDown(target: target, socketPath: remoteSocketPath)
        case "exists":
            return .tunnelFailed(
                "\(remoteSocketPath) exists on \(target) but forwarded connections get no reply"
                    + " — herdr may have left a stale socket, or sshd forbids Unix-socket"
                    + " forwards (AllowStreamLocalForwarding)"
            )
        default:
            return nil
        }
    }

    /// Sniffs the remote OS: "macos", an os-release ID like "ubuntu"/"debian", or a uname fallback.
    public static func probeOS(
        target: String,
        credentialID: UUID? = nil,
        tailscale: TSNetManager? = nil
    ) async throws -> String {
        let command = """
        case "$(uname -s)" in Darwin) echo macos;; Linux) . /etc/os-release 2>/dev/null; echo "${ID:-linux}";; *) uname -s | tr '[:upper:]' '[:lower:]';; esac
        """
        let output = try await runSSH(
            target: target,
            command: command,
            timeout: 10,
            credentialID: credentialID,
            tailscale: tailscale
        )
        let os = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !os.isEmpty else { throw HerdrError.tunnelFailed("empty OS probe result") }
        return os
    }

    // MARK: - File transfer

    /// Streams one regular file to a private cache on the remote host and returns
    /// its absolute remote path. The generated name preserves only a safe extension.
    public func uploadFile(from localURL: URL) async throws -> String {
        let fileSize = try Self.validateUploadCandidate(localURL)
        return try await Self.uploadFile(
            target: target,
            localURL: localURL,
            remoteFilename: Self.uploadFilename(for: localURL),
            credentialID: credentialID,
            timeout: Self.uploadTimeout(fileSizeBytes: fileSize),
            tailscale: tailscale
        )
    }

    /// Rejects what the upload path cannot stream, and returns the size in bytes.
    @discardableResult
    static func validateUploadCandidate(_ localURL: URL) throws -> Int {
        guard localURL.isFileURL else {
            throw HerdrError.fileTransferFailed("a local file is required")
        }
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw HerdrError.fileTransferFailed("only regular files can be transferred")
        }
        let fileSize = values.fileSize ?? 0
        guard fileSize <= maximumUploadBytes else {
            throw HerdrError.fileTransferFailed(
                "the file is larger than the \(maximumUploadBytes / (1024 * 1024)) MB limit"
            )
        }
        return fileSize
    }

    /// A hard deadline generous enough for a slow link (~256 KB/s) — stalled
    /// sessions are caught much earlier by ServerAlive, not by this watchdog.
    static func uploadTimeout(fileSizeBytes: Int) -> TimeInterval {
        min(600, 30 + Double(fileSizeBytes) / 262_144)
    }

    static func uploadFile(
        target: String,
        localURL: URL,
        remoteFilename: String,
        credentialID: UUID?,
        timeout: TimeInterval = 60,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        tailscale: TSNetManager? = nil
    ) async throws -> String {
        // The name lands inside a remote shell script, so nothing but the
        // generated form of uploadFilename(for:) may reach it.
        guard isSafeRemoteFilename(remoteFilename) else {
            throw HerdrError.fileTransferFailed("unsafe remote filename")
        }
        try await tailscale?.ensureRunning()
        let proxyArguments = Self.proxyArguments(for: tailscale)
        let command = """
        umask 077
        dir="${XDG_CACHE_HOME:-$HOME/.cache}/herdrm/attachments"
        mkdir -p "$dir" && chmod 700 "$dir"
        find "$dir" -type f -mtime +7 -delete 2>/dev/null || true
        tmp="$dir/.\(remoteFilename).part"
        dest="$dir/\(remoteFilename)"
        if cat > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$dest"; then
            printf '%s\\n' "$dest"
        else
            rm -f "$tmp"
            exit 1
        fi
        """

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = executableURL
                let authentication = authenticationConfiguration(for: credentialID)
                defer { authentication.discardAuthorization() }
                proc.arguments = authentication.arguments + proxyArguments + [
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=8",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=4",
                    sshDestination(target),
                    // Under sh explicitly: the login shell may be zsh (where a
                    // `path=` assignment would clobber PATH) or fish (no `var=`
                    // assignments at all).
                    "exec /bin/sh -c \(HerdrService.shellQuoted(command))",
                ]
                proc.environment = ProcessInfo.processInfo.environment.merging(authentication.environment) { _, new in new }
                let output = Pipe()
                let errorOutput = Pipe()
                proc.standardOutput = output
                proc.standardError = errorOutput
                do {
                    proc.standardInput = try FileHandle(forReadingFrom: localURL)
                    try proc.run()
                } catch {
                    continuation.resume(throwing: HerdrError.fileTransferFailed("ssh spawn: \(error.localizedDescription)"))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if proc.isRunning { proc.terminate() }
                }
                proc.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else {
                    let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(throwing: HerdrError.fileTransferFailed(
                        failureReason(status: proc.terminationStatus, stderr: errorData)
                    ))
                    return
                }
                let lines = String(data: data, encoding: .utf8)?
                    .split(whereSeparator: \.isNewline)
                    .map(String.init) ?? []
                guard let remotePath = lines.last(where: { $0.hasPrefix("/") }) else {
                    continuation.resume(throwing: HerdrError.fileTransferFailed("the remote host returned no path"))
                    return
                }
                continuation.resume(returning: remotePath)
            }
        }
    }

    static func uploadFilename(for localURL: URL) -> String {
        let rawExtension = localURL.pathExtension.lowercased()
        let isSafeExtension = !rawExtension.isEmpty
            && rawExtension.utf8.count <= 16
            && rawExtension.utf8.allSatisfy { byte in
                switch byte {
                case 48...57, 97...122: return true
                default: return false
                }
            }
        let suffix = isSafeExtension ? ".\(rawExtension)" : ""
        return "\(UUID().uuidString.lowercased())\(suffix)"
    }

    static func isSafeRemoteFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64, !name.hasPrefix("."), !name.contains("..") else {
            return false
        }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 97...122, UInt8(ascii: "-"), UInt8(ascii: "."): return true
            default: return false
            }
        }
    }

    // MARK: - One-shot exec

    /// Runs a command on the remote host and returns stdout. Used for probes.
    public static func runSSH(
        target: String,
        command: String,
        timeout: TimeInterval,
        credentialID: UUID? = nil,
        tailscale: TSNetManager? = nil
    ) async throws -> String {
        try await tailscale?.ensureRunning()
        let proxyArguments = Self.proxyArguments(for: tailscale)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                let authentication = authenticationConfiguration(for: credentialID)
                defer { authentication.discardAuthorization() }
                proc.arguments = authentication.arguments + proxyArguments + [
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=8",
                    sshDestination(target),
                    command,
                ]
                proc.environment = ProcessInfo.processInfo.environment.merging(authentication.environment) { _, new in new }
                let out = Pipe()
                let errorOutput = Pipe()
                proc.standardOutput = out
                proc.standardError = errorOutput
                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: HerdrError.tunnelFailed("ssh spawn: \(error.localizedDescription)"))
                    return
                }
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if proc.isRunning { proc.terminate() }
                }
                proc.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else {
                    let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(throwing: HerdrError.tunnelFailed(
                        failureReason(status: proc.terminationStatus, stderr: errorData)
                    ))
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    static func proxyArguments(for tailscale: TSNetManager?) -> [String] {
        guard let tailscale else { return [] }
        return ["-o", "ProxyCommand=\(tailscale.proxyCommand)"]
    }

    static func authenticationConfiguration(
        for credentialID: UUID?
    ) -> SSHAuthenticationConfiguration {
        guard let credentialID, let executablePath = Bundle.main.executablePath,
              let authorizationID = try? SSHCredentialStore.createAuthorization(for: credentialID)
        else {
            return SSHAuthenticationConfiguration(
                arguments: ["-o", "BatchMode=yes"],
                environment: [:],
                authorizationID: nil
            )
        }
        return SSHAuthenticationConfiguration(
            arguments: ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"],
            environment: [
                "SSH_ASKPASS": executablePath,
                "SSH_ASKPASS_REQUIRE": "force",
                SSHCredentialStore.askPassModeEnvironmentKey: "1",
                SSHCredentialStore.authorizationIDEnvironmentKey: authorizationID.uuidString,
            ],
            authorizationID: authorizationID
        )
    }

    private static func failureReason(status: Int32, stderr: Data) -> String {
        failureReason(status: status, stderr: String(data: stderr, encoding: .utf8) ?? "")
    }

    private static func failureReason(status: Int32, stderr: String) -> String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return "ssh exited \(status)" }
        return String(detail.suffix(2_000))
    }
}
#endif  // os(macOS)
