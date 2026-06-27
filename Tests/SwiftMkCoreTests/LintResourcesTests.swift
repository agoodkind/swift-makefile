//
//  LintResourcesTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - LintResourcesTests

/// The bundled gate configs must match the repo's root config files byte for byte,
/// so the engine-owned resources never drift from the source the maintainer edits,
/// and `LintResources.ensure` writes the configs into a fresh checkout.
enum LintResourcesTests {
  /// A bundled resource paired with the repo-root file it must equal.
  struct Pair {
    let resourceName: String
    let resourceExtension: String
    let rootFile: String
  }

  /// Each bundled resource and its source-of-truth root file.
  static let pairs: [Pair] = [
    Pair(resourceName: "swiftlint", resourceExtension: "yml", rootFile: ".swiftlint.yml"),
    Pair(resourceName: "swift-format", resourceExtension: "json", rootFile: ".swift-format"),
    Pair(resourceName: "periphery", resourceExtension: "yml", rootFile: ".periphery.yml"),
    Pair(resourceName: "osv-scanner", resourceExtension: "toml", rootFile: "osv-scanner.toml"),
    Pair(resourceName: "mise", resourceExtension: "toml", rootFile: "mise.toml"),
  ]

  /// The repo root, derived from this test file's path so it is independent of the
  /// process working directory (other suites change it).
  static func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

@Test
func bundledConfigsMatchRootConfigsByteForByte() throws {
  let root = LintResourcesTests.repoRoot()
  for pair in LintResourcesTests.pairs {
    let bundled = try #require(
      LintResources.bundledData(
        resourceName: pair.resourceName, resourceExtension: pair.resourceExtension),
      "bundled \(pair.resourceName).\(pair.resourceExtension) is missing")
    let rootData = try Data(contentsOf: root.appendingPathComponent(pair.rootFile))
    #expect(bundled == rootData, "drift in \(pair.rootFile)")
  }
}

@Test
func ensureWritesConfigsIntoAFreshCheckout() throws {
  let manager = FileManager.default
  let checkout = NSTemporaryDirectory() + "swiftmk-resources-" + UUID().uuidString
  try manager.createDirectory(atPath: checkout, withIntermediateDirectories: true)
  defer { removeTemporary(checkout) }

  let ok = LintResources.ensure(
    context: PathContext(pwd: checkout + "/", cwd: checkout + "/"))
  #expect(ok)
  #expect(manager.fileExists(atPath: checkout + "/.make/swiftlint.yml"))
  #expect(manager.fileExists(atPath: checkout + "/.make/swift-format.json"))
  #expect(manager.fileExists(atPath: checkout + "/.make/periphery.yml"))
  #expect(manager.fileExists(atPath: checkout + "/.make/osv-scanner.toml"))
  #expect(manager.fileExists(atPath: checkout + "/.config/mise/conf.d/swift-mk.toml"))

  // The written swiftlint config equals the bundled bytes.
  let written = try Data(contentsOf: URL(fileURLWithPath: checkout + "/.make/swiftlint.yml"))
  let bundled = try #require(
    LintResources.bundledData(resourceName: "swiftlint", resourceExtension: "yml"))
  #expect(written == bundled)
}
