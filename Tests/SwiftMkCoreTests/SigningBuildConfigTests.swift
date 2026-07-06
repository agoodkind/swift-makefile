//
//  SigningBuildConfigTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright (c) 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - SigningBuildConfigTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `SigningBuildConfigTests.swift`; the suite is written as free `@Test` functions.
enum SigningBuildConfigTests {}

@Test
func signingBuildConfigAdHocFromDashIdentity() throws {
  let text = try #require(SigningBuildConfig.contents(identity: "-", team: "", style: ""))
  #expect(text.contains("CODE_SIGN_IDENTITY = -"))
  #expect(text.contains("CODE_SIGN_STYLE = Manual"))
  #expect(text.contains("CODE_SIGNING_ALLOWED = YES"))
  #expect(text.contains("CODE_SIGNING_REQUIRED = NO"))
  // Ad-hoc needs no team.
  #expect(!text.contains("DEVELOPMENT_TEAM"))
}

@Test
func signingBuildConfigAdHocKeepsTeamWhenProvided() throws {
  // The PR-check context sets identity "-" with a team; the team is harmless and
  // is preserved, but signing still stays ad-hoc and not required.
  let text = try #require(
    SigningBuildConfig.contents(identity: "-", team: "H3BMXM4W7H", style: ""))
  #expect(text.contains("CODE_SIGN_IDENTITY = -"))
  #expect(text.contains("DEVELOPMENT_TEAM = H3BMXM4W7H"))
  #expect(text.contains("CODE_SIGNING_REQUIRED = NO"))
}

@Test
func signingBuildConfigDeveloperIdFromIdentityAndTeam() throws {
  let identity = "Developer ID Application: Alex Goodkind (H3BMXM4W7H)"
  let text = try #require(
    SigningBuildConfig.contents(identity: identity, team: "H3BMXM4W7H", style: ""))
  #expect(text.contains("CODE_SIGN_IDENTITY = \(identity)"))
  #expect(text.contains("CODE_SIGN_STYLE = Manual"))
  #expect(text.contains("DEVELOPMENT_TEAM = H3BMXM4W7H"))
  #expect(!text.contains("OTHER_CODE_SIGN_FLAGS"))
  // A real identity is never ad-hoc, so the ad-hoc allowances stay out.
  #expect(!text.contains("CODE_SIGNING_REQUIRED = NO"))
}

@Test
func signingBuildConfigWritesOtherCodeSignFlagsForKeychain() throws {
  let keychain = "/Users/runner/Library/Keychains/swift_mk_signing_runner.keychain-db"
  let identity = "Developer ID Application: Alex Goodkind (H3BMXM4W7H)"
  let text = try #require(
    SigningBuildConfig.contents(
      identity: identity,
      team: "H3BMXM4W7H",
      style: "",
      keychain: keychain))
  #expect(text.contains("CODE_SIGN_IDENTITY = \(identity)"))
  #expect(text.contains("OTHER_CODE_SIGN_FLAGS = --keychain \(keychain)"))
}

@Test
func signingBuildConfigAutomaticFromTeamOnly() throws {
  let text = try #require(
    SigningBuildConfig.contents(identity: "", team: "H3BMXM4W7H", style: ""))
  #expect(text.contains("CODE_SIGN_STYLE = Automatic"))
  #expect(text.contains("DEVELOPMENT_TEAM = H3BMXM4W7H"))
  // No identity setting line when the identity is empty; Automatic resolves the
  // identity. Match a real setting line (leading newline), not the header comment.
  #expect(!text.contains("\nCODE_SIGN_IDENTITY ="))
}

@Test
func signingBuildConfigEmptyInputsProduceNoOverride() {
  #expect(SigningBuildConfig.contents(identity: "", team: "", style: "") == nil)
  #expect(SigningBuildConfig.contents(identity: "  ", team: "  ", style: "  ") == nil)
}

@Test
func signingBuildConfigExplicitStyleWins() throws {
  // An empty identity with a team would infer Automatic; an explicit style overrides.
  let text = try #require(
    SigningBuildConfig.contents(identity: "", team: "H3BMXM4W7H", style: "Manual"))
  #expect(text.contains("CODE_SIGN_STYLE = Manual"))
}

@Test
func signingBuildConfigWriteReturnsNilWithoutOverride() {
  let makeDir = NSTemporaryDirectory() + "swiftmk-signing-none-" + UUID().uuidString
  let path = SigningBuildConfig.write(identity: "", team: "", style: "", makeDir: makeDir)
  #expect(path == nil)
}

@Test
func signingBuildConfigWriteWritesXcconfigAndReturnsAbsolutePath() throws {
  let makeDir = NSTemporaryDirectory() + "swiftmk-signing-" + UUID().uuidString
  let path = try #require(
    SigningBuildConfig.write(
      identity: "", team: "H3BMXM4W7H", style: "", makeDir: makeDir))
  #expect((path as NSString).isAbsolutePath)
  let written = try String(contentsOfFile: path, encoding: .utf8)
  #expect(written == SigningBuildConfig.contents(identity: "", team: "H3BMXM4W7H", style: ""))
}

@Test
func signingBuildConfigWriteDegradesSafelyOnFailure() {
  // A makeDir under a non-directory cannot be created, so the write throws; the
  // function must degrade to nil (build proceeds with existing signing) not crash.
  let path = SigningBuildConfig.write(
    identity: "-", team: "", style: "", makeDir: "/dev/null/swiftmk-cannot-create")
  #expect(path == nil)
}

@Test
func signingXcconfigValuesParsesKeysIgnoringCommentsAndQuotes() throws {
  let path = NSTemporaryDirectory() + "swiftmk-xcc-" + UUID().uuidString + ".xcconfig"
  let text = """
    // a leading comment
    DEVELOPMENT_TEAM = H3BMXM4W7H
    CODE_SIGN_IDENTITY = Apple Development // trailing comment
    CODE_SIGN_STYLE = Automatic;
    QUOTED = "Apple Development"
    """
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  let values = SigningBuildConfig.xcconfigValues(atPath: path)
  #expect(values["DEVELOPMENT_TEAM"] == "H3BMXM4W7H")
  #expect(values["CODE_SIGN_IDENTITY"] == "Apple Development")
  #expect(values["CODE_SIGN_STYLE"] == "Automatic")
  #expect(values["QUOTED"] == "Apple Development")
}

@Test
func signingXcconfigValuesReturnsEmptyForMissingFile() {
  let path = NSTemporaryDirectory() + "swiftmk-missing-" + UUID().uuidString + ".xcconfig"
  #expect(SigningBuildConfig.xcconfigValues(atPath: path).isEmpty)
}

// MARK: - SigningEnvironmentOverrideTests

/// The override mutates the process environment (`XCODE_XCCONFIG_FILE` and the
/// signing inputs), so these run serialized to keep that global state from one
/// test out of another.
@Suite(.serialized)
enum SigningEnvironmentOverrideTests {
  private static let signingEnvironmentKeys = [
    "CODE_SIGN_IDENTITY", "DEVELOPMENT_TEAM", "TUIST_DEVELOPMENT_TEAM", "CODE_SIGN_STYLE",
    "CODE_SIGN_KEYCHAIN", "SWIFT_MK_SIGN_IDENTITY", "SWIFT_MK_SIGN_TEAM", "SWIFT_MK_SIGN_STYLE",
    "SWIFT_MK_SIGN_KEYCHAIN",
    "SWIFT_MK_REQUIRE_SIGNING", "SWIFT_MK_VERIFY_XCCONFIG",
  ]

  @Test
  static func noOpWhenXcodeXcconfigFileAlreadySet() {
    setenv("XCODE_XCCONFIG_FILE", "/tmp/preexisting.xcconfig", 1)
    let makeDir = NSTemporaryDirectory() + "swiftmk-noop-" + UUID().uuidString
    let path = SigningBuildConfig.applyEnvironmentOverride(makeDir: makeDir)
    unsetenv("XCODE_XCCONFIG_FILE")
    #expect(path == nil)
  }

  @Test
  static func writesAndSetsEnvFromXcconfigWhenUnset() throws {
    try withCleanSigningEnvironment {
      let makeDir = NSTemporaryDirectory() + "swiftmk-apply-" + UUID().uuidString
      let xcconfig = makeDir + ".xcconfig"
      try "DEVELOPMENT_TEAM = H3BMXM4W7H\n".write(
        toFile: xcconfig, atomically: true, encoding: .utf8)
      let path = SigningBuildConfig.applyEnvironmentOverride(
        localXcconfigPaths: [xcconfig], makeDir: makeDir)
      let applied = Env.get("XCODE_XCCONFIG_FILE")
      let resolved = try #require(path)
      #expect(applied == resolved)
      let written = try String(contentsOfFile: resolved, encoding: .utf8)
      #expect(written.contains("DEVELOPMENT_TEAM = H3BMXM4W7H"))
      #expect(written.contains("CODE_SIGN_STYLE = Automatic"))
    }
  }

  @Test
  static func teamResolutionUsesSwiftMkThenDevelopmentThenTuistEnvironment() {
    withCleanSigningEnvironment {
      setenv("TUIST_DEVELOPMENT_TEAM", "TUISTTEAM", 1)
      #expect(SigningBuildConfig.environmentInputs().team == "TUISTTEAM")

      setenv("DEVELOPMENT_TEAM", "DEVTEAM", 1)
      #expect(SigningBuildConfig.environmentInputs().team == "DEVTEAM")

      setenv("SWIFT_MK_SIGN_TEAM", "SWIFTTEAM", 1)
      #expect(SigningBuildConfig.environmentInputs().team == "SWIFTTEAM")
    }
  }

  @Test
  static func keychainResolutionUsesSwiftMkThenCodeSignEnvironment() {
    withCleanSigningEnvironment {
      setenv("CODE_SIGN_KEYCHAIN", "/tmp/code.keychain-db", 1)
      #expect(SigningBuildConfig.environmentInputs().keychain == "/tmp/code.keychain-db")

      setenv("SWIFT_MK_SIGN_KEYCHAIN", "/tmp/swift.keychain-db", 1)
      #expect(SigningBuildConfig.environmentInputs().keychain == "/tmp/swift.keychain-db")
    }
  }

  @Test
  static func resolvedTeamFallsBackToConfiguredXcconfig() throws {
    try withCleanSigningEnvironment {
      let xcconfig = try temporaryXcconfig("DEVELOPMENT_TEAM = FILETEAM\n")
      #expect(SigningBuildConfig.resolvedTeam(localXcconfigPaths: [xcconfig]) == "FILETEAM")
    }
  }

  @Test
  static func signingPreflightIsInertWhenSigningIsNotRequired() {
    withCleanSigningEnvironment {
      #expect(SigningBuildConfig.signingPreflightResult().ok)
    }
  }

  @Test
  static func signingPreflightFailsWhenRequiredTeamIsMissing() {
    withCleanSigningEnvironment {
      let missingXcconfig = temporaryPath("missing-local.xcconfig")
      setenv("SWIFT_MK_VERIFY_XCCONFIG", missingXcconfig, 1)

      let result = SigningBuildConfig.signingPreflightResult()

      #expect(!result.ok)
      #expect(result.message.contains("swift-mk signing: missing DEVELOPMENT_TEAM"))
      #expect(result.message.contains("Set DEVELOPMENT_TEAM"))
      #expect(result.message.contains(missingXcconfig))
      #expect(!result.message.contains("\u{2014}"))
      #expect(!result.message.contains("\u{2013}"))
    }
  }

  @Test
  static func signingPreflightPassesWithTuistDevelopmentTeam() {
    withCleanSigningEnvironment {
      setenv("SWIFT_MK_VERIFY_XCCONFIG", temporaryPath("missing-local.xcconfig"), 1)
      setenv("TUIST_DEVELOPMENT_TEAM", "TUISTTEAM", 1)

      #expect(SigningBuildConfig.signingPreflightResult().ok)
    }
  }

  @Test
  static func signingPreflightPassesWithConfiguredXcconfigTeam() throws {
    try withCleanSigningEnvironment {
      let xcconfig = try temporaryXcconfig("DEVELOPMENT_TEAM = FILETEAM\n")
      setenv("SWIFT_MK_VERIFY_XCCONFIG", xcconfig, 1)

      #expect(SigningBuildConfig.signingPreflightResult().ok)
    }
  }

  @Test
  static func signingPreflightUsesDefaultLocalXcconfigPathWithRequireFlag() {
    withCleanSigningEnvironment {
      setenv("SWIFT_MK_REQUIRE_SIGNING", "1", 1)

      let result = SigningBuildConfig.signingPreflightResult()

      #expect(!result.ok)
      #expect(result.message.contains("Config/local.xcconfig"))
    }
  }

  private static func withCleanSigningEnvironment(_ run: () throws -> Void) rethrows {
    let xcodeXcconfigFile = savedEnvironmentValue("XCODE_XCCONFIG_FILE")
    let savedValues = savedSigningEnvironmentValues()
    defer {
      restoreEnvironmentValue(xcodeXcconfigFile, forKey: "XCODE_XCCONFIG_FILE")
      restoreSigningEnvironmentValues(savedValues)
    }
    unsetenv("XCODE_XCCONFIG_FILE")
    for key in signingEnvironmentKeys {
      unsetenv(key)
    }
    try run()
  }

  private static func temporaryXcconfig(_ contents: String) throws -> String {
    let path = temporaryPath("local.xcconfig")
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
  }

  private static func temporaryPath(_ filename: String) -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swiftmk-signing-\(UUID().uuidString)",
      isDirectory: true
    )
    return directory.appendingPathComponent(filename).path
  }

  private static func savedSigningEnvironmentValues() -> [String: String] {
    var values: [String: String] = [:]
    for key in signingEnvironmentKeys {
      if let value = savedEnvironmentValue(key) {
        values[key] = value
      }
    }
    return values
  }

  private static func restoreSigningEnvironmentValues(_ values: [String: String]) {
    for key in signingEnvironmentKeys {
      restoreEnvironmentValue(values[key], forKey: key)
    }
  }

  private static func savedEnvironmentValue(_ key: String) -> String? {
    guard let value = getenv(key) else {
      return nil
    }
    return String(cString: value)
  }

  private static func restoreEnvironmentValue(_ value: String?, forKey key: String) {
    guard let value else {
      unsetenv(key)
      return
    }
    setenv(key, value, 1)
  }
}
