import Foundation

// The runner appends the three production scheduling methods from AppModel.
// Only the snapshot operation is replaced with a controlled fake.
@MainActor
final class StatusRefreshProbe {
    var refreshDebounces: [UUID: Task<Void, Never>] = [:]
    var refreshDebounceTokens: [UUID: UUID] = [:]
    var refreshDebouncePending: Set<UUID> = []
    var snapshotRefreshTasks: [UUID: Task<Bool, Never>] = [:]
    var snapshotRefreshTokens: [UUID: UUID] = [:]
    var refreshRequested: Set<UUID> = []
    var completed = 0
    var active = 0
    var maxActive = 0
    var requestDelay: UInt64 = 30_000_000
    func performRefresh(_ id: UUID) async -> Bool {
        active += 1
        maxActive = max(maxActive, active)
        try? await Task.sleep(nanoseconds: requestDelay)
        active -= 1
        completed += 1
        return true
    }
    // PRODUCTION_METHODS
}

@main
struct StatusRefreshTests {
    @MainActor static func main() async throws {
        let busy = StatusRefreshProbe()
        let id = UUID()
        for _ in 0..<30 {
            busy.scheduleRefresh(id)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(busy.completed >= 3, "continuous events starved snapshots")
        try await Task.sleep(nanoseconds: 600_000_000)
        precondition(busy.refreshDebounces.isEmpty, "trailing refresh failed to drain")
        precondition(busy.maxActive == 1, "snapshots overlapped during event bursts")

        let slow = StatusRefreshProbe()
        slow.requestDelay = 150_000_000
        let first = Task { await slow.refresh(id) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = Task { await slow.refreshImmediately(id) }
        let third = Task { await slow.refresh(id) }
        _ = await (first.value, second.value, third.value)
        precondition(slow.completed == 2, "requests during a snapshot need one follow-up snapshot")
        precondition(slow.maxActive == 1, "manual and event snapshots overlapped")
        precondition(slow.snapshotRefreshTasks.isEmpty, "completed snapshot left a stale task")
        print("PASS: continuous events refresh before quiet; trailing work drains; concurrent requests serialize and reconcile")
    }
}
