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
/// reader sees end of file and the forwarder has flushed everything read before then.
///
/// `detach()` is the fence: it stops the reader, clears the un-forwarded queue, and
/// prevents the forwarder from dequeuing any further chunk. At most one chunk survives
/// the fence: a chunk the forwarder already removed from the queue under the lock, whose
/// sink write is in flight or about to start. That write completes, because a
/// synchronous write cannot be interrupted. The production sinks are standard output
/// and standard error, which stay open for the process lifetime and do not block on a
/// wedge, so that one surviving write is always safe. A caller that supplies its own
/// closable handle as the sink must keep it open until the drain completes.
///
/// Overflow: if the sink wedges, the forwarder blocks only itself while the reader keeps
/// draining into the capture buffer, bounded by the child's total output, the same bound
/// a full capture already accepts. On `detach()` the untransmitted tail is dropped and
/// the queued chunks are freed. Standard output and standard error are not made
/// non-blocking, because those descriptors are shared process wide.
///
/// The reader runs on a dispatch source served by the global thread pool. A forwarder
/// whose sink blocks holds one pool thread; the production sinks never block, so the
/// reader is never starved and capture is complete. Only a pathological number of
/// concurrently wedged sinks could delay the reader past the grace in
/// `waitForDirectProcess`, which would bound capture to what was read by then; that does
/// not occur in production.
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
  /// Idempotent.
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
    stateLock.lock()
    guard active else {
      stateLock.unlock()
      return
    }
    let chunk = source.availableData
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

  /// Return true exactly once, when the drain has completed: the reader is done and,
  /// unless the drain was cancelled, the forwarder has flushed every pending chunk.
  /// Caller holds `stateLock`.
  private func claimCompletionLocked() -> Bool {
    guard !completionSignaled, readerDone else {
      return false
    }
    if !cancelled, forwarding || !pending.isEmpty {
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
