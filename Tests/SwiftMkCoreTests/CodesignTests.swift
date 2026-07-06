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
func importSigningCertActionUsesRunnerKeyedKeychainName() throws {
  let action = try importSigningCertActionText()

  #expect(action.contains("id: keychain"))
  #expect(action.contains("RUNNER_NAME:-runner"))
  #expect(action.contains("swift_mk_signing_"))
  #expect(action.contains("keychain: ${{ steps.keychain.outputs.name }}"))
  #expect(action.contains(#"security delete-keychain "${KEYCHAIN_NAME}.keychain""#))
  #expect(action.contains(#"security find-identity -v -p codesigning "${KEYCHAIN_NAME}.keychain""#))
  #expect(!action.contains("signing_temp.keychain"))
  #expect(!action.contains("keychain: signing_temp"))
}

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

private func importSigningCertActionText() throws -> String {
  let actionURL = codesignTestsRepositoryRoot()
    .appendingPathComponent(".github/actions/import-signing-cert/action.yml")
  return try String(contentsOf: actionURL, encoding: .utf8)
}

private func codesignTestsRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
