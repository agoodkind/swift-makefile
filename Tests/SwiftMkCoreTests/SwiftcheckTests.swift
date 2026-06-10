//
//  SwiftcheckTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - SwiftcheckTests

enum SwiftcheckTests {}

@Test
func parsesRawFindingsBeforeApplyingExcludes() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-swiftcheck-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer {
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      Output.warning("cleanup failed: \(error.localizedDescription)")
    }
  }

  let rawPath = directory.appendingPathComponent("swiftcheck.raw.out").path
  let rawOutput =
    "Sources/SwiftMkCore/Toolchain.swift:42:5: silent_try: handle throwing calls explicitly\n"
  try rawOutput.write(toFile: rawPath, atomically: true, encoding: .utf8)
  let context = PathContext(pwd: directory.path + "/", cwd: directory.path + "/")

  let parsedAll = Swiftcheck.parseFindings(rawPath: rawPath, context: context)
  let parsedFindings = Swiftcheck.structuredFindings(
    rawPath: rawPath,
    exclude: "Sources/SwiftMkCore/Toolchain.swift",
    context: context
  )

  #expect(parsedAll.count == 1)
  #expect(parsedFindings.isEmpty)
  #expect(!Swiftcheck.isToolFailure(status: 1, parsedAll: parsedAll))
  #expect(Swiftcheck.isToolFailure(status: 1, parsedAll: []))
}
