//
//  XcconfigValuesTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - XcconfigValuesTests

/// `XcconfigValues.read` parses `KEY = value` settings, expands `$(KEY)`/`${KEY}`
/// references, leaves unknown references literal, and lets later files win.
enum XcconfigValuesTests {
  static func withTemporaryFile(_ contents: String, _ body: (String) throws -> Void) throws {
    let path = NSTemporaryDirectory() + "swiftmk-xcconfig-" + UUID().uuidString + ".xcconfig"
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    defer { removeTemporary(path) }
    try body(path)
  }
}

@Test
func xcconfigExpandsReferences() throws {
  try XcconfigValuesTests.withTemporaryFile(
    """
    BUNDLE_ID_PREFIX = io.goodkind.celltunnel
    AGENT_BUNDLE_ID = $(BUNDLE_ID_PREFIX).agent
    PHONE_BUNDLE_ID = ${BUNDLE_ID_PREFIX}.phone
    """
  ) { path in
    let values = XcconfigValues.read(paths: [path])
    #expect(values["AGENT_BUNDLE_ID"] == "io.goodkind.celltunnel.agent")
    #expect(values["PHONE_BUNDLE_ID"] == "io.goodkind.celltunnel.phone")
  }
}

@Test
func xcconfigLeavesUnknownReferenceLiteral() throws {
  try XcconfigValuesTests.withTemporaryFile(
    "DERIVED = $(NOT_DEFINED)/x\n"
  ) { path in
    let values = XcconfigValues.read(paths: [path])
    #expect(values["DERIVED"] == "$(NOT_DEFINED)/x")
  }
}

@Test
func xcconfigLaterFileWins() throws {
  try XcconfigValuesTests.withTemporaryFile("TEAM = AAAA\n") { first in
    try XcconfigValuesTests.withTemporaryFile("TEAM = BBBB\n") { second in
      let values = XcconfigValues.read(paths: [first, second])
      #expect(values["TEAM"] == "BBBB")
    }
  }
}

@Test
func xcconfigMissingFileContributesNothing() {
  let values = XcconfigValues.read(paths: ["/nonexistent/Local.xcconfig"])
  #expect(values.isEmpty)
}
