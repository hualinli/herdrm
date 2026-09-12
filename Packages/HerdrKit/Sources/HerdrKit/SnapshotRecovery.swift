import Foundation

/// Reconciles even when the event stream is silent or a one-off snapshot failed.
/// Returning false means repeated request failures warrant reconnecting the session.
public enum SnapshotRecovery {
    public static func run(
        intervalNanoseconds: UInt64 = 5_000_000_000,
        failureLimit: Int = 2,
        refresh: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        var failures = 0
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: intervalNanoseconds) }
            catch { return true }
            let succeeded = await refresh()
            guard !Task.isCancelled else { return true }
            failures = succeeded ? 0 : failures + 1
            if failures >= failureLimit { return false }
        }
        return true
    }
}
