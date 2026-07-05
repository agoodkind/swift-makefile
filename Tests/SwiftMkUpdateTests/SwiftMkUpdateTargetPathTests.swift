//
//  SwiftMkUpdateTargetPathTests.swift
//  SwiftMkUpdateTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-03.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkUpdate

// MARK: - SwiftMkUpdateTargetPathTests

enum SwiftMkUpdateTargetPathTests {
  private static let executablePermission = 0o755

  @Test
  static func resolvesBareArgv0ViaPath() throws {
    try withTemporaryDirectory { pathDirectory in
      try withTemporaryDirectory { workingDirectory in
        // A bare argv0 (launched from PATH) must resolve to its PATH entry, not
        // to a same-named file in the working directory.
        let onPath = pathDirectory.appendingPathComponent("swift-mk")
        try "binary".write(to: onPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: executablePermission)],
          ofItemAtPath: onPath.path)

        let resolved = UpdateOptions.defaultTargetPath(
          arguments: ["swift-mk"],
          currentDirectory: workingDirectory.path,
          environment: ["PATH": pathDirectory.path])

        #expect(resolved == onPath.resolvingSymlinksInPath().path)
        let inWorkingDirectory =
          workingDirectory.appendingPathComponent("swift-mk").resolvingSymlinksInPath().path
        #expect(resolved != inWorkingDirectory)
      }
    }
  }

  @Test
  static func resolvesRelativeArgv0AgainstWorkingDirectory() throws {
    try withTemporaryDirectory { workingDirectory in
      let resolved = UpdateOptions.defaultTargetPath(
        arguments: ["./swift-mk"],
        currentDirectory: workingDirectory.path,
        environment: [:])
      let expected =
        workingDirectory.appendingPathComponent("swift-mk").resolvingSymlinksInPath().path
      #expect(resolved == expected)
    }
  }
}
