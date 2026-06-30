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
    #expect(
      offenders.isEmpty,
      """
      SwiftMkCore must drive the swift CLI through the SwiftPM chokepoint, not link \
      libSwiftPM. Remove these imports:
      \(offenders.joined(separator: "\n"))
      """)
  }

  @Test
  static func importedModuleParsesAttributedAndSubmoduleImports() {
    #expect(importedModule("import PackageModel") == "PackageModel")
    #expect(importedModule("@_implementationOnly import PackageGraph") == "PackageGraph")
    #expect(importedModule("import struct PackageModel.Manifest") == "PackageModel")
    #expect(importedModule("@testable import SwiftMkCore") == "SwiftMkCore")
    #expect(importedModule("import\tPackageModel") == "PackageModel")
    #expect(importedModule("import   PackageGraph") == "PackageGraph")
    #expect(importedModule("// import PackageModel") == nil)
    #expect(importedModule("let s = \"import PackageModel\"") == nil)
  }

  // MARK: helpers

  enum RepoError: Error {
    case directoryUnreadable(String)
    case rootNotFound
  }

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
    // Throw rather than return empty on an unreadable directory: a silent empty scan
    // would pass the invariant by failing to look, which is exactly what it must catch.
    guard let enumerator = manager.enumerator(atPath: directory) else {
      throw RepoError.directoryUnreadable(directory)
    }
    var offenders: [String] = []
    for case let relative as String in enumerator where relative.hasSuffix(".swift") {
      let path = (directory as NSString).appendingPathComponent(relative)
      let contents = try String(contentsOfFile: path, encoding: .utf8)
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
    var tokens = line.split { $0 == " " || $0 == "\t" }.map(String.init)
    // Drop leading attributes such as @_implementationOnly or @testable.
    while let first = tokens.first, first.hasPrefix("@") {
      tokens.removeFirst()
    }
    guard tokens.first == "import" else {
      return nil
    }
    tokens.removeFirst()
    // Drop an item-kind keyword so `import struct X.Y` still yields the module name.
    let itemKinds: Set<String> = [
      "struct", "class", "enum", "protocol", "typealias", "func", "var", "let",
    ]
    if let first = tokens.first, itemKinds.contains(first) {
      tokens.removeFirst()
    }
    guard let moduleToken = tokens.first else {
      return nil
    }
    return moduleToken.split(separator: ".").first.map(String.init)
  }
}
