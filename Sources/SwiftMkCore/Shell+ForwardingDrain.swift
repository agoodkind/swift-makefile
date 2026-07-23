//
//  Shell+ForwardingDrain.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import Foundation

extension Shell {
  /// Time for pipe readers to consume bytes already in flight after the direct
  /// child exits. Descendants may keep inherited write ends open indefinitely.
  private static let forwardingDrainGraceMilliseconds = 250

  static func waitForDirectProcess(
    _ process: Process,
    drains: [ForwardingDrain]
  ) -> Int32 {
    process.waitUntilExit()
    let status = process.terminationStatus
    let deadline =
      DispatchTime.now() + .milliseconds(forwardingDrainGraceMilliseconds)
    for drain in drains where !drain.waitUntilFinished(deadline: deadline) {
      for unfinishedDrain in drains {
        unfinishedDrain.stop()
      }
      for unfinishedDrain in drains {
        unfinishedDrain.waitUntilFinished()
      }
      break
    }
    return status
  }
}

// MARK: - ForwardingDrain

/// Reads one pipe concurrently, optionally retaining its bytes. The direct child
/// exit path can stop the reader when a descendant keeps the write end open.
final class ForwardingDrain: @unchecked Sendable {
  private var buffer = Data()
  private let capturing: Bool
  private let finished = DispatchGroup()
  private let handle: FileHandle
  private let onChunk: @Sendable (Data) -> Void
  private let stateLock = NSLock()
  private var active = true
  private var completionSignaled = false
  private var inFlightCallbackCount = 0

  init(
    handle: FileHandle,
    capturing: Bool = false,
    onChunk: @escaping @Sendable (Data) -> Void
  ) {
    self.capturing = capturing
    self.handle = handle
    self.onChunk = onChunk
    finished.enter()
    handle.readabilityHandler = { [weak self] source in
      self?.read(from: source)
    }
  }

  func waitUntilFinished(deadline: DispatchTime) -> Bool {
    finished.wait(timeout: deadline) == .success
  }

  func waitUntilFinished() {
    finished.wait()
  }

  func stop() {
    finish(handle)
  }

  func snapshot() -> Data {
    stateLock.lock()
    defer { stateLock.unlock() }
    return buffer
  }

  private func read(from source: FileHandle) {
    // Register each callback under the same lock as stop, then forward outside
    // the lock so completion cannot overtake an already-read chunk.
    stateLock.lock()
    guard active else {
      stateLock.unlock()
      return
    }
    let chunk = source.availableData
    guard !chunk.isEmpty else {
      active = false
      let shouldSignalCompletion = claimCompletionIfReady()
      stateLock.unlock()
      source.readabilityHandler = nil
      if shouldSignalCompletion {
        finished.leave()
      }
      return
    }
    if capturing {
      buffer.append(chunk)
    }
    inFlightCallbackCount += 1
    stateLock.unlock()
    defer { completeCallback() }
    onChunk(chunk)
  }

  private func finish(_ source: FileHandle) {
    stateLock.lock()
    active = false
    let shouldSignalCompletion = claimCompletionIfReady()
    stateLock.unlock()
    source.readabilityHandler = nil
    if shouldSignalCompletion {
      finished.leave()
    }
  }

  private func completeCallback() {
    stateLock.lock()
    inFlightCallbackCount -= 1
    let shouldSignalCompletion = claimCompletionIfReady()
    stateLock.unlock()
    if shouldSignalCompletion {
      finished.leave()
    }
  }

  private func claimCompletionIfReady() -> Bool {
    guard !active, inFlightCallbackCount == 0, !completionSignaled else {
      return false
    }
    completionSignaled = true
    return true
  }
}
