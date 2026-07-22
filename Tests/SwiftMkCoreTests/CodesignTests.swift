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
func binaryModeAddsKeychainWhenSet() {
  let keychain = "/Users/runner/Library/Keychains/swift_mk_signing_runner.keychain-db"
  let arguments = Codesign.arguments(
    path: "/tmp/lmd",
    mode: .binary,
    identity: "X",
    identifier: nil,
    keychain: keychain)
  #expect(
    arguments == [
      "--force", "--timestamp", "--sign", "X", "--options", "runtime",
      "--keychain", keychain, "/tmp/lmd",
    ])
}

@Test
func binaryModeWithPreserveMetadataKeepsExistingIdentifier() {
  let arguments = Codesign.arguments(
    path: "/tmp/Updater.app",
    mode: .binary,
    identity: "X",
    identifier: "ignored.when.preserving",
    preserveMetadata: "identifier,entitlements,flags")
  #expect(
    arguments == [
      "--force", "--timestamp", "--sign", "X", "--options", "runtime",
      "--preserve-metadata=identifier,entitlements,flags", "/tmp/Updater.app",
    ])
}

@Test
func preserveMetadataTrimsSurroundingNewlinesAndSpaces() {
  let arguments = Codesign.arguments(
    path: "/tmp/Updater.app",
    mode: .binary,
    identity: "X",
    identifier: "ignored.when.preserving",
    preserveMetadata: "  identifier,entitlements,flags\n")
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
func explicitIdentifierWinsForEveryPath() {
  #expect(
    Codesign.identifier(forPath: "Products/lmd", explicit: "io.fixed", prefix: "io.goodkind.lmd")
      == "io.fixed")
}

@Test
func identifierPrefixDerivesFromBasename() {
  func derived(_ path: String) -> String? {
    Codesign.identifier(forPath: path, explicit: nil, prefix: "io.goodkind.lmd")
  }
  #expect(derived("Products/Build/Release/lmd") == "io.goodkind.lmd.lmd")
  #expect(derived("Products/Build/Release/lmd-serve") == "io.goodkind.lmd.lmd-serve")
  // A resource bundle drops its extension, matching the per-bundle identifier form.
  #expect(derived("Products/Build/Release/mlx.bundle") == "io.goodkind.lmd.mlx")
}

@Test
func identifierIsNilWithoutExplicitOrPrefix() {
  #expect(Codesign.identifier(forPath: "Products/lmd", explicit: nil, prefix: nil) == nil)
  #expect(Codesign.identifier(forPath: "Products/lmd", explicit: "", prefix: "") == nil)
}

@Test
func discoverBundlesFindsTopLevelBundlesSorted() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-bundles-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer {
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      Output.warning("cleanup failed: \(error.localizedDescription)")
    }
  }
  for name in ["zeta.bundle", "alpha.bundle", "lmd", "notes.txt"] {
    try Data().write(to: directory.appendingPathComponent(name))
  }
  let found = Codesign.discoverBundles(in: directory.path)
    .map { ($0 as NSString).lastPathComponent }
  #expect(found == ["alpha.bundle", "zeta.bundle"])
}

@Test
func discoverBundlesIsEmptyForMissingDirectory() {
  #expect(Codesign.discoverBundles(in: "/no/such/dir-\(UUID().uuidString)").isEmpty)
}

// MARK: - CodesignEnvironmentTests

/// These tests mutate process environment used by signing resolution, so they run
/// serialized to keep global state out of parallel codesign tests.
@Suite(.serialized)
enum CodesignEnvironmentTests {
  @Test
  static func codesignKeychainResolutionPrefersExplicitThenSwiftMkThenCodeSignEnvironment() {
    let previousSwiftMkKeychain = ProcessInfo.processInfo.environment["SWIFT_MK_SIGN_KEYCHAIN"]
    let previousCodeSignKeychain = ProcessInfo.processInfo.environment["CODE_SIGN_KEYCHAIN"]
    unsetenv("SWIFT_MK_SIGN_KEYCHAIN")
    unsetenv("CODE_SIGN_KEYCHAIN")
    defer {
      restoreEnvironmentValue(previousSwiftMkKeychain, forKey: "SWIFT_MK_SIGN_KEYCHAIN")
      restoreEnvironmentValue(previousCodeSignKeychain, forKey: "CODE_SIGN_KEYCHAIN")
    }

    setenv("CODE_SIGN_KEYCHAIN", "/tmp/code.keychain-db", 1)
    #expect(
      Codesign.resolveKeychain(explicit: nil, localXcconfigPaths: []) == "/tmp/code.keychain-db")

    setenv("SWIFT_MK_SIGN_KEYCHAIN", "/tmp/swift.keychain-db", 1)
    #expect(
      Codesign.resolveKeychain(explicit: nil, localXcconfigPaths: []) == "/tmp/swift.keychain-db")
    #expect(
      Codesign.resolveKeychain(explicit: "/tmp/explicit.keychain-db", localXcconfigPaths: [])
        == "/tmp/explicit.keychain-db")
  }

  @Test
  static func runFailsWithoutIdentity() {
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
}

@Test
func swiftBuildMakefileRendersKeychainSpacingForSigningCommands() throws {
  let keychain = "/Users/runner/Library/Keychains/signing keychain.keychain-db"
  let renderedWithKeychain = try renderSwiftBuildMakefileCommands(codeSignKeychain: keychain)
  let expectedPreludeKeychainBoundary = #"SWIFT_MK_SIGN_KEYCHAIN="" "/tmp/swift-mk""#
  let expectedPostBuildKeychainBoundary =
    #"--bundles-in Products/Bundles --keychain "\#(keychain)" Products/App"#

  #expect(renderedWithKeychain.prelude.contains(expectedPreludeKeychainBoundary))
  #expect(renderedWithKeychain.postBuildSign.contains(expectedPostBuildKeychainBoundary))

  let renderedWithoutKeychain = try renderSwiftBuildMakefileCommands(codeSignKeychain: "")

  #expect(!renderedWithoutKeychain.prelude.contains("CODE_SIGN_KEYCHAIN="))
  #expect(!renderedWithoutKeychain.postBuildSign.contains("--keychain"))
  #expect(
    renderedWithoutKeychain.postBuildSign.contains(
      #"--bundles-in Products/Bundles Products/App"#
    ))
}

private func renderSwiftBuildMakefileCommands(codeSignKeychain: String) throws -> (
  prelude: String,
  postBuildSign: String
) {
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("swift-mk-render-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer {
    do {
      try FileManager.default.removeItem(at: temporaryDirectory)
    } catch {
      Output.warning("cleanup failed: \(error.localizedDescription)")
    }
  }

  let makefileURL = temporaryDirectory.appendingPathComponent("Makefile")
  let repositoryRoot = codesignTestsRepositoryRoot().path
  let makefile = """
    include \(repositoryRoot)/swift-build.mk

    .PHONY: print-signing
    print-signing:
    \t@printf 'PRELUDE=%s\\n' '$(SWIFT_MK_SIGNING_PRELUDE)'
    \t@printf 'POST_BUILD_SIGN=%s\\n' '$(SWIFT_MK_POST_BUILD_SIGN_CMD)'
    """
  try makefile.write(to: makefileURL, atomically: true, encoding: .utf8)

  var arguments = [
    "-f", makefileURL.path,
    "print-signing",
    "SWIFT_MK_BIN=/tmp/swift-mk",
    "CODE_SIGN_IDENTITY=Developer ID Application: Example",
    "SWIFT_MK_SIGN_BUNDLES_DIR=Products/Bundles",
    "SWIFT_MK_SIGN_PRODUCTS=Products/App",
  ]
  if !codeSignKeychain.isEmpty {
    arguments.append("CODE_SIGN_KEYCHAIN=\(codeSignKeychain)")
  }

  let result = Shell.run("make", arguments)
  #expect(result.status == 0, Comment(rawValue: result.combined))

  let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(
    String.init)
  let prelude = lines.first { $0.hasPrefix("PRELUDE=") }?.dropFirst("PRELUDE=".count)
  let postBuildSign = lines.first { $0.hasPrefix("POST_BUILD_SIGN=") }?
    .dropFirst("POST_BUILD_SIGN=".count)

  return (String(prelude ?? ""), String(postBuildSign ?? ""))
}

private func codesignTestsRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

private func restoreEnvironmentValue(_ value: String?, forKey key: String) {
  guard let value else {
    unsetenv(key)
    return
  }
  setenv(key, value, 1)
}
