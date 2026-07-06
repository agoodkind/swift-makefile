//
//  ReleaseVersionTests.swift
//  SwiftMkMaintCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkMaintCore

// MARK: - ReleaseVersionTests

enum ReleaseVersionTests {
  @Test
  static func currentVersionUsesTheReleaseStampLiteral() {
    #expect(ReleaseVersion.current == "dev")
  }
}
