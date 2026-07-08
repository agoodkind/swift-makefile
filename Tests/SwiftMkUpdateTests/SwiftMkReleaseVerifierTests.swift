//
//  SwiftMkReleaseVerifierTests.swift
//  SwiftMkUpdateTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkUpdate

// MARK: - SwiftMkReleaseVerifierTests

@Suite(.serialized)
enum SwiftMkReleaseVerifierTests {
  static let newerTag = SwiftMkUpdateSupport.newerTag

  @Test
  static func verifyReleaseDownloadsMountsAndRunsPublishedBinary() throws {
    try withPreparedUpdate { setup in
      let updater = Updater(options: setup.options)

      let result = try updater.verifyRelease(tag: newerTag, requireSignature: true)

      #expect(result.tag == newerTag)
      #expect(result.assetName == "swift-mk_darwin_arm64.dmg")
      #expect(result.requireSignature)
      #expect(result.validationOutput.contains("version: \(newerTag)"))
    }
  }

  @Test
  static func verifyReleaseSkipsStapleWhenNotRequired() throws {
    try withPreparedUpdate(commandMode: .stapleFailure) { setup in
      let updater = Updater(options: setup.options)

      let result = try updater.verifyRelease(tag: newerTag, requireSignature: false)

      #expect(result.tag == newerTag)
      #expect(!result.requireSignature)
      #expect(result.validationOutput.contains("version: \(newerTag)"))
    }
  }

  @Test
  static func verifyReleaseSkipsTeamCheckWhenNotRequired() throws {
    try withPreparedUpdate(commandMode: .teamMismatch) { setup in
      let updater = Updater(options: setup.options)

      let result = try updater.verifyRelease(tag: newerTag, requireSignature: false)

      #expect(result.tag == newerTag)
      #expect(result.validationOutput.contains("version: \(newerTag)"))
    }
  }

  @Test
  static func verifyReleaseRefusesUnsignedCandidateEvenWhenNotRequired() throws {
    // A basic codesign validity check runs before the binary is executed even
    // when require-signature is off, so an unsigned or tampered candidate is
    // refused rather than launched.
    try withPreparedUpdate(commandMode: .signatureFailure) { setup in
      let updater = Updater(options: setup.options)

      #expect(throws: UpdateError.self) {
        try updater.verifyRelease(tag: newerTag, requireSignature: false)
      }
    }
  }

  @Test
  static func verifyReleaseRefusesWrongTagOutput() throws {
    try withPreparedUpdate(commandMode: .validateMismatch) { setup in
      let updater = Updater(options: setup.options)

      #expect(throws: UpdateError.self) {
        try updater.verifyRelease(tag: newerTag, requireSignature: false)
      }
    }
  }
}
