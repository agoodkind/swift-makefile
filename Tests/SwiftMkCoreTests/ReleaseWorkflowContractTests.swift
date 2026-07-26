//
//  ReleaseWorkflowContractTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ReleaseWorkflowContractTests

@Suite(.serialized)
enum ReleaseWorkflowContractTests {
  @Test
  static func validatesTheReusableReleaseWorkflowContract() throws {
    let script = try scriptPath()
    let workflow = try workflowPath()
    let result = Shell.run("ruby", [script, workflow])

    #expect(result.status == 0)
    #expect(result.stderr.isEmpty)
  }

  private static func scriptPath() throws -> String {
    try repositoryPath(for: "scripts/verify-release-workflow-contract.rb")
  }

  private static func workflowPath() throws -> String {
    try repositoryPath(for: ".github/workflows/_release.yml")
  }

  private static func repositoryPath(for relativePath: String) throws -> String {
    var directory = (#filePath as NSString).deletingLastPathComponent
    while directory != "/" {
      let candidate = (directory as NSString).appendingPathComponent(relativePath)
      if FileManager.default.fileExists(atPath: candidate) {
        return candidate
      }
      directory = (directory as NSString).deletingLastPathComponent
    }
    throw ReleaseWorkflowContractTestError.fileNotFound(relativePath)
  }

  private enum ReleaseWorkflowContractTestError: Error {
    case fileNotFound(String)
  }
}
