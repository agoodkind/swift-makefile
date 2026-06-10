//
//  CodesignTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - CodesignTests

enum CodesignTests {}

@Test
func binaryModeSignsWithRuntimeAndIdentifier() {
  let arguments = Codesign.arguments(
    path: "/tmp/lmd",
    mode: .binary,
    identity: "Developer ID Application: A (T)",
    identifier: "io.goodkind.lmd")
  #expect(
    arguments == [
      "--force", "--timestamp", "--sign", "Developer ID Application: A (T)",
      "--options", "runtime", "--identifier", "io.goodkind.lmd", "/tmp/lmd",
    ])
}

@Test
func binaryModeOmitsEmptyIdentifier() {
  let arguments = Codesign.arguments(
    path: "/tmp/lmd",
    mode: .binary,
    identity: "X",
    identifier: nil)
  #expect(
    arguments == ["--force", "--timestamp", "--sign", "X", "--options", "runtime", "/tmp/lmd"])
}

@Test
func sparkleModePreservesMetadata() {
  let arguments = Codesign.arguments(
    path: "/tmp/Updater.app",
    mode: .sparkle,
    identity: "X",
    identifier: "ignored.when.sparkle")
  #expect(
    arguments == [
      "--force", "--timestamp", "--sign", "X", "--options", "runtime",
      "--preserve-metadata=identifier,entitlements,flags", "/tmp/Updater.app",
    ])
}

@Test
func dmgModeSkipsHardenedRuntime() {
  let arguments = Codesign.arguments(
    path: "/tmp/App.dmg",
    mode: .dmg,
    identity: "X",
    identifier: nil)
  #expect(arguments == ["--force", "--timestamp", "--sign", "X", "/tmp/App.dmg"])
}

@Test
func runFailsWithoutIdentity() {
  let previousIdentity = ProcessInfo.processInfo.environment["CODE_SIGN_IDENTITY"]
  let previousSignIdentity = ProcessInfo.processInfo.environment["SWIFT_MK_SIGN_IDENTITY"]
  unsetenv("CODE_SIGN_IDENTITY")
  unsetenv("SWIFT_MK_SIGN_IDENTITY")
  defer {
    if let previousIdentity { setenv("CODE_SIGN_IDENTITY", previousIdentity, 1) }
    if let previousSignIdentity { setenv("SWIFT_MK_SIGN_IDENTITY", previousSignIdentity, 1) }
  }
  let outcome = Codesign.run(
    paths: ["/tmp/x"],
    mode: .binary,
    identifier: nil,
    localXcconfigPaths: [])
  #expect(outcome == false)
}
