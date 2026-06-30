//
//  ManifestCompletenessTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ManifestCompletenessTests

/// Enforces, as a build-failing constraint, that every engine source and test file is
/// listed in `swift.mk`'s `SWIFT_MK_SCRIPT_FILES` fetch manifest. A new
/// `Sources/SwiftMkCore` file left out of the manifest is not fetched into consumers,
/// which breaks their build; this test catches the omission before it ships.
@Suite(.serialized)
enum ManifestCompletenessTests {
  @Test
  static func everySwiftMkCoreSourceIsInTheFetchManifest() throws {
    let loaded = try loadManifest()
    let missing = try filesMissingFromManifest(
      directory: "Sources/SwiftMkCore", root: loaded.root, manifest: loaded.manifest)
    let message =
      "these Sources/SwiftMkCore files are absent from SWIFT_MK_SCRIPT_FILES in "
      + "swift.mk, so they would not be fetched into consumers: \(missing)"
    #expect(missing.isEmpty, Comment(rawValue: message))
  }

  @Test
  static func everyEngineTestIsInTheFetchManifest() throws {
    let loaded = try loadManifest()
    let missing = try filesMissingFromManifest(
      directory: "Tests/SwiftMkCoreTests", root: loaded.root, manifest: loaded.manifest)
    let message =
      "these Tests/SwiftMkCoreTests files are absent from SWIFT_MK_SCRIPT_FILES in "
      + "swift.mk: \(missing)"
    #expect(missing.isEmpty, Comment(rawValue: message))
  }

  // MARK: helpers

  enum ManifestError: Error { case manifestNotFound }

  /// Walk up from this test file to the directory holding `swift.mk`, the engine repo
  /// root in any checkout or worktree, and read the manifest text.
  static func loadManifest() throws -> (root: String, manifest: String) {
    var directory = (#filePath as NSString).deletingLastPathComponent
    while directory != "/" {
      let candidate = (directory as NSString).appendingPathComponent("swift.mk")
      if FileManager.default.fileExists(atPath: candidate) {
        return (directory, try String(contentsOfFile: candidate, encoding: .utf8))
      }
      directory = (directory as NSString).deletingLastPathComponent
    }
    throw ManifestError.manifestNotFound
  }

  /// The `.swift` files in `directory` (relative to the repo root) whose repo-relative
  /// path does not appear verbatim in the manifest text.
  static func filesMissingFromManifest(
    directory: String, root: String, manifest: String
  ) throws -> [String] {
    let absolute = (root as NSString).appendingPathComponent(directory)
    let entries = try FileManager.default.contentsOfDirectory(atPath: absolute)
    var missing: [String] = []
    for entry in entries where entry.hasSuffix(".swift") {
      let relativePath = directory + "/" + entry
      if !manifest.contains(relativePath) {
        missing.append(relativePath)
      }
    }
    return missing.sorted()
  }
}
