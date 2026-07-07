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

  private static func captureStandardOutput(_ body: () throws -> Void) throws -> String {
    let original = dup(STDOUT_FILENO)
    try #require(original >= 0)
    let pipe = Pipe()
    fflush(stdout)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    do {
      try body()
      pipe.fileHandleForWriting.closeFile()
      dup2(original, STDOUT_FILENO)
      close(original)
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return try #require(String(bytes: data, encoding: .utf8))
    } catch {
      pipe.fileHandleForWriting.closeFile()
      dup2(original, STDOUT_FILENO)
      close(original)
      _ = pipe.fileHandleForReading.readDataToEndOfFile()
      throw error
    }
  }
}
