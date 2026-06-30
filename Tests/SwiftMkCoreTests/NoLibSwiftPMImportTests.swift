//
//  NoLibSwiftPMImportTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - NoLibSwiftPMImportTests

/// Enforces, as a build-failing constraint, that `SwiftMkCore` imports no
/// swift-package-manager library module. The engine drives the `swift` command-line
/// tool through the gated `SwiftPM` chokepoint as a subprocess, so linking libSwiftPM
/// is never the path; this test fails the build if a source imports one.
@Suite(.serialized)
enum NoLibSwiftPMImportTests {
  /// The swift-package-manager library modules the engine must not link. `Package.swift`
  /// is the package manifest, not a `SwiftMkCore` source, so it is not scanned and may
  /// import `PackageDescription`.
  static let bannedModules: Set<String> = [
    "PackageDescription", "PackageModel", "PackageGraph", "PackageLoading",
    "SPMBuildCore", "PackageCollections", "Workspace", "Build",
  ]

  @Test
  static func swiftMkCoreImportsNoLibSwiftPMModule() throws {
    let root = try engineRepoRoot()
    let offenders = try bannedImports(inDirectory: root + "/Sources/SwiftMkCore")
    let message =
      "SwiftMkCore must drive the swift CLI through the SwiftPM chokepoint, not link "
      + "libSwiftPM. Remove these imports: \(offenders)"
    #expect(offenders.isEmpty, Comment(rawValue: message))
  }

  @Test
  static func importedModuleParsesAttributedAndSubmoduleImports() {
    #expect(importedModule("import PackageModel") == "PackageModel")
    #expect(importedModule("@_implementationOnly import PackageGraph") == "PackageGraph")
    #expect(importedModule("import struct PackageModel.Manifest") == "PackageModel")
    #expect(importedModule("@testable import SwiftMkCore") == "SwiftMkCore")
    #expect(importedModule("// import PackageModel") == nil)
    #expect(importedModule("let s = \"import PackageModel\"") == nil)
  }

  // MARK: helpers

  enum RepoError: Error { case rootNotFound }

  /// Walk up from this test file to the directory holding `swift.mk`, the engine repo
  /// root in any checkout or worktree.
  static func engineRepoRoot() throws -> String {
    var directory = (#filePath as NSString).deletingLastPathComponent
    while directory != "/" {
      if FileManager.default.fileExists(
        atPath: (directory as NSString).appendingPathComponent("swift.mk"))
      {
        return directory
      }
      directory = (directory as NSString).deletingLastPathComponent
    }
    throw RepoError.rootNotFound
  }

  /// The `path: import-line` pairs under `directory` that import a banned module.
  static func bannedImports(inDirectory directory: String) throws -> [String] {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(atPath: directory) else {
      return []
    }
    var offenders: [String] = []
    for case let relative as String in enumerator where relative.hasSuffix(".swift") {
      let path = (directory as NSString).appendingPathComponent(relative)
      let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
      for line in contents.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let module = importedModule(trimmed), bannedModules.contains(module) else {
          continue
        }
        offenders.append("\(relative): \(trimmed)")
      }
    }
    return offenders.sorted()
  }

  /// The module a line imports, or nil when the line is not an import. Strips leading
  /// attributes (`@_implementationOnly`, `@testable`) and an item kind
  /// (`import struct X.Y`), and ignores comments and string literals by requiring the
  /// line to begin with `import` once attributes are removed.
  static func importedModule(_ line: String) -> String? {
    if line.hasPrefix("//") {
      return nil
    }
    var rest = line
    while rest.hasPrefix("@") {
      guard let space = rest.firstIndex(of: " ") else {
        return nil
      }
      rest = String(rest[rest.index(after: space)...]).trimmingCharacters(in: .whitespaces)
    }
    guard rest.hasPrefix("import ") else {
      return nil
    }
    let after = rest.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
    guard let last = after.split(separator: " ").last else {
      return nil
    }
    return last.split(separator: ".").first.map(String.init)
  }
}
