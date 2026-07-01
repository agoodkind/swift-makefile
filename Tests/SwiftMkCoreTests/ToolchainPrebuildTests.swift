//
//  ToolchainPrebuildTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ToolchainPrebuildTests

@Suite(.serialized)
enum ToolchainPrebuildTests {
  private static let commandEnvName = "SWIFT_XCODE_PREBUILD_CMD"
  private static let guardEnvName = "SWIFT_MK_IN_PREBUILD"

  @Test
  static func unsetOrEmptyCommandDoesNothing() throws {
    try withMarker { marker in
      unsetenv(commandEnvName)
      #expect(ToolchainPrebuild.run())
      #expect(!FileManager.default.fileExists(atPath: marker))

      setenv(commandEnvName, "  \n", 1)
      #expect(ToolchainPrebuild.run())
      #expect(!FileManager.default.fileExists(atPath: marker))
    }
  }

  @Test
  static func configuredCommandRuns() throws {
    try withMarker { marker in
      setenv(commandEnvName, "/usr/bin/touch \(quoted(marker))", 1)
      #expect(ToolchainPrebuild.run())
      #expect(FileManager.default.fileExists(atPath: marker))
    }
  }

  @Test
  static func failingCommandReturnsFalse() throws {
    try withMarker { _ in
      setenv(commandEnvName, "exit 1", 1)
      #expect(!ToolchainPrebuild.run())
    }
  }

  @Test
  static func recursionGuardSkipsConfiguredCommand() throws {
    try withMarker { marker in
      setenv(commandEnvName, "/usr/bin/touch \(quoted(marker))", 1)
      setenv(guardEnvName, "1", 1)

      #expect(ToolchainPrebuild.run())
      #expect(!FileManager.default.fileExists(atPath: marker))
    }
  }

  @Test
  static func forwardingXcodebuildRunsPrebuildCommandFirst() throws {
    try withMarker { prebuildMarker in
      setenv(commandEnvName, "/usr/bin/touch \(quoted(prebuildMarker))", 1)

      try GatedBuildHarness.run { setup in
        let status = Toolchain.runXcodebuildForwarding(
          GatedBuildHarness.compileRequest(),
          actions: ["build"],
          environment: [:])

        #expect(status == 0)
        #expect(FileManager.default.fileExists(atPath: prebuildMarker))
        #expect(FileManager.default.fileExists(atPath: setup.xcodebuildMarker))
      }
    }
  }

  @Test
  static func xcodegenTestRunsPrebuildCommandFirst() throws {
    try withMarker { prebuildMarker in
      setenv(commandEnvName, "/usr/bin/touch \(quoted(prebuildMarker))", 1)

      try GatedBuildHarness.run { setup in
        let request = Toolchain.Request(
          generator: .xcodegen,
          scheme: "App",
          configuration: "Debug",
          project: "App.xcodeproj")
        let status = Toolchain.test(request)

        #expect(status == 0)
        #expect(FileManager.default.fileExists(atPath: prebuildMarker))
        #expect(FileManager.default.fileExists(atPath: setup.xcodebuildMarker))
      }
    }
  }

  private static func withMarker(_ body: (String) throws -> Void) throws {
    try TestGlobalLock.withLock {
      let manager = FileManager.default
      let directory = NSTemporaryDirectory() + "swiftmk-prebuild-" + UUID().uuidString
      let marker = directory + "/marker"
      let saved = Environment.snapshot([commandEnvName, guardEnvName])
      defer {
        saved.restore()
        removeTemporary(directory)
      }
      try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try body(marker)
    }
  }

  private static func quoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }
}
