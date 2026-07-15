//
//  IndexStoreSettle.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import Foundation

#if canImport(Darwin)
  import CoreServices
#endif

// MARK: - IndexStoreSettle

/// Waits for an Xcode index store to finish being written before the dead-code
/// scan reads it.
///
/// Xcode populates the index store as background indexing finishes, which can lag
/// the build command's exit, so a scan run immediately after the build can read a
/// partial store and report phantom unused symbols that clear on a later run.
/// This watches the whole store tree for file writes and returns once no write has
/// landed for a quiet window, or once a maximum wait elapses, so the scan is
/// deterministic without forcing a clean rebuild. On Darwin the watch runs through
/// an `FSEventStream`; on other platforms it polls the tree for a stable
/// fingerprint, since the dead-code scan this debounces never runs off Darwin.
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

  #if canImport(Darwin)
    /// Watches a directory tree for writes and signals once they go quiet. The
    /// FSEvents callback runs on `queue`, which also owns the debounce timer, so
    /// the quiet-window state needs no extra locking.
    final class Watcher {
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
          // Treat a watch-setup failure as a timeout, not a settle: the store may
          // still be mid-write, so the caller should scan the current state rather
          // than trust a false "settled".
          return true
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
          Output.error("deadcode: could not start index store watch")
          FSEventStreamInvalidate(stream)
          FSEventStreamRelease(stream)
          return true
        }
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
  #else
    /// Watches a directory tree for writes and signals once they go quiet by
    /// polling. FSEvents is Darwin-only, so off Darwin the tree is fingerprinted on
    /// an interval and the wait returns once the fingerprint holds still across the
    /// quiet window. The fingerprint records every file's path, size, and
    /// modification time, sorted by path, so it moves whenever the indexer adds,
    /// removes, grows, or rewrites a file. Recording per-file state, not just an
    /// aggregate of (file count, total size, newest mtime), catches a same-size
    /// rewrite of a file that is not the newest in the tree, which an aggregate would
    /// miss and read as settled while writes continue.
    final class Watcher {
      private let quietSeconds: Double
      private let pollIntervalSeconds: Double
      // A semaphore nobody signals, so `wait(timeout:)` is a cancelable poll delay
      // that avoids a bare `sleep` call in production code.
      private let pollTick = DispatchSemaphore(value: 0)

      init(quietSeconds: Double, latencySeconds: Double) {
        self.quietSeconds = quietSeconds
        self.pollIntervalSeconds = max(latencySeconds, Watcher.minimumPollIntervalSeconds)
      }

      private static let minimumPollIntervalSeconds: Double = 0.05

      /// One file's contribution to the tree fingerprint.
      struct FileState: Equatable {
        let relativePath: String
        let size: Int
        let modification: Double
      }

      /// An order-independent, per-file summary of a directory tree's write state.
      struct Fingerprint: Equatable {
        let files: [FileState]
      }

      /// Returns true when the maximum wait elapsed before the writes went quiet.
      func wait(path: String, maxSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(maxSeconds)
        var lastFingerprint = fingerprint(path)
        var lastChange = Date()
        while Date() < deadline {
          _ = pollTick.wait(timeout: .now() + pollIntervalSeconds)
          let current = fingerprint(path)
          if current != lastFingerprint {
            lastFingerprint = current
            lastChange = Date()
          } else if Date().timeIntervalSince(lastChange) >= quietSeconds {
            return false
          }
        }
        return true
      }

      func fingerprint(_ path: String) -> Fingerprint {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: path) else {
          return Fingerprint(files: [])
        }
        var files: [FileState] = []
        for case let relativePath as String in enumerator {
          let fileURL = URL(
            fileURLWithPath: (path as NSString).appendingPathComponent(relativePath))
          let values: URLResourceValues
          do {
            values = try fileURL.resourceValues(
              forKeys: [.fileSizeKey, .contentModificationDateKey])
          } catch {
            continue
          }
          files.append(
            FileState(
              relativePath: relativePath,
              size: values.fileSize ?? 0,
              modification: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        files.sort { $0.relativePath < $1.relativePath }
        return Fingerprint(files: files)
      }
    }
  #endif
}
