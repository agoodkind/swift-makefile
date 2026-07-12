//
//  IndexStoreSettleTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-11.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - IndexStoreSettleTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `IndexStoreSettleTests.swift`; the suite is written as free `@Test` functions.
enum IndexStoreSettleTests {}

@Test(.timeLimit(.minutes(1)))
func indexStoreSettleReportsSettledAfterWritesStop() throws {
  let directory = try makeSettleDirectory()
  defer { removeTemporary(directory.path) }

  // A brief burst of writes, then silence: the watcher must ride out the burst and
  // then report settled once the quiet window passes, not time out.
  let writer = SettleTreeWriter(directory: directory)
  writer.start(intervalSeconds: 0.1, count: 6)
  defer { writer.stop() }

  let watcher = IndexStoreSettle.Watcher(quietSeconds: 0.4, latencySeconds: 0.1)
  let timedOut = watcher.wait(path: directory.path, maxSeconds: 10)

  #expect(!timedOut)
}

@Test(.timeLimit(.minutes(1)))
func indexStoreSettleTimesOutWhileWritesContinue() throws {
  let directory = try makeSettleDirectory()
  defer { removeTemporary(directory.path) }

  // Continuous writes never let the quiet window close, so the wait must reach its
  // maximum and report a timeout.
  let writer = SettleTreeWriter(directory: directory)
  writer.start(intervalSeconds: 0.1, count: Int.max)
  defer { writer.stop() }

  let watcher = IndexStoreSettle.Watcher(quietSeconds: 0.5, latencySeconds: 0.1)
  let timedOut = watcher.wait(path: directory.path, maxSeconds: 1.5)

  #expect(timedOut)
}

private func makeSettleDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-index-settle-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

// MARK: - SettleTreeWriter

/// Writes a fresh file into `directory` on an interval from a background thread so
/// the watched tree keeps changing, and stops on request. Every tick creates a new
/// file, so both the FSEvents and the polling watcher observe the tree change.
private final class SettleTreeWriter: @unchecked Sendable {
  private let directory: URL
  private let lock = NSLock()
  private var stopped = false

  init(directory: URL) {
    self.directory = directory
  }

  func start(intervalSeconds: Double, count: Int) {
    let thread = Thread { [directory] in
      var index = 0
      while index < count {
        self.lock.lock()
        let shouldStop = self.stopped
        self.lock.unlock()
        if shouldStop {
          return
        }
        let fileURL = directory.appendingPathComponent("settle-\(index).txt")
        do {
          try Data("\(index)".utf8).write(to: fileURL)
        } catch {
          break
        }
        index += 1
        Thread.sleep(forTimeInterval: intervalSeconds)
      }
    }
    thread.start()
  }

  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
  }
}
