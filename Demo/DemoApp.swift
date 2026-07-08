import SwiftUI
import OfflineSyncKit

/// Simulates a remote server so the demo can show a *real* concurrent
/// conflict (two "devices" editing the same grocery list entity while
/// offline) getting merged when they both come back online — not a
/// canned/staged result.
///
/// This class intentionally lives in the demo app, not the library: the
/// library only needs to know about `SyncNetworkClient`, and a real app
/// would talk to an actual backend here instead.
final class SimulatedServer: SyncNetworkClient, @unchecked Sendable {

    private var records: [String: RemoteRecord] = [:]
    /// Deliberately fails every Nth push so the demo can also show the
    /// retry -> dead-letter path, not just the happy/conflict paths.
    private var pushCount = 0
    private let failEveryNth: Int?

    init(failEveryNth: Int? = nil) {
        self.failEveryNth = failEveryNth
    }

    func push(_ action: SyncAction) async -> SyncPushResult {
        pushCount += 1
        if let failEveryNth, failEveryNth > 0, pushCount % failEveryNth == 0 {
            return .transientFailure(URLError(.notConnectedToInternet))
        }

        guard let existing = records[action.entityID] else {
            records[action.entityID] = RemoteRecord(
                entityID: action.entityID, payload: action.payload,
                updatedAt: action.createdAt, deviceID: action.deviceID, clock: action.clock
            )
            return .accepted
        }

        switch action.clock.compare(to: existing.clock) {
        case .after, .equal:
            records[action.entityID] = RemoteRecord(
                entityID: action.entityID, payload: action.payload,
                updatedAt: action.createdAt, deviceID: action.deviceID, clock: action.clock
            )
            return .accepted
        case .before, .concurrent:
            return .conflict(existing)
        }
    }

    /// After a merged action is re-pushed and accepted, this lets the demo
    /// UI show the server's final, merged state.
    func currentRecord(for entityID: String) -> RemoteRecord? {
        records[entityID]
    }
}

@MainActor
@Observable
final class DemoViewModel {

    private let store = InMemoryActionQueueStore()
    private let server: SimulatedServer
    private let engine: SyncEngine

    private(set) var pendingActions: [SyncAction] = []
    private(set) var deadLetterCount = 0
    private(set) var log: [String] = []
    private(set) var serverGroceryList: [String: String] = [:]

    /// device-local vector clocks, one per simulated device, so repeated
    /// taps genuinely advance causal history instead of reusing a stale
    /// clock value.
    private var iPhoneClock = VectorClock()
    private var iPadClock = VectorClock()

    init() {
        // failEveryNth: 4 so a handful of demo taps will genuinely exercise
        // the retry -> dead-letter path without every sync failing.
        let server = SimulatedServer(failEveryNth: 4)
        self.server = server
        self.engine = SyncEngine(
            store: store,
            network: server,
            conflictStrategy: VectorClockMergeStrategy(),
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0.1, maxDelay: 0.5)
        )
    }

    func editFromiPhone(field: String, value: String) async {
        iPhoneClock = iPhoneClock.incrementing("iPhone")
        let action = SyncAction(
            entityID: "grocery-list", kind: .update, payload: [field: value],
            deviceID: "iPhone", clock: iPhoneClock
        )
        await engine.enqueue(action)
        log.insert("📱 iPhone queued: \(field) = \(value)", at: 0)
        await refreshPending()
    }

    func editFromiPad(field: String, value: String) async {
        iPadClock = iPadClock.incrementing("iPad")
        let action = SyncAction(
            entityID: "grocery-list", kind: .update, payload: [field: value],
            deviceID: "iPad", clock: iPadClock
        )
        await engine.enqueue(action)
        log.insert("💻 iPad queued: \(field) = \(value)", at: 0)
        await refreshPending()
    }

    func sync() async {
        let summary = await engine.drain()
        if !summary.synced.isEmpty {
            log.insert("✅ Synced \(summary.synced.count) action(s)", at: 0)
        }
        if !summary.retried.isEmpty {
            log.insert("🔁 Retrying \(summary.retried.count) action(s) after transient failure", at: 0)
        }
        if !summary.deadLettered.isEmpty {
            log.insert("💀 \(summary.deadLettered.count) action(s) moved to dead-letter queue", at: 0)
        }
        if summary.synced.isEmpty && summary.retried.isEmpty && summary.deadLettered.isEmpty {
            log.insert("· Nothing to sync", at: 0)
        }

        if let record = server.currentRecord(for: "grocery-list") {
            serverGroceryList = record.payload
        }
        deadLetterCount = await engine.deadLetteredEntries().count
        await refreshPending()
    }

    private func refreshPending() async {
        pendingActions = await store.all()
    }
}

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var viewModel = DemoViewModel()
    @State private var counter = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Simulated server state") {
                    if viewModel.serverGroceryList.isEmpty {
                        Text("No sync yet")
                            .foregroundStyle(.secondary)
                    } else {
                        // Sorted so SwiftUI's diffing is stable across
                        // re-renders instead of relying on dictionary order.
                        ForEach(viewModel.serverGroceryList.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            LabeledContent(key, value: value)
                        }
                    }
                }

                Section("Offline write-ahead queue (\(viewModel.pendingActions.count) pending)") {
                    if viewModel.pendingActions.isEmpty {
                        Text("Queue is empty")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.pendingActions) { action in
                            VStack(alignment: .leading) {
                                Text("\(action.deviceID) · attempt \(action.attemptCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(action.payload.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                            }
                        }
                    }
                }

                Section("Dead-letter queue") {
                    Text("\(viewModel.deadLetterCount) permanently failed action(s)")
                        .foregroundStyle(viewModel.deadLetterCount > 0 ? .red : .secondary)
                }

                Section("Actions") {
                    Button("Edit from iPhone: add \"milk\"") {
                        counter += 1
                        Task { await viewModel.editFromiPhone(field: "item-\(counter)", value: "milk") }
                    }
                    Button("Edit from iPad: add \"eggs\"") {
                        counter += 1
                        Task { await viewModel.editFromiPad(field: "item-\(counter)", value: "eggs") }
                    }
                    Button("Sync Now") {
                        Task { await viewModel.sync() }
                    }
                    .bold()
                }

                Section("Activity log") {
                    if viewModel.log.isEmpty {
                        Text("No activity yet")
                            .foregroundStyle(.secondary)
                    } else {
                        // Bounded so a long demo session doesn't render an
                        // unbounded, ever-growing list.
                        ForEach(Array(viewModel.log.prefix(20).enumerated()), id: \.offset) { _, entry in
                            Text(entry).font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("OfflineSyncKit Demo")
        }
    }
}
