//
//  ForwardingDrainTests.swift
//  SwiftMkPipeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkPipe

// MARK: - ForwardingDrainTests

/// Empty namesake type so the SwiftLint `file_name` rule finds a declaration matching the
/// file; the tests are written as free `@Test` functions.
enum ForwardingDrainTests {}

// A payload large enough to span several reader wakeups (well over one 64 KiB pipe buffer),
// so the capture test exercises the append path more than once.
private let largeCapturePayloadByteCount = 204_800
// Generous upper bound for a drain that must complete once the write end closes. The reader
// wakes each poll interval, so end of file is observed within a few hundred milliseconds.
private let finishDeadlineSeconds = 5
// Short bound used where the drain must NOT finish because the write end stays open. It is a
// few poll intervals so a genuine completion would be observed if it happened.
private let boundedWaitMilliseconds = 300
// Time to let the reader wake and read one chunk before the next write, so two writes land as
// two separate reads rather than one coalesced read.
private let interWriteSettleMilliseconds: UInt32 = 100_000

@Test
func capturesEveryByteUntilEndOfFile() throws {
  let pipe = Pipe()
  let drain = ForwardingDrain(handle: pipe.fileHandleForReading, capturing: true)
  let payload = Data((0..<largeCapturePayloadByteCount).map { UInt8($0 & 0xFF) })

  try pipe.fileHandleForWriting.write(contentsOf: payload)
  try pipe.fileHandleForWriting.close()

  let finished = drain.waitUntilFinished(deadline: .now() + .seconds(finishDeadlineSeconds))
  #expect(finished)
  #expect(drain.snapshot() == payload)
  drain.detach()
}

@Test
func waitIsBoundedWhenWriteEndStaysOpen() throws {
  let pipe = Pipe()
  let drain = ForwardingDrain(handle: pipe.fileHandleForReading, capturing: true)
  let payload = Data("partial output\n".utf8)

  // Write a chunk but keep the write end open, so the reader never sees end of file.
  try pipe.fileHandleForWriting.write(contentsOf: payload)

  let finished =
    drain.waitUntilFinished(deadline: .now() + .milliseconds(boundedWaitMilliseconds))
  #expect(!finished)

  // detach() must return promptly by joining the reader; the bytes read before detach stay
  // captured.
  drain.detach()
  #expect(drain.snapshot() == payload)

  try pipe.fileHandleForWriting.close()
}

@Test
func detachFencesAQueuedChunkFromTheSink() throws {
  let pipe = Pipe()
  let released = DispatchSemaphore(value: 0)
  let delivered = DeliveredChunks()
  let firstWriteObserved = DispatchSemaphore(value: 0)

  let drain = ForwardingDrain(handle: pipe.fileHandleForReading, capturing: true) { chunk in
    delivered.append(chunk)
    firstWriteObserved.signal()
    // Block the forwarder on the first delivery so a second chunk stays queued.
    released.wait()
  }

  let firstChunk = Data("first\n".utf8)
  let secondChunk = Data("second\n".utf8)

  // Deliver the first chunk and wait until the sink is blocked inside it.
  try pipe.fileHandleForWriting.write(contentsOf: firstChunk)
  #expect(firstWriteObserved.wait(timeout: .now() + .seconds(finishDeadlineSeconds)) == .success)

  // Queue a second chunk that the blocked forwarder has not dequeued yet.
  usleep(interWriteSettleMilliseconds)
  try pipe.fileHandleForWriting.write(contentsOf: secondChunk)
  usleep(interWriteSettleMilliseconds)

  // The forwarder is blocked on the first chunk, so completion is not reached.
  #expect(
    !drain.waitUntilFinished(deadline: .now() + .milliseconds(boundedWaitMilliseconds)))

  // Fence: detach clears the queued second chunk. The reader is joined; the one in-flight
  // first-chunk write is still blocked on the semaphore.
  drain.detach()
  #expect(delivered.snapshot() == [firstChunk])

  // Release the in-flight write and confirm the fenced second chunk never reaches the sink.
  released.signal()
  usleep(interWriteSettleMilliseconds)
  #expect(delivered.snapshot() == [firstChunk])

  try pipe.fileHandleForWriting.close()
}

// MARK: - DeliveredChunks

/// Thread-safe recorder for the chunks a drain's sink receives.
private final class DeliveredChunks: @unchecked Sendable {
  private let lock = NSLock()
  private var chunks: [Data] = []

  func append(_ chunk: Data) {
    lock.lock()
    chunks.append(chunk)
    lock.unlock()
  }

  func snapshot() -> [Data] {
    lock.lock()
    defer { lock.unlock() }
    return chunks
  }
}
