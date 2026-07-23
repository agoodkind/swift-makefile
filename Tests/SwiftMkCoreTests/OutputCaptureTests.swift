//
//  OutputCaptureTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-06.
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

// MARK: - OutputCaptureTests

@Suite(.serialized)
enum OutputCaptureTests {
  @Test
  static func captureCollectsUserFacingOutputAndThenRestoresStdout() throws {
    try TestGlobalLock.withLock {
      let saved = Environment.snapshot(["SWIFT_MK_LOG_LEVEL"])
      defer { saved.restore() }

      setenv("SWIFT_MK_LOG_LEVEL", "notice", 1)
      Output.beginCapture()
      Output.log("captured stdout")
      Output.emitStandardOutput("raw stdout")
      Output.logError("captured stderr")
      Output.notice("captured notice")
      let captured = Output.endCapture()

      #expect(
        captured
          == "captured stdout\n"
          + "raw stdout"
          + "captured stderr\n"
          + "captured notice\n")

      let direct = try captureStandardOutput {
        Output.log("direct stdout")
      }
      #expect(direct == "direct stdout\n")
    }
  }

  @Test
  static func forwardingShellOutputStreamsAndRemainsCaptured() throws {
    try TestGlobalLock.withLock {
      let statusOnlyMarker = "status-only-\(UUID().uuidString)"
      let capturedMarker = "captured-result-\(UUID().uuidString)"
      var captured = ""
      let direct = try captureStandardOutput {
        Output.beginCapture()
        let status = Shell.runForwardingOutput(
          "/bin/sh", ["-c", "printf '%s' '\(statusOnlyMarker)'"])
        let result = Shell.runForwardingAndCapturing(
          "/bin/sh", ["-c", "printf '%s' '\(capturedMarker)'"])
        captured = Output.endCapture()

        #expect(status == 0)
        #expect(result.status == 0)
        #expect(result.stdout == capturedMarker)
      }

      #expect(direct.contains(statusOnlyMarker))
      #expect(direct.contains(capturedMarker))
      #expect(captured.contains(statusOnlyMarker))
      #expect(captured.contains(capturedMarker))
    }
  }

  @Test
  static func capturePreservesTextAroundInvalidUTF8() throws {
    try TestGlobalLock.withLock {
      var bytes = Data("before".utf8)
      bytes.append(0xFF)
      bytes.append(Data("after".utf8))
      var captured = ""
      let forwarded = try captureStandardOutputData {
        Output.beginCapture()
        Output.forwardStandardOutput(bytes)
        captured = Output.endCapture()
      }

      #expect(forwarded == bytes)
      #expect(captured == "before\u{FFFD}after")
      #expect(captured.hasSuffix("after"))
    }
  }

  private static func captureStandardOutput(_ body: () throws -> Void) throws -> String {
    let data = try captureStandardOutputData(body)
    return try #require(String(bytes: data, encoding: .utf8))
  }

  private static func captureStandardOutputData(_ body: () throws -> Void) throws -> Data {
    let original = dup(STDOUT_FILENO)
    try #require(original >= 0)
    let pipe = Pipe()
    // Flush all buffered output streams before redirecting fd 1. Passing nil
    // (flush every stream) avoids referencing the libc `stdout` global, which
    // Glibc exports as shared mutable state that Swift 6 rejects in this context.
    fflush(nil)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    do {
      try body()
      pipe.fileHandleForWriting.closeFile()
      dup2(original, STDOUT_FILENO)
      close(original)
      return pipe.fileHandleForReading.readDataToEndOfFile()
    } catch {
      pipe.fileHandleForWriting.closeFile()
      dup2(original, STDOUT_FILENO)
      close(original)
      _ = pipe.fileHandleForReading.readDataToEndOfFile()
      throw error
    }
  }
}
