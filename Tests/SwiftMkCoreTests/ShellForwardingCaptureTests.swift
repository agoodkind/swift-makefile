//
//  ShellForwardingCaptureTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-11.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

// MARK: - ShellForwardingCaptureTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching the
/// file; the tests are written as free `@Test` functions.
enum ShellForwardingCaptureTests {}

@Test
func forwardingAndCapturingReturnsBothStreamsAndStatus() {
  let result = Shell.runForwardingAndCapturing(
    "/bin/sh", ["-c", "printf out; printf err 1>&2; exit 3"])
  #expect(result.status == 3)
  #expect(result.stdout == "out")
  #expect(result.stderr == "err")
  #expect(result.combined == "outerr")
}

@Test
func forwardingAndCapturingReturnsZeroStatusOnSuccess() {
  let result = Shell.runForwardingAndCapturing("/bin/sh", ["-c", "printf done"])
  #expect(result.status == 0)
  #expect(result.combined == "done")
}

@Test(.timeLimit(.minutes(1)))
func forwardingCallsReturnWhenDescendantHoldsPipes() throws {
  let statusPIDURL = descendantPIDURL()
  defer { removeTemporary(statusPIDURL.path) }
  let statusStarted = Date()
  let status = Shell.runForwardingOutput(
    "/bin/sh",
    ["-c", descendantPipeCommand(pidURL: statusPIDURL, marker: "status")])
  let statusElapsed = Date().timeIntervalSince(statusStarted)
  try terminateDescendant(at: statusPIDURL)

  #expect(status == 0)
  #expect(statusElapsed < descendantReturnLimitSeconds)

  let capturedPIDURL = descendantPIDURL()
  defer { removeTemporary(capturedPIDURL.path) }
  let capturedStarted = Date()
  let result = Shell.runForwardingAndCapturing(
    "/bin/sh",
    ["-c", descendantPipeCommand(pidURL: capturedPIDURL, marker: "captured")])
  let capturedElapsed = Date().timeIntervalSince(capturedStarted)
  try terminateDescendant(at: capturedPIDURL)

  #expect(result.status == 0)
  #expect(result.stdout == "captured")
  #expect(capturedElapsed < descendantReturnLimitSeconds)
}

@Test(.timeLimit(.minutes(1)))
func forwardingCapturePreservesFinalOutputAtDeadlineBoundary() throws {
  try TestGlobalLock.withLock {
    for iteration in 0..<finalOutputRaceIterationCount {
      let pidURL = descendantPIDURL()
      defer { removeTemporary(pidURL.path) }
      let marker = "finding-\(iteration)"
      let result = try runDeadlineBoundaryForwardingCapture(
        pidURL: pidURL,
        marker: marker)
      try terminateDescendant(at: pidURL)

      #expect(result.callbackStarted)
      #expect(result.status == 1)
      #expect(result.captured == marker)
      #expect(result.forwarded == marker)
      #expect(result.outputCapture.contains(marker))
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func forwardingStreamingCapturesFloodedStreamsWithoutDeadlock() throws {
  try withForwardingFiles { stdoutURL, stderrURL, stdout, stderr in
    // The shell backgrounds two dd writers and waits for both, so it always exits
    // and closes the pipes, and the drains always reach EOF. Use the plain call
    // without a timeout: a timeout would route through leaderExitedByDeadline,
    // which schedules on the global queue and could falsely report a timeout under
    // the saturated parallel run. The `.timeLimit(.minutes(1))` on the test is the
    // outer backstop.
    let result = Shell.runForwardingAndCapturingStreaming(
      "/bin/sh",
      [
        "-c",
        "dd if=/dev/zero bs=1024 count=200 status=none & "
          + "dd if=/dev/zero of=/dev/stderr bs=1024 count=200 status=none & wait",
      ],
      forwardingStandardOutput: stdout,
      forwardingStandardError: stderr)

    // The produced payload is all zero bytes, so count zero bytes exactly rather
    // than count the total. An exact zero count catches both data loss and any
    // duplication of the payload regardless of load, while a small bound on the
    // non-zero bytes absorbs the few diagnostic bytes the shell and OS write to
    // stderr under load. A total-count band would instead let a duplicated chunk
    // pass as long as it stayed under the slack.
    #expect(result.status == 0)
    let stdoutCounts = zeroAndNoiseCounts(Array(result.stdout.utf8))
    let stderrCounts = zeroAndNoiseCounts(Array(result.stderr.utf8))
    let combinedCounts = zeroAndNoiseCounts(Array(result.combined.utf8))
    #expect(stdoutCounts.zeros == largeForwardingByteCount)
    #expect(stdoutCounts.noise <= floodedStreamsNoiseToleranceBytes)
    #expect(stderrCounts.zeros == largeForwardingByteCount)
    #expect(stderrCounts.noise <= floodedStreamsNoiseToleranceBytes)
    #expect(combinedCounts.zeros == largeForwardingByteCount * 2)
    #expect(combinedCounts.noise <= floodedStreamsNoiseToleranceBytes * 2)
    let forwardedStdoutCounts = zeroAndNoiseCounts(try Data(contentsOf: stdoutURL))
    let forwardedStderrCounts = zeroAndNoiseCounts(try Data(contentsOf: stderrURL))
    #expect(forwardedStdoutCounts.zeros == largeForwardingByteCount)
    #expect(forwardedStdoutCounts.noise <= floodedStreamsNoiseToleranceBytes)
    #expect(forwardedStderrCounts.zeros == largeForwardingByteCount)
    #expect(forwardedStderrCounts.noise <= floodedStreamsNoiseToleranceBytes)
    #expect(!result.timedOut)
  }
}

@Test(.timeLimit(.minutes(1)))
func forwardingStreamingForwardsBothStreamsBeforeExit() throws {
  try withForwardingFiles { stdoutURL, stderrURL, stdout, stderr in
    let stdoutMarker = "live-stdout-\(UUID().uuidString)"
    let stderrMarker = "live-stderr-\(UUID().uuidString)"
    let releaseURL = stdoutURL.deletingLastPathComponent().appendingPathComponent(
      "swift-mk-forwarding-release-\(UUID().uuidString)")
    defer { removeTemporary(releaseURL.path) }
    let finished = DispatchSemaphore(value: 0)
    // Run the streaming call on a dedicated thread, not the global queue, so a
    // saturated global queue under the parallel test run cannot starve it and make
    // the markers never appear.
    Thread.detachNewThread {
      _ = Shell.runForwardingAndCapturingStreaming(
        "/bin/sh",
        [
          "-c",
          "printf '%s' '\(stdoutMarker)'; printf '%s' '\(stderrMarker)' 1>&2; "
            + "while [ ! -e '\(releaseURL.path)' ]; do sleep 0.01; done",
        ],
        forwardingStandardOutput: stdout,
        forwardingStandardError: stderr)
      finished.signal()
    }

    #expect(waitForOutput([stdoutMarker], at: stdoutURL, timeoutSeconds: 5))
    #expect(waitForOutput([stderrMarker], at: stderrURL, timeoutSeconds: 5))
    #expect(finished.wait(timeout: .now()) == .timedOut)
    #expect(FileManager.default.createFile(atPath: releaseURL.path, contents: nil))
    // Block until the streaming call returns so the detached thread cannot outlive
    // this scope and write to the forwarding handles that withForwardingFiles closes
    // on return. The child exits as soon as the release file exists, so this always
    // completes; the bound only guards against a genuine stall. On the unexpected
    // timeout, still block unbounded before returning so the handles never close
    // under a live thread; the outer .timeLimit fails the test if that ever hangs.
    let streamingReturned =
      finished.wait(timeout: .now() + streamingReleaseWaitSeconds) == .success
    #expect(streamingReturned)
    if !streamingReturned {
      finished.wait()
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func forwardingStreamingPreservesCapturedOutputOnTimeout() throws {
  try withForwardingFiles { _, _, stdout, stderr in
    let result = Shell.runForwardingAndCapturingStreaming(
      "/bin/sh",
      ["-c", "printf before; printf error 1>&2; while :; do :; done"],
      forwardingStandardOutput: stdout,
      forwardingStandardError: stderr,
      timeoutSeconds: 0.5)

    #expect(result.timedOut)
    #expect(result.status != 0)
    #expect(result.stdout == "before")
    #expect(result.stderr == "error")
    #expect(result.combined == "beforeerror")
  }
}

private let largeForwardingByteCount = 204_800
// Ceiling on non-zero bytes in the flooded-streams capture. The produced payload is
// all zero bytes, so any non-zero byte is a diagnostic the shell or OS wrote to
// stderr under load. Keep this small so it absorbs the handful of observed
// diagnostic bytes without hiding a larger anomaly; the exact zero-byte count, not
// this value, is what proves no data was lost or duplicated.
private let floodedStreamsNoiseToleranceBytes = 4_096
private let outputPollIntervalSeconds: TimeInterval = 0.01
private let descendantHoldSeconds = 5
private let descendantReturnLimitSeconds: TimeInterval = 2
private let finalCallbackReleaseDelaySeconds: TimeInterval = 0.35
private let finalOutputRaceIterationCount = 24
private let forwardedChunkWaitSeconds: TimeInterval = 1
// Bound for waiting on the streaming call to return after its child is released.
// The child exits as soon as the release file appears, so the wait always
// completes well within this; it exists only to keep a detached streaming thread
// from outliving the scope and writing to handles the test is about to close.
private let streamingReleaseWaitSeconds: TimeInterval = 30

private func descendantPIDURL() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-descendant-\(UUID().uuidString).pid")
}

private func descendantPipeCommand(pidURL: URL, marker: String, status: Int32 = 0) -> String {
  "sleep \(descendantHoldSeconds) & printf '%s' \"$!\" > '\(pidURL.path)'; "
    + "printf '%s' '\(marker)'; exit \(status)"
}

private func terminateDescendant(at pidURL: URL) throws {
  let rawPID = try String(contentsOf: pidURL, encoding: .utf8)
  let pid = try #require(Int32(rawPID))
  _ = kill(pid, SIGTERM)
}

private func deadlineBoundaryCommand(pidURL: URL, exitURL: URL, marker: String) -> String {
  "sleep \(descendantHoldSeconds) & printf '%s' \"$!\" > '\(pidURL.path)'; "
    + "printf '%s' '\(marker)'; "
    + "while [ ! -e '\(exitURL.path)' ]; do sleep 0.01; done; exit 1"
}

// Release the blocked callback from a dedicated thread, not the global queue. The
// callback in onChunk waits on callbackRelease, and this thread leaves it. Under the
// parallel test run the global queue saturates with other tests' blocking waits, so
// an async block here could be starved and never run, which would deadlock the
// callback and hang the drain wait while the caller holds TestGlobalLock. A detached
// thread always gets its own OS thread, so the release cannot be starved. It records
// whether the callback started so the caller can assert the boundary was exercised.
private func startCallbackReleaseThread(
  callbackStarted: DispatchSemaphore,
  callbackStartObserved: AtomicFlag,
  exitURL: URL,
  callbackRelease: DispatchGroup
) {
  Thread.detachNewThread {
    let callbackDidStart =
      callbackStarted.wait(timeout: .now() + forwardedChunkWaitSeconds) == .success
    callbackStartObserved.set(callbackDidStart)
    _ = FileManager.default.createFile(atPath: exitURL.path, contents: nil)
    if callbackDidStart {
      Thread.sleep(forTimeInterval: finalCallbackReleaseDelaySeconds)
    }
    callbackRelease.leave()
  }
}

private func runDeadlineBoundaryForwardingCapture(pidURL: URL, marker: String) throws
  -> BoundedForwardingCaptureResult
{
  let exitURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-forwarding-exit-\(UUID().uuidString)")
  defer { removeTemporary(exitURL.path) }
  let process = Process()
  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [
    "-c",
    deadlineBoundaryCommand(pidURL: pidURL, exitURL: exitURL, marker: marker),
  ]
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe
  let forwarded = TestDataBuffer()
  let callbackStarted = DispatchSemaphore(value: 0)
  let callbackRelease = DispatchGroup()
  let callbackFinished = DispatchSemaphore(value: 0)
  let callbackStartObserved = AtomicFlag()
  callbackRelease.enter()
  let stdoutDrain = ForwardingDrain(
    handle: stdoutPipe.fileHandleForReading,
    capturing: true
  ) { chunk in
    callbackStarted.signal()
    callbackRelease.wait()
    forwarded.append(chunk)
    Output.forwardStandardOutput(chunk)
    callbackFinished.signal()
  }
  let stderrDrain = ForwardingDrain(handle: stderrPipe.fileHandleForReading) { chunk in
    FileHandle.nullDevice.write(chunk)
  }
  Output.beginCapture()
  var captureEnded = false
  defer {
    if !captureEnded {
      _ = Output.endCapture()
    }
  }
  try process.run()
  startCallbackReleaseThread(
    callbackStarted: callbackStarted,
    callbackStartObserved: callbackStartObserved,
    exitURL: exitURL,
    callbackRelease: callbackRelease)
  let status = Shell.waitForDirectProcess(process, drains: [stdoutDrain, stderrDrain])
  let captured = Output.decodeCapturedUTF8(stdoutDrain.snapshot())
  let forwardedOutput = Output.decodeCapturedUTF8(forwarded.snapshot())
  let outputCapture = Output.endCapture()
  captureEnded = true
  _ = callbackFinished.wait(timeout: .now() + forwardedChunkWaitSeconds)
  return BoundedForwardingCaptureResult(
    status: status,
    captured: captured,
    forwarded: forwardedOutput,
    outputCapture: outputCapture,
    callbackStarted: callbackStartObserved.get()
  )
}

private func withForwardingFiles(
  _ body: (URL, URL, FileHandle, FileHandle) throws -> Void
) throws {
  let baseName = "swift-mk-forwarding-\(UUID().uuidString)"
  let stdoutURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "\(baseName)-stdout.log")
  let stderrURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "\(baseName)-stderr.log")
  try #require(FileManager.default.createFile(atPath: stdoutURL.path, contents: nil))
  try #require(FileManager.default.createFile(atPath: stderrURL.path, contents: nil))
  let stdout = try FileHandle(forWritingTo: stdoutURL)
  let stderr = try FileHandle(forWritingTo: stderrURL)
  defer {
    stdout.closeFile()
    stderr.closeFile()
    removeTemporary(stdoutURL.path)
    removeTemporary(stderrURL.path)
  }
  try body(stdoutURL, stderrURL, stdout, stderr)
}

// Split a byte collection into its zero-byte payload count and its non-zero
// diagnostic-noise count. The flooded-streams test produces an all-zero payload, so
// the zero count is the exact transferred payload and the remainder is injected
// noise.
private func zeroAndNoiseCounts(_ bytes: some Sequence<UInt8>) -> (zeros: Int, noise: Int) {
  var zeros = 0
  var noise = 0
  for byte in bytes {
    if byte == 0 {
      zeros += 1
    } else {
      noise += 1
    }
  }
  return (zeros, noise)
}

private func waitForOutput(
  _ markers: [String], at url: URL, timeoutSeconds: TimeInterval
) -> Bool {
  let deadline = Date().addingTimeInterval(timeoutSeconds)
  repeat {
    let output: String
    do {
      output = try String(contentsOf: url, encoding: .utf8)
    } catch {
      Output.error("test: could not read forwarding output at \(url.path): \(error)")
      return false
    }
    if markers.allSatisfy({ output.contains($0) }) {
      return true
    }
    Thread.sleep(forTimeInterval: outputPollIntervalSeconds)
  } while Date() < deadline
  return false
}

// MARK: - BoundedForwardingCaptureResult

private struct BoundedForwardingCaptureResult {
  let status: Int32
  let captured: String
  let forwarded: String
  let outputCapture: String
  // Whether the drain callback started before the release fired. When false the run
  // never exercised the callback-in-flight boundary, so the test must fail rather
  // than pass on a run that proved nothing.
  let callbackStarted: Bool
}

// MARK: - AtomicFlag

/// A thread-safe boolean the deadline-boundary harness sets from its release thread
/// and reads from the test thread.
private final class AtomicFlag: @unchecked Sendable {
  private var value = false
  private let lock = NSLock()

  func set(_ newValue: Bool) {
    lock.lock()
    defer { lock.unlock() }
    value = newValue
  }

  func get() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

// MARK: - TestDataBuffer

private final class TestDataBuffer: @unchecked Sendable {
  private var data = Data()
  private let lock = NSLock()

  func append(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }
    data.append(chunk)
  }

  func snapshot() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}
