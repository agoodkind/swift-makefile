//
//  Shell+ForwardingDrain.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

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
/// The reader runs on its own thread. It waits for the pipe to become readable with a
/// bounded `poll`, reads each chunk, appends it to the capture buffer, and hands it to
/// the forwarder. A dedicated thread is scheduled by the operating system, not the
/// global dispatch pool, so heavy pool contention cannot starve it and truncate a
/// capture. The reader never calls the sink, so a slow or blocked sink cannot stall the
/// reader or keep the pipe from draining. The forwarder, when a sink is configured, runs
/// on its own serial queue and writes each chunk to the sink; if the sink blocks, only
/// that queue blocks.
///
/// The `poll` timeout lets `detach()` stop the reader by setting a flag the reader checks
/// each timeout, so the reader exits within one poll interval without closing the
/// descriptor. When the descriptor's owner closes it, `poll` reports the invalid
/// descriptor and the reader treats it as end of file.
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
final class ForwardingDrain: @unchecked Sendable {
  private let handle: FileHandle
  private let capturing: Bool
  private let sink: (@Sendable (Data) -> Void)?
  private let finished = DispatchGroup()
  private let sharedGroup: DispatchGroup?
  private let forwarderQueue: DispatchQueue?

  // Read granularity, one pipe buffer on macOS. The reader reads at most this many bytes
  // per wakeup.
  private static let readerBufferSize = 65_536
  // How long each `poll` waits before the reader rechecks for cancellation. It bounds how
  // long `detach()` takes to stop a reader that is waiting on a pipe no one is writing to.
  private static let readerPollTimeoutMilliseconds: Int32 = 100
  // Reader thread stack, 512 KiB. The reader only holds a fixed read buffer, so the default
  // 512 KiB is ample and keeps the per-drain footprint small.
  private static let readerThreadStackSize = 524_288
  // Upper bound on how long detach() waits to join the reader. The reader observes
  // cancellation within one poll interval, so this is never reached in practice; it only
  // keeps detach() bounded if the reader is somehow stuck.
  private static let readerJoinTimeoutMilliseconds = 2_000

  // Signaled once when the reader thread exits, so detach() can join it before anything
  // closes the descriptor.
  private let readerExited = DispatchSemaphore(value: 0)

  private let stateLock = NSLock()
  private var buffer = Data()
  private var pending: [Data] = []
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
    let reader = Thread { [weak self] in
      self?.readLoop()
    }
    reader.name = "swift-mk.forwarding-drain.reader"
    reader.stackSize = Self.readerThreadStackSize
    reader.start()
  }

  func waitUntilFinished(deadline: DispatchTime) -> Bool {
    finished.wait(timeout: deadline) == .success
  }

  /// Legacy name kept for callers that stop a drain; identical to `detach()`.
  func stop() {
    detach()
  }

  /// Stop the reader and fence the forwarder: the reader appends nothing further and exits
  /// within one poll interval, the queued chunks are freed, and the forwarder dequeues
  /// nothing further after this returns. At most the one chunk the forwarder already
  /// dequeued may still complete its write. Completion is signaled after that write
  /// returns, not here, so it does not fire while a sink write is in flight. Idempotent.
  func detach() {
    stateLock.lock()
    if cancelled {
      stateLock.unlock()
      return
    }
    cancelled = true
    // Free the un-forwarded queue so a wedged sink cannot retain it indefinitely.
    pending.removeAll()
    stateLock.unlock()
    // Join the reader so nothing closes the descriptor while it is still polling or
    // reading. The reader observes `cancelled` within one poll interval and signals its
    // exit; the wait is bounded in case the reader is somehow stuck.
    _ = readerExited.wait(
      timeout: .now() + .milliseconds(Self.readerJoinTimeoutMilliseconds))
    stateLock.lock()
    readerDone = true
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

  private enum PollOutcome {
    case readable
    case keepWaiting
    case stop
  }

  private func readLoop() {
    let fileDescriptor = handle.fileDescriptor
    var readBuffer = [UInt8](repeating: 0, count: Self.readerBufferSize)
    reading: while true {
      switch pollForReadable(fileDescriptor) {
      case .keepWaiting:
        continue reading
      case .stop:
        break reading
      case .readable:
        if !readAndStore(fileDescriptor, into: &readBuffer) {
          break reading
        }
      }
    }
    finishReader()
  }

  /// Wait one poll interval for the descriptor to become readable. Return `.stop` when the
  /// drain was cancelled during an idle interval or the poll failed, `.keepWaiting` on a
  /// bare timeout or an interrupted poll, and `.readable` when data is available.
  private func pollForReadable(_ fileDescriptor: Int32) -> PollOutcome {
    var descriptor = pollfd(
      fd: fileDescriptor, events: Int16(truncatingIfNeeded: POLLIN), revents: 0)
    let ready = poll(&descriptor, 1, Self.readerPollTimeoutMilliseconds)
    if ready < 0 {
      // A non-EINTR poll error stops the reader. An interrupted poll rechecks
      // cancellation so repeated signals cannot keep the reader past detach().
      if errno != EINTR {
        return .stop
      }
      return isCancelled() ? .stop : .keepWaiting
    }
    if ready == 0 {
      return isCancelled() ? .stop : .keepWaiting
    }
    return .readable
  }

  /// Read one chunk and store it. Return false to stop the reader: end of file, a read
  /// error such as the owner closing the descriptor, or a cancellation observed while
  /// storing. Return true to keep reading.
  private func readAndStore(_ fileDescriptor: Int32, into readBuffer: inout [UInt8]) -> Bool {
    // Read outside the lock so the read and the Data allocation do not stall snapshot(),
    // the forwarder's dequeue, or detach().
    let count = readBuffer.withUnsafeMutableBytes { raw in
      read(fileDescriptor, raw.baseAddress, raw.count)
    }
    if count > 0 {
      return storeChunk(Data(readBuffer[0..<count]))
    }
    if count < 0, errno == EINTR {
      return true
    }
    return false
  }

  /// Append a chunk under the lock and hand it to the forwarder. Return false when the
  /// drain was cancelled, so the reader stops without storing after `detach()`.
  private func storeChunk(_ chunk: Data) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    if cancelled {
      return false
    }
    if capturing {
      buffer.append(chunk)
    }
    if sink != nil {
      pending.append(chunk)
      scheduleForwarderLocked()
    }
    return true
  }

  private func isCancelled() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return cancelled
  }

  private func finishReader() {
    stateLock.lock()
    readerDone = true
    let signal = claimCompletionLocked()
    stateLock.unlock()
    if signal {
      leaveGroups()
    }
    // Signal last, so a detach() joining here sees the reader fully done.
    readerExited.signal()
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
