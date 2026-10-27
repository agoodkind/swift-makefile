//
//  ReleaseChecksumsScriptTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ReleaseChecksumsScriptTests

@Suite(.serialized)
enum ReleaseChecksumsScriptTests {
  static let sourceArchive = "swift-makefile-dev.tar.gz"
  static let maintDmg = "swift-mk-maint_darwin_arm64.dmg"
  static let engineDmg = "swift-mk-engine_darwin_arm64.dmg"
  static let sourceArchiveContents = "source archive\n"
  static let stapledMaintContents = "stapled maint dmg\n"
  static let stapledEngineContents = "stapled engine dmg\n"
  static let sourceArchiveDigest =
    "5534df43f64c54eacb4b9189e025a1fd16b7a9e69155295b6165b6ffbb2490b5"
  static let stapledMaintDigest =
    "30707636a389d4fb31ac7c3cfbea8c8e13217d235493b425ff193666e9766086"
  static let stapledEngineDigest =
    "79e1ea60a05a991dbcd3fcfcdeb141845b73c847b982bd4d1cd6823456ff6f6b"

  @Test
  static func refreshWritesTheDigestsOfAssetsChangedAfterTheFirstWrite() throws {
    try withDistDirectory { dist in
      try dist.write(sourceArchiveContents, to: sourceArchive)
      try dist.write("unstapled maint dmg\n", to: maintDmg)
      try dist.write("unstapled engine dmg\n", to: engineDmg)
      let written = dist.run("write", sourceArchive, maintDmg, engineDmg)
      try #require(written.status == 0)

      try dist.write(stapledMaintContents, to: maintDmg)
      try dist.write(stapledEngineContents, to: engineDmg)
      let staleCheck = dist.run("verify")
      #expect(staleCheck.status != 0)
      #expect(staleCheck.stderr.contains("checksums.txt does not match"))

      let refreshed = dist.run("refresh")
      try #require(refreshed.status == 0)
      let expected = """
        \(sourceArchiveDigest)  \(sourceArchive)
        \(stapledMaintDigest)  \(maintDmg)
        \(stapledEngineDigest)  \(engineDmg)

        """
      #expect(try dist.read("checksums.txt") == expected)
      #expect(dist.run("verify").status == 0)
    }
  }

  @Test
  static func refreshAndVerifySkipADistWithoutChecksums() throws {
    try withDistDirectory { dist in
      try dist.write(stapledEngineContents, to: engineDmg)

      #expect(dist.run("refresh").status == 0)
      #expect(dist.run("verify").status == 0)
      #expect(!FileManager.default.fileExists(atPath: dist.path(for: "checksums.txt")))
    }
  }

  private static func withDistDirectory(_ body: (DistDirectory) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-release-checksums-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        Output.warning("cleanup failed: \(error.localizedDescription)")
      }
    }
    try body(DistDirectory(directory: directory, script: try scriptPath()))
  }

  private static func scriptPath() throws -> String {
    var searchDirectory = (#filePath as NSString).deletingLastPathComponent
    while searchDirectory != "/" {
      let candidate = (searchDirectory as NSString).appendingPathComponent(
        "scripts/release-checksums.sh")
      if FileManager.default.fileExists(atPath: candidate) {
        return candidate
      }
      searchDirectory = (searchDirectory as NSString).deletingLastPathComponent
    }
    throw ReleaseChecksumsScriptTestError.scriptNotFound
  }

  private struct DistDirectory {
    let directory: URL
    let script: String

    func path(for name: String) -> String {
      directory.appendingPathComponent(name).path
    }

    func write(_ contents: String, to name: String) throws {
      try contents.write(toFile: path(for: name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String) throws -> String {
      try String(contentsOfFile: path(for: name), encoding: .utf8)
    }

    func run(_ arguments: String...) -> Shell.Result {
      Shell.run("/bin/bash", [script, arguments[0], directory.path] + arguments.dropFirst())
    }
  }

  private enum ReleaseChecksumsScriptTestError: Error {
    case scriptNotFound
  }
}
