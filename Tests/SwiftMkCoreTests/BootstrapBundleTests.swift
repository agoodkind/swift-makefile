//
//  BootstrapBundleTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-04.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BootstrapBundleTests

enum BootstrapBundleTests {}

@Test
func helperKeepsTheResourceBundleBesideTheBinaryAcrossARefresh() async throws {
  // swift-mk reads its lint configs from the bundle beside the binary. The
  // binary and swift-mk.key stay across a refresh, and a matching key skips
  // the rebuild that copies the bundle.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    let bundleFile = "swift-makefile_SwiftMkCore.bundle/Contents/Resources/swiftlint.yml"
    try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
    try writeMakeFile(directory, "swift-mk", "warm binary\n")
    try writeMakeFile(directory, "swift-mk.key", "warm key\n")
    try writeMakeFile(directory, bundleFile, "warm config\n")

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status == 0, "helper failed: \(result.stderr)")

    #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v1\n")
    #expect(readMakeFile(directory, "swift-mk.key") == "warm key\n")
    #expect(readMakeFile(directory, bundleFile) == "warm config\n")
  }
}
