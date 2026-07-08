# OfflineSyncKit Demo

A small SwiftUI app that puts [OfflineSyncKit](https://github.com/rajatslakhina/offline-sync-kit)'s write-ahead sync queue on screen: two simulated devices ("iPhone" and "iPad") edit a shared grocery list while offline, and tapping **Sync Now** drains the queue against a simulated flaky server — showing accepted writes, genuine vector-clock conflicts getting merged, and (every fourth sync) a transient failure working through retry and, eventually, the dead-letter queue.

## Why this matters

A conflict-resolution engine is only convincing once you can watch it resolve a conflict. This app exists to make `OfflineSyncKit`'s three headline behaviors — concurrent-write merge, retry backoff, dead-letter routing — visible and interactive in under a minute, not just provable in a test file.

## How it's built

- `Demo.xcodeproj` is a real Xcode project, **not** a Swift Package executable target — see the library README for why that pattern crashes on launch.
- It depends on `OfflineSyncKit` via an `XCRemoteSwiftPackageReference` pointed at the library's real GitHub URL (branch `main`), exactly like any external consumer of the package would — not a local/relative path.
- `Demo/DemoApp.swift` wires up a `SimulatedServer` (a tiny `SyncNetworkClient` that lives only in this demo app, standing in for a real backend) and a `SyncEngine` configured with `VectorClockMergeStrategy`, then drives it from a single SwiftUI view.

## How to run it

1. Clone this repo.
2. Open `Demo.xcodeproj` in Xcode.
3. Let Xcode resolve the remote `OfflineSyncKit` package dependency (Xcode does this automatically on first open; if it doesn't, use File → Packages → Resolve Package Versions).
4. Select the `Demo` scheme and any iOS Simulator, then Build & Run.
5. Tap "Edit from iPhone" and "Edit from iPad" a few times, then tap **Sync Now** to watch the queue drain, a conflict get merged into the simulated server's state, and (roughly every fourth sync) a simulated transient failure move through retry.

## Verification status — stated honestly

This repo was built and pushed by an unattended scheduled pipeline run. Computer-use (the ability to click and drive Xcode/Simulator on the host Mac) is categorically unavailable during scheduled/unattended runs on this platform — a live `request_access` call during this run returned an explicit "can't be approved during a scheduled run" response, not a skip-by-choice. That means **this build has not yet been confirmed to launch on Simulator, and the screenshots referenced by the task template are not yet captured or embedded.**

In place of a live run, this run did: a scripted brace/paren/bracket balance check on `Demo.xcodeproj/project.pbxproj` (balanced) and on `Demo/DemoApp.swift` (balanced), a scripted scan for unguarded force-unwraps in the demo source (none found), and a full manual read-through against the same crash classes the library itself is tested against — bounds-checked collection access (`ForEach` over `Identifiable` arrays only, dictionary iteration always via `.sorted(by:)` for stable, safe ordering), no retain cycles (the view model is a plain `@Observable` class held by `@State`, with no back-reference to the view), and guarded empty states for every list (`pendingActions.isEmpty`, `serverGroceryList.isEmpty`, `log.isEmpty` each render an explicit empty-state row instead of an empty list).

The honest next step, for a human running this on the actual Mac: open `Demo.xcodeproj`, run it on a Simulator, and — if it behaves as designed — add real screenshots to `Demo/Screenshots/` and embed them here. This section will be updated once that happens; it is not being overwritten with a false claim in the meantime.

## Library

Depends on [`offline-sync-kit`](https://github.com/rajatslakhina/offline-sync-kit) — write-ahead queue, last-write-wins + vector-clock CRDT conflict resolution, exponential backoff retry, and a dead-letter queue.
