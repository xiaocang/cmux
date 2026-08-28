import Foundation
import os

// The termination snapshot is synchronous, so retain the last asynchronously
// validated livesh ids behind a tiny lock instead of blocking quit on liveshctl.
private nonisolated let liveShellSessionIDCache = OSAllocatedUnfairLock(initialState: Set<String>())

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> ProcessDetectedResumeIndexes {
        let knownLiveShellSessionIDs: Set<String>
        if let sessions = try? await LiveShellControl.list() {
            knownLiveShellSessionIDs = Set(sessions.lazy.filter { $0.status == .running }.map(\.id))
            liveShellSessionIDCache.withLock { $0 = knownLiveShellSessionIDs }
        } else {
            knownLiveShellSessionIDs = liveShellSessionIDCache.withLock { $0 }
        }
        return await Task.detached(priority: .utility) {
            loadSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                maximumSnapshotAge: 5,
                knownLiveShellSessionIDs: knownLiveShellSessionIDs
            )
        }.value
    }

    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        maximumSnapshotAge: TimeInterval? = nil,
        knownLiveShellSessionIDs: Set<String>? = nil
    ) -> ProcessDetectedResumeIndexes {
        let knownLiveShellSessionIDs = knownLiveShellSessionIDs
            ?? liveShellSessionIDCache.withLock { $0 }
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = if let maximumSnapshotAge {
            CmuxTopProcessSnapshot.captureCached(includeProcessDetails: true, maximumAge: maximumSnapshotAge)
        } else {
            CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        }
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        let restorableAgentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt,
            knownLiveShellSessionIDs: knownLiveShellSessionIDs
        )
        return ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
        )
    }
}
