//
//  IndexStoreSettle.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import CoreServices
import Foundation

// MARK: - IndexStoreSettle

/// Waits for an Xcode index store to finish being written before the dead-code
/// scan reads it.
///
/// Xcode populates the index store as background indexing finishes, which can lag
/// the build command's exit, so a scan run immediately after the build can read a
/// partial store and report phantom unused symbols that clear on a later run.
/// This watches the whole store tree for file writes through an `FSEventStream`
/// and returns once no write has landed for a quiet window, or once a maximum
/// wait elapses, so the scan is deterministic without forcing a clean rebuild.
public enum IndexStoreSettle {
    private static let maxSeconds: Double = 180
    private static let quietSeconds: Double = 5
    private static let eventLatencySeconds: Double = 0.5

    /// Block until the index store at `indexStorePath` stops being written.
    /// `SWIFT_MK_DEADCODE_INDEX_SETTLE_SECONDS` overrides the maximum wait.
    public static func waitForStable(_ indexStorePath: String) {
        let watcher = Watcher(quietSeconds: quietSeconds, latencySeconds: eventLatencySeconds)
        let timedOut = watcher.wait(path: indexStorePath, maxSeconds: maxWaitSeconds())
        if timedOut {
            Output.info("deadcode: index store settle timed out, scanning current state")
        } else {
            Output.info("deadcode: index store settled")
        }
    }

    private static func maxWaitSeconds() -> Double {
        let raw = Env.get("SWIFT_MK_DEADCODE_INDEX_SETTLE_SECONDS")
        if let parsed = Double(raw), parsed > 0 {
            return parsed
        }
        return maxSeconds
    }

    /// Watches a directory tree for writes and signals once they go quiet. The
    /// FSEvents callback runs on `queue`, which also owns the debounce timer, so
    /// the quiet-window state needs no extra locking.
    private final class Watcher {
        private let queue = DispatchQueue(label: "swift-mk.index-settle")
        private let settled = DispatchSemaphore(value: 0)
        private let quietSeconds: Double
        private let latencySeconds: Double
        private var quietTimer: DispatchWorkItem?

        init(quietSeconds: Double, latencySeconds: Double) {
            self.quietSeconds = quietSeconds
            self.latencySeconds = latencySeconds
        }

        /// Returns true when the maximum wait elapsed before the writes went quiet.
        func wait(path: String, maxSeconds: Double) -> Bool {
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else {
                    return
                }
                Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue().onActivity()
            }
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
            guard
                let stream = FSEventStreamCreate(
                    kCFAllocatorDefault,
                    callback,
                    &context,
                    [path] as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    latencySeconds,
                    flags)
            else {
                Output.error("deadcode: could not watch index store for settling")
                return false
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            queue.async { [weak self] in self?.restartQuietWindow() }

            let outcome = settled.wait(timeout: .now() + maxSeconds)

            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return outcome == .timedOut
        }

        func onActivity() {
            restartQuietWindow()
        }

        private func restartQuietWindow() {
            quietTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in self?.settled.signal() }
            quietTimer = timer
            queue.asyncAfter(deadline: .now() + quietSeconds, execute: timer)
        }
    }
}
