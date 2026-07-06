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
  /// Every engine module's sources, not one hand-picked directory. A consumer fetches
  /// `Package.swift` plus the sources listed in the manifest into `.make`, then builds
  /// `swift-mk` from `.make`. SwiftPM validates every declared target's source directory
  /// at manifest load, so one source left out of the manifest makes the consumer's
  /// `.make` package a declared target with no sources, and the consumer's cold-cache
  /// build fails. Covering every fetched tree, not just `SwiftMkCore`, is what stops a
  /// newly added module (the `SwiftMkUpdate` case) from shipping unfetched.
  static let fetchedSourceDirectories = [
    "Sources",
    "Tests",
    "swiftcheck/Sources",
    "swiftcheck/Tests",
  ]

  @Test
  static func everyEngineSourceIsInTheFetchManifest() throws {
    let loaded = try loadManifest()
    var missing: [String] = []
    for directory in fetchedSourceDirectories {
      missing.append(
        contentsOf: try filesMissingFromManifest(
          directory: directory, root: loaded.root, manifest: loaded.manifest))
    }
    #expect(
      missing.isEmpty,
      """
      these engine .swift sources are absent from SWIFT_MK_SCRIPT_FILES in swift.mk, so \
      they would not be fetched into a consumer's .make, and the consumer's swift-mk \
      build would fail at manifest load:
      \(missing.sorted().joined(separator: "\n"))
      """)
  }

  // MARK: helpers

  enum ManifestError: Error {
    case directoryUnreadable(String)
    case manifestNotFound
  }

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

  /// The `.swift` files under `directory` (relative to the repo root), recursively,
  /// whose repo-relative path does not appear verbatim in the manifest text. Recurses
  /// so a file in a nested subdirectory cannot slip past the invariant.
  static func filesMissingFromManifest(
    directory: String, root: String, manifest: String
  ) throws -> [String] {
    let absolute = (root as NSString).appendingPathComponent(directory)
    guard let enumerator = FileManager.default.enumerator(atPath: absolute) else {
      throw ManifestError.directoryUnreadable(absolute)
    }
    var missing: [String] = []
    for case let relative as String in enumerator where relative.hasSuffix(".swift") {
      let relativePath = directory + "/" + relative
      if !manifest.contains(relativePath) {
        missing.append(relativePath)
      }
    }
    return missing.sorted()
  }
}
