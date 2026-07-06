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
  #expect(action.contains(#"KEYCHAIN_PATH: ${{ steps.keychain.outputs.path }}"#))
  #expect(action.contains(#"security delete-keychain "$KEYCHAIN_PATH""#))
  #expect(action.contains(#"security find-identity -v -p codesigning "$KEYCHAIN_PATH""#))
  #expect(!action.contains("signing_temp.keychain"))
  #expect(!action.contains("keychain: signing_temp"))
}

@Test
func importSigningCertActionOutputsExplicitKeychainPath() throws {
  let action = try importSigningCertActionText()

  #expect(action.contains("  keychain:"))
  #expect(action.contains("value: ${{ steps.keychain.outputs.path }}"))
  #expect(
    action.contains(#"keychain_path="${HOME}/Library/Keychains/${keychain_name}.keychain-db""#))
  #expect(action.contains(#"printf 'path=%s\n' "$keychain_path" >> "$GITHUB_OUTPUT""#))
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
func codesignRunSourceThreadsKeychainOption() throws {
  let source = try codesignRunText()

  #expect(source.contains("var keychain: String?"))
  #expect(source.contains("keychain: keychain"))
}

@Test
func workflowHelperThreadsCodeSignKeychain() throws {
  let source = try workflowHelperText()

  #expect(source.contains(#"let codeSignKeychain = environment.optional("CODE_SIGN_KEYCHAIN")"#))
  #expect(source.contains(#"CODE_SIGN_KEYCHAIN=\(codeSignKeychain)"#))
}

@Test
func workflowsPassActionKeychainOutputBesideIdentity() throws {
  let ciGate = try workflowText(named: "_ci-gate.yml")
  let release = try workflowText(named: "_release.yml")

  #expect(
    ciGate.contains(
      "CODE_SIGN_KEYCHAIN: ${{ steps.cert-local.outputs.keychain || steps.cert-remote.outputs.keychain }}"
    ))
  #expect(release.contains("CODE_SIGN_KEYCHAIN: ${{ steps.cert.outputs.keychain }}"))
  #expect(release.contains("CODE_SIGN_KEYCHAIN=$CODE_SIGN_KEYCHAIN"))
}

@Test
func releaseWorkflowKeepsSigningMakeArgumentsWhole() throws {
  let release = try workflowText(named: "_release.yml")

  #expect(release.contains("sign_args=()"))
  #expect(
    release.contains(
      #"sign_args+=("CODE_SIGN_IDENTITY=$CERT_SHA1" "DMG_SIGN_IDENTITY=$CERT_SHA1")"#))
  #expect(release.contains(#"sign_args+=("CODE_SIGN_KEYCHAIN=$CODE_SIGN_KEYCHAIN")"#))
  #expect(release.contains(#"sign_args+=("DEVELOPMENT_TEAM=$TEAM_ID")"#))
  #expect(release.contains(#""${sign_args[@]}""#))
  #expect(!release.contains("make ${{ inputs.build-target }} ${{ inputs.make-args }} $sign_args"))
}

@Test
func swiftBuildMakefilePassesKeychainToSigningPreludeAndCodesignRun() throws {
  let makefile = try swiftBuildMakefileText()
  let rootMakefile = try swiftMakefileText()

  #expect(makefile.contains(#"CODE_SIGN_KEYCHAIN="$(CODE_SIGN_KEYCHAIN)""#))
  #expect(makefile.contains("--keychain"))
  #expect(rootMakefile.contains("export CODE_SIGN_KEYCHAIN"))
  #expect(rootMakefile.contains("export SWIFT_MK_SIGN_KEYCHAIN"))
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

private func importSigningCertActionText() throws -> String {
  let actionURL = codesignTestsRepositoryRoot()
    .appendingPathComponent(".github/actions/import-signing-cert/action.yml")
  return try String(contentsOf: actionURL, encoding: .utf8)
}

private func codesignRunText() throws -> String {
  let sourceURL = codesignTestsRepositoryRoot()
    .appendingPathComponent("Sources/SwiftMkCLI/CodesignRun.swift")
  return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func workflowHelperText() throws -> String {
  let sourceURL = codesignTestsRepositoryRoot()
    .appendingPathComponent(".github/actions/workflow-helper/workflow-helper.swift")
  return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func workflowText(named name: String) throws -> String {
  let workflowURL = codesignTestsRepositoryRoot()
    .appendingPathComponent(".github/workflows")
    .appendingPathComponent(name)
  return try String(contentsOf: workflowURL, encoding: .utf8)
}

private func swiftBuildMakefileText() throws -> String {
  let makefileURL = codesignTestsRepositoryRoot()
    .appendingPathComponent("swift-build.mk")
  return try String(contentsOf: makefileURL, encoding: .utf8)
}

private func swiftMakefileText() throws -> String {
  let makefileURL = codesignTestsRepositoryRoot()
    .appendingPathComponent("swift.mk")
  return try String(contentsOf: makefileURL, encoding: .utf8)
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
