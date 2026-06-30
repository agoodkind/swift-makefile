//
//  DeadcodeCoverageCompletenessTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - DeadcodeCoverageCompletenessTests

/// The unbypassable coverage check: an owned Swift source covered by no scan is
/// reported, a manifest is not owned, a nested package's sources are covered by the
/// subtree rule, and a package-describe output decodes to absolute source paths.
@Suite(.serialized)
enum DeadcodeCoverageCompletenessTests {
  // MARK: uncovered core

  @Test
  static func uncoveredIsEmptyWhenEveryOwnedFileIsCovered() {
    let owned: Set<String> = ["/p/A.swift", "/p/B.swift"]
    let result = DeadcodeCoverageCompleteness.uncovered(
      owned: owned, packageCovered: ["/p/A.swift"], xcodeCovered: ["/p/B.swift"])
    #expect(result.isEmpty)
  }

  @Test
  static func uncoveredReturnsTheXcodeOnlyFileWhenTheIndexIsEmpty() {
    let owned: Set<String> = ["/p/App.swift", "/p/Lib.swift"]
    let packageCovered: Set<String> = ["/p/Lib.swift"]
    let withoutIndex = DeadcodeCoverageCompleteness.uncovered(
      owned: owned, packageCovered: packageCovered, xcodeCovered: [])
    #expect(withoutIndex == ["/p/App.swift"])
    let withIndex = DeadcodeCoverageCompleteness.uncovered(
      owned: owned, packageCovered: packageCovered, xcodeCovered: ["/p/App.swift"])
    #expect(withIndex.isEmpty)
  }

  @Test
  static func isUnderMatchesADirectoryAndItsDescendants() {
    #expect(DeadcodeCoverageCompleteness.isUnder("/p/Tools/X.swift", anyOf: ["/p/Tools"]))
    #expect(DeadcodeCoverageCompleteness.isUnder("/p/Tools", anyOf: ["/p/Tools"]))
    #expect(!DeadcodeCoverageCompleteness.isUnder("/p/ToolsX.swift", anyOf: ["/p/Tools"]))
    #expect(!DeadcodeCoverageCompleteness.isUnder("/p/Other.swift", anyOf: ["/p/Tools"]))
  }

  // MARK: package describe decoding

  @Test
  static func packageSourceFilesDecodesDescribeToAbsoluteSwiftPaths() {
    let json = """
      {
        "name": "demo",
        "path": "/repo",
        "targets": [
          { "name": "Lib", "type": "library", "path": "Sources/Lib",
            "sources": ["A.swift", "B.swift", "data.json"] },
          { "name": "LibTests", "type": "test", "path": "Tests/LibTests",
            "sources": ["LibTests.swift"] }
        ]
      }
      """
    let files = DeadcodeCoverageCompleteness.packageSourceFiles(json: json)
    let expectedLib = IndexCompleteness.standardize("/repo/Sources/Lib/A.swift")
    let expectedTest = IndexCompleteness.standardize("/repo/Tests/LibTests/LibTests.swift")
    #expect(files.contains(expectedLib))
    #expect(files.contains(IndexCompleteness.standardize("/repo/Sources/Lib/B.swift")))
    #expect(files.contains(expectedTest))
    #expect(!files.contains(IndexCompleteness.standardize("/repo/Sources/Lib/data.json")))
  }

  @Test
  static func packageSourceFilesIsEmptyWithoutAPackagePath() {
    let json = """
      { "name": "demo", "targets": [ { "name": "Lib" } ] }
      """
    #expect(DeadcodeCoverageCompleteness.packageSourceFiles(json: json).isEmpty)
  }

  // MARK: owned set and nested packages

  @Test
  static func ownedSwiftFilesDropsManifestsAndAbsolutizes() throws {
    try withTemporaryRepo { root, context in
      let owned = DeadcodeCoverageCompleteness.ownedSwiftFiles(context: context)
      let app = IndexCompleteness.standardize(root + "/Sources/App.swift")
      let tool = IndexCompleteness.standardize(root + "/Nested/Tool.swift")
      let manifest = IndexCompleteness.standardize(root + "/Package.swift")
      let nestedManifest = IndexCompleteness.standardize(root + "/Nested/Package.swift")
      #expect(owned.contains(app))
      #expect(owned.contains(tool))
      #expect(!owned.contains(manifest))
      #expect(!owned.contains(nestedManifest))
      // A shebang script is run directly, not compiled into a target, so it is not an
      // owned source the gate expects scanned.
      let script = IndexCompleteness.standardize(root + "/Scripts/run.swift")
      #expect(!owned.contains(script))
    }
  }

  @Test
  static func isManifestOrConfigRecognizesBuildSystemManifests() {
    #expect(DeadcodeCoverageCompleteness.isManifestOrConfig("Package.swift"))
    #expect(DeadcodeCoverageCompleteness.isManifestOrConfig("Project.swift"))
    #expect(DeadcodeCoverageCompleteness.isManifestOrConfig("Tools/Package.swift"))
    #expect(DeadcodeCoverageCompleteness.isManifestOrConfig("Tuist.swift"))
    #expect(DeadcodeCoverageCompleteness.isManifestOrConfig("Tuist/ProjectHelpers.swift"))
    #expect(!DeadcodeCoverageCompleteness.isManifestOrConfig("Sources/App.swift"))
    #expect(!DeadcodeCoverageCompleteness.isManifestOrConfig("Apps/iOS/Main.swift"))
  }

  @Test
  static func isShebangScriptDetectsTheInterpreterLine() throws {
    let root = NSTemporaryDirectory() + "swiftmk-shebang-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { removeTemporary(root) }
    let script = root + "/run.swift"
    let source = root + "/Lib.swift"
    try "#!/usr/bin/env swift\nprint(1)\n".write(
      toFile: script, atomically: true, encoding: .utf8)
    try "enum Lib {}\n".write(toFile: source, atomically: true, encoding: .utf8)
    #expect(DeadcodeCoverageCompleteness.isShebangScript(script))
    #expect(!DeadcodeCoverageCompleteness.isShebangScript(source))
  }

  @Test
  static func nestedPackageRootsExcludesTheRepoRootManifest() throws {
    try withTemporaryRepo { root, context in
      let roots = DeadcodeCoverageCompleteness.nestedPackageRoots(context: context)
      let nested = IndexCompleteness.standardize(root + "/Nested")
      #expect(roots.contains(nested))
      #expect(!roots.contains(IndexCompleteness.standardize(root)))
    }
  }

  @Test
  static func nestedPackageSubtreeCoversItsOwnSourcesNotRootCode() throws {
    try withTemporaryRepo { root, context in
      let owned = DeadcodeCoverageCompleteness.ownedSwiftFiles(context: context)
      let covered = DeadcodeCoverageCompleteness.packageCoveredFiles(
        context: context, owned: owned)
      let tool = IndexCompleteness.standardize(root + "/Nested/Tool.swift")
      let app = IndexCompleteness.standardize(root + "/Sources/App.swift")
      // The nested package's source is covered by the subtree rule. The root App.swift
      // is not in any nested package and the fake root manifest does not resolve, so it
      // stays uncovered, which is the bypass the gate must catch.
      #expect(covered.contains(tool))
      #expect(!covered.contains(app))
      let missing = DeadcodeCoverageCompleteness.uncovered(
        owned: owned, packageCovered: covered, xcodeCovered: [])
      #expect(missing == [app])
    }
  }

  // MARK: helpers

  private static func withTemporaryRepo(
    _ body: (_ root: String, _ context: PathContext) throws -> Void
  ) throws {
    try TestGlobalLock.withLock {
      let manager = FileManager.default
      let root = NSTemporaryDirectory() + "swiftmk-coverage-" + UUID().uuidString
      try manager.createDirectory(
        atPath: root + "/Sources", withIntermediateDirectories: true)
      try manager.createDirectory(
        atPath: root + "/Nested", withIntermediateDirectories: true)
      try "enum App {}\n".write(
        toFile: root + "/Sources/App.swift", atomically: true, encoding: .utf8)
      try "// manifest\n".write(
        toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
      try "// nested manifest\n".write(
        toFile: root + "/Nested/Package.swift", atomically: true, encoding: .utf8)
      try "enum Tool {}\n".write(
        toFile: root + "/Nested/Tool.swift", atomically: true, encoding: .utf8)
      try manager.createDirectory(
        atPath: root + "/Scripts", withIntermediateDirectories: true)
      try "#!/usr/bin/env swift\nprint(\"hi\")\n".write(
        toFile: root + "/Scripts/run.swift", atomically: true, encoding: .utf8)
      let savedCwd = manager.currentDirectoryPath
      defer {
        manager.changeCurrentDirectoryPath(savedCwd)
        removeTemporary(root)
      }
      _ = Shell.run("git", ["-C", root, "init", "-q"])
      _ = Shell.run(
        "git",
        [
          "-C", root, "add", "Sources/App.swift", "Package.swift",
          "Nested/Package.swift", "Nested/Tool.swift", "Scripts/run.swift",
        ])
      manager.changeCurrentDirectoryPath(root)
      let context = PathContext(pwd: root + "/", cwd: root + "/")
      try body(root, context)
    }
  }
}
