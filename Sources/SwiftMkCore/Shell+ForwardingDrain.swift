//
//  Shell+ForwardingDrain.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import Foundation

extension Shell {
  /// Time to wait for the drains to finish after the direct child exits before
  /// giving up and detaching. A descendant may keep an inherited write end open, so
  /// the reader may never see EOF; a blocked sink may keep the forwarder from
  /// flushing. Either way the wait is bounded and detach makes the drain inert.
  static let forwardingDrainGraceMilliseconds = 250

  static func waitForDirectProcess(
    _ process: Process,
    drains: [ForwardingDrain]
  ) -> Int32 {
    process.waitUntilExit()
    let status = process.terminationStatus
    let deadline =
      DispatchTime.now() + .milliseconds(forwardingDrainGraceMilliseconds)
    for drain in drains where !drain.waitUntilFinished(deadline: deadline) {
      // A drain did not finish within the grace: a descendant is holding the pipe
      // open, or a sink is blocked. Detach every drain so none can hang this caller
      // or write to a caller-owned sink after this returns, then stop waiting. The
      // captured bytes are whatever the reader accumulated before this point.
      for unfinishedDrain in drains {
        unfinishedDrain.detach()
      }
      break
    }
    return status
  }
}

// MARK: - ForwardingDrain

/// Reads one pipe and, independently, forwards its bytes to an optional sink.
///
/// The reader runs on the file handle's readability handler: it reads each chunk,
/// appends it to the capture buffer, and hands it to the forwarder. The reader never
/// calls the sink, so a slow or blocked sink cannot stall the reader or keep the pipe
/// from draining. The forwarder, when a sink is configured, runs on its own serial
/// queue and writes each chunk to the sink; if the sink blocks, only that queue
/// blocks.
///
/// Completion, observed through `waitUntilFinished(deadline:)`, is reached when the
/// reader is done and the forwarder has no chunk queued or in flight.
///
/// `detach()` is the fence: it stops the reader, clears the un-forwarded queue, and
/// prevents the forwarder from dequeuing any further chunk. It does not signal completion
/// while a sink write is still running; the forwarder signals it after that write returns.
/// So a caller that waits with `waitUntilFinished(deadline:)` and sees success can safely
/// close a handle it supplied as the sink, because no write is then in flight. On a wedged
/// sink the wait times out instead, and the one in-flight write outlives the caller.
///
/// The primary guarantee is that the caller never hangs: the reader and the completion
/// signal do not depend on the sink starting, and every wait on completion is bounded. A
/// sink can block. `Output.forwardStandardOutput` writes synchronously to standard output,
/// which blocks under downstream backpressure. A blocked sink blocks only its forwarder,
/// not the reader or the caller. `detach()` frees the queued chunks, so a wedged sink
/// retains only the drain object and the one chunk still in its write, which is inherent
/// to a synchronous write that cannot be interrupted and is bounded in practice because
/// the continuous-integration log collector drains standard output and error.
///
/// The reader runs on a dispatch source served by the global thread pool, so heavy pool
/// contention can delay it past the grace in `waitForDirectProcess` and bound capture to
/// what was read by then. Capture-only drains have no forwarder, so a truncated
/// `Shell.run` capture requires the pool to be saturated by unrelated work for longer
/// than the grace, which is rare but possible.
final class ForwardingDrain: @unchecked Sendable {
  private let handle: FileHandle
  private let capturing: Bool
  private let sink: (@Sendable (Data) -> Void)?
  private let finished = DispatchGroup()
  private let sharedGroup: DispatchGroup?
  private let forwarderQueue: DispatchQueue?

  private let stateLock = NSLock()
  private var buffer = Data()
  private var pending: [Data] = []
  private var active = true
  private var readerDone = false
  private var cancelled = false
  private var forwarding = false
  private var completionSignaled = false

  /// - Parameters:
  ///   - capturing: retain every chunk so `snapshot()` returns the full stream.
  ///   - onChunk: the sink, run on a dedicated queue off the reader; nil captures only.
  ///   - sharedGroup: an optional group left once alongside the private one when the
  ///     drain completes, so a caller can wait on several drains together.
  init(
    handle: FileHandle,
    capturing: Bool = false,
    onChunk: (@Sendable (Data) -> Void)? = nil,
    sharedGroup: DispatchGroup? = nil
  ) {
    self.handle = handle
    self.capturing = capturing
    self.sink = onChunk
    self.sharedGroup = sharedGroup
    if onChunk == nil {
      forwarderQueue = nil
    } else {
      forwarderQueue = DispatchQueue(label: "swift-mk.forwarding-drain")
    }
    finished.enter()
    sharedGroup?.enter()
    handle.readabilityHandler = { [weak self] source in
      self?.read(from: source)
    }
  }

  func waitUntilFinished(deadline: DispatchTime) -> Bool {
    finished.wait(timeout: deadline) == .success
  }

  /// Legacy name kept for callers that stop a drain; identical to `detach()`.
  func stop() {
    detach()
  }

  /// Stop the reader and fence the forwarder: no reader callback fires, the queued
  /// chunks are freed, and the forwarder dequeues nothing further after this returns.
  /// At most the one chunk the forwarder already dequeued may still complete its write.
  /// Completion is signaled after that write returns, not here, so it does not fire while
  /// a sink write is in flight. Idempotent.
  func detach() {
    stateLock.lock()
    active = false
    readerDone = true
    cancelled = true
    // Free the un-forwarded queue so a wedged sink cannot retain it indefinitely.
    pending.removeAll()
    handle.readabilityHandler = nil
    let signal = claimCompletionLocked()
    stateLock.unlock()
    if signal {
      leaveGroups()
    }
  }

  func snapshot() -> Data {
    stateLock.lock()
    defer { stateLock.unlock() }
    return buffer
  }

  private func read(from source: FileHandle) {
    // Read outside the lock: the blocking pipe read and the Data allocation must not stall
    // snapshot(), the forwarder's dequeue, or detach().
    let chunk = source.availableData
    stateLock.lock()
    guard active else {
      stateLock.unlock()
      return
    }
    if chunk.isEmpty {
      active = false
      readerDone = true
      source.readabilityHandler = nil
      let signal = claimCompletionLocked()
      stateLock.unlock()
      if signal {
        leaveGroups()
      }
      return
    }
    if capturing {
      buffer.append(chunk)
    }
    if sink != nil {
      pending.append(chunk)
      scheduleForwarderLocked()
    }
    stateLock.unlock()
  }

  /// Start the forwarder if a sink exists, chunks are waiting, and none is running.
  /// Caller holds `stateLock`.
  private func scheduleForwarderLocked() {
    guard !cancelled, !forwarding, let queue = forwarderQueue, let sink else {
      return
    }
    forwarding = true
    queue.async { [weak self] in
      self?.runForwarder(sink)
    }
  }

  private func runForwarder(_ sink: @Sendable (Data) -> Void) {
    while true {
      stateLock.lock()
      if cancelled || pending.isEmpty {
        forwarding = false
        let signal = claimCompletionLocked()
        stateLock.unlock()
        if signal {
          leaveGroups()
        }
        return
      }
      let chunk = pending.removeFirst()
      stateLock.unlock()
      // Outside the lock: a blocking sink stalls only this queue.
      sink(chunk)
    }
  }

  /// Return true exactly once, when the drain has completed: the reader is done and the
  /// forwarder has no chunk queued or in flight. The forwarder check holds even when the
  /// drain is cancelled, so `detach()` does not signal completion while a sink write is
  /// still running; the forwarder signals it after that write returns. Caller holds
  /// `stateLock`.
  private func claimCompletionLocked() -> Bool {
    guard !completionSignaled, readerDone else {
      return false
    }
    if forwarding || !pending.isEmpty {
      return false
    }
    completionSignaled = true
    return true
  }

  private func leaveGroups() {
    finished.leave()
    sharedGroup?.leave()
  }
}
