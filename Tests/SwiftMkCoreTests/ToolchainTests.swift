//
//  ToolchainTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ToolchainTests

/// Namesake suite for result-bundle toolchain tests. The remaining
/// suite is written as free `@Test` functions below.
@Suite(.serialized)
enum ToolchainTests {
  @Test
  static func resultBundlePathIsAddedWhenDirectoryIsConfigured() throws {
    try withTemporaryResultBundleDirectory { resultBundleDirectory in
      let request = Toolchain.Request(
        generator: .tuist,
        scheme: "App",
        configuration: "Debug",
        workspace: "App.xcworkspace"
      )
      let args = Toolchain.xcodebuildArguments(
        request, actions: ["build"], resultBundleDirectory: resultBundleDirectory)
      let path = try #require(resultBundlePath(in: args))
      #expect(args.contains("-resultBundlePath"))
      #expect(path.hasSuffix("/App-Debug.xcresult"))
      #expect(path.hasPrefix(resultBundleDirectory))
    }
  }

  @Test
  static func resultBundlePathSanitizesSchemeSpaces() throws {
    try withTemporaryResultBundleDirectory { resultBundleDirectory in
      let request = Toolchain.Request(
        generator: .tuist,
        scheme: "Fan Curve",
        configuration: "Release",
        workspace: "FanCurveApp.xcworkspace"
      )
      let args = Toolchain.xcodebuildArguments(
        request, actions: ["build"], resultBundleDirectory: resultBundleDirectory)
      let path = try #require(resultBundlePath(in: args))
      #expect(path.hasSuffix("/Fan-Curve-Release.xcresult"))
      #expect(!path.contains(" "))
    }
  }

  @Test
  static func resultBundlePathIsOmittedWhenDirectoryIsUnset() {
    #expect(Env.get("SWIFT_MK_RESULT_BUNDLE_DIR").isEmpty)
    let request = Toolchain.Request(
      generator: .tuist,
      scheme: "App",
      configuration: "Debug",
      workspace: "App.xcworkspace"
    )
    let args = Toolchain.xcodebuildArguments(
      request, actions: ["build"], resultBundleDirectory: nil)
    #expect(!args.contains("-resultBundlePath"))
  }

  @Test
  static func resultBundlePathRemovesPreexistingDirectory() throws {
    try withTemporaryResultBundleDirectory { resultBundleDirectory in
      let expectedPath = (resultBundleDirectory as NSString).appendingPathComponent(
        "App-Debug.xcresult")
      try FileManager.default.createDirectory(
        atPath: expectedPath, withIntermediateDirectories: true)
      let request = Toolchain.Request(
        generator: .tuist,
        scheme: "App",
        configuration: "Debug",
        workspace: "App.xcworkspace"
      )
      let args = Toolchain.xcodebuildArguments(
        request, actions: ["build"], resultBundleDirectory: resultBundleDirectory)
      let path = try #require(resultBundlePath(in: args))
      #expect(path == expectedPath)
      #expect(!FileManager.default.fileExists(atPath: expectedPath))
    }
  }

  private static func resultBundlePath(in args: [String]) -> String? {
    guard let flagIndex = args.firstIndex(of: "-resultBundlePath") else {
      return nil
    }
    let pathIndex = args.index(after: flagIndex)
    guard pathIndex < args.endIndex else {
      return nil
    }
    return args[pathIndex]
  }

  private static func withTemporaryResultBundleDirectory(
    _ run: (String) throws -> Void
  ) throws {
    let resultBundleDirectory =
      NSTemporaryDirectory()
      + "swiftmk-result-bundle-"
      + UUID().uuidString
    try FileManager.default.createDirectory(
      atPath: resultBundleDirectory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(
        atPath: resultBundleDirectory)
    }
    try run(resultBundleDirectory)
  }
}

@Test
func toolchainTuistBuildNamesWorkspaceNeverAutoDiscovers() {
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "App",
    configuration: "Debug",
    workspace: "App.xcworkspace"
  )
  let args = Toolchain.xcodebuildArguments(request, actions: ["build"])
  // The explicit -workspace is the Automerge-break fix: xcodebuild must not
  // auto-discover the bare app project.
  #expect(args.contains("-workspace"))
  #expect(args.contains("App.xcworkspace"))
  #expect(!args.contains("-project"))
  #expect(args.contains("-scheme"))
  #expect(args.contains("App"))
  #expect(args.last == "build")
}

@Test
func toolchainTuistBuildPassesDerivedDataAndSettingsForPackaging() {
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "FanCurve",
    configuration: "Debug",
    workspace: "FanCurveApp.xcworkspace",
    derivedDataPath: "build",
    extraSettings: ["SMC_FAN_HELPER_APP": "/tmp/Helper.app"]
  )
  let args = Toolchain.xcodebuildArguments(request, actions: ["build"])
  // A consumer that packages its product needs a known -derivedDataPath, which
  // `tuist build` cannot provide; the xcodebuild -workspace form can.
  #expect(args.contains("-derivedDataPath"))
  #expect(args.contains("build"))
  #expect(args.contains("SMC_FAN_HELPER_APP=/tmp/Helper.app"))
}

@Test
func toolchainTuistTestUsesNativeTuistWithSelectiveTestingDisabled() {
  let request = Toolchain.Request(generator: .tuist, scheme: "App", configuration: "Debug")
  let args = Toolchain.tuistTestArguments(request)
  #expect(args == ["test", "App", "--configuration", "Debug", "--no-selective-testing"])
}

@Test
func toolchainTuistTestPinsDerivedDataPathWhenSet() {
  // The test path pins DerivedData to the same place build/coverage use, so
  // `tuist test` no longer falls back to system DerivedData and desyncs.
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "App",
    configuration: "Debug",
    derivedDataPath: ".derived-data"
  )
  let args = Toolchain.tuistTestArguments(request)
  #expect(
    args == [
      "test", "App", "--configuration", "Debug", "--no-selective-testing",
      "--derived-data-path", ".derived-data",
    ])
}

@Test
func toolchainTuistTestForwardsExtraSettingsAfterPassthroughSeparator() {
  // A setting injected at test time (a helper-app path) must reach xcodebuild.
  // `tuist test` documents `-- <xcodebuild args>` passthrough, so the setting
  // goes after a single `--`, never before it.
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "FanCurve",
    configuration: "Debug",
    workspace: "FanCurveApp.xcworkspace",
    derivedDataPath: "build",
    extraSettings: ["SMC_FAN_HELPER_APP": "/tmp/Helper.app"]
  )
  let args = Toolchain.tuistTestArguments(request)
  #expect(
    args == [
      "test", "FanCurve", "--configuration", "Debug", "--no-selective-testing",
      "--derived-data-path", "build", "--", "SMC_FAN_HELPER_APP=/tmp/Helper.app",
    ])
}

@Test
func toolchainTuistTestOmitsPassthroughSeparatorWithoutSettings() {
  // No extra settings means no trailing `--`, so the existing zero-setting test
  // path is unchanged.
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "App",
    configuration: "Debug",
    workspace: "App.xcworkspace"
  )
  #expect(!Toolchain.tuistTestArguments(request).contains("--"))
}

@Test
func toolchainPassesExtraArgumentsForAnalyze() {
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "Agent",
    configuration: "Debug",
    workspace: "App.xcworkspace",
    extraArguments: ["-allowProvisioningUpdates"]
  )
  let args = Toolchain.xcodebuildArguments(request, actions: ["analyze"])
  #expect(args.contains("-allowProvisioningUpdates"))
  #expect(args.last == "analyze")
}

@Test
func toolchainSigningEnvironmentRespectsExistingOverride() {
  setenv("XCODE_XCCONFIG_FILE", "/tmp/existing-signing.xcconfig", 1)
  defer { unsetenv("XCODE_XCCONFIG_FILE") }
  #expect(Toolchain.signingEnvironment().isEmpty)
}

@Test
func toolchainBuildForTestingNamesWorkspaceAndAction() {
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "App",
    configuration: "Debug",
    workspace: "App.xcworkspace",
    derivedDataPath: "build",
    extraSettings: ["COMPILER_INDEX_STORE_ENABLE": "YES"]
  )
  let args = Toolchain.xcodebuildArguments(request, actions: ["build-for-testing"])
  #expect(args.contains("-workspace"))
  #expect(args.contains("App.xcworkspace"))
  #expect(args.contains("COMPILER_INDEX_STORE_ENABLE=YES"))
  #expect(args.last == "build-for-testing")
}

@Test
func toolchainXcodegenBuildNamesProjectNeverAutoDiscovers() {
  let request = Toolchain.Request(
    generator: .xcodegen,
    scheme: "Helper",
    configuration: "Release",
    project: "App.xcodeproj"
  )
  let args = Toolchain.xcodebuildArguments(request, actions: ["build"])
  #expect(args.contains("-project"))
  #expect(args.contains("App.xcodeproj"))
  #expect(!args.contains("-workspace"))
  #expect(args.contains("-scheme"))
  #expect(args.contains("Helper"))
  #expect(args.last == "build")
}

@Test
func toolchainXcodegenTestNamesProjectAndAction() {
  let request = Toolchain.Request(
    generator: .xcodegen,
    scheme: "Helper",
    configuration: "Debug",
    project: "App.xcodeproj"
  )
  let args = Toolchain.xcodebuildArguments(request, actions: ["test"])
  #expect(args.contains("-project"))
  #expect(args.contains("App.xcodeproj"))
  #expect(args.last == "test")
}

@Test
func toolchainCleanBuildAppendsBothActionsInOrder() {
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "Agent",
    configuration: "Debug",
    workspace: "App.xcworkspace",
    derivedDataPath: "build/Analyze/DerivedData"
  )
  let args = Toolchain.xcodebuildArguments(request, actions: ["clean", "build"])
  // The swiftlint analyze compiler-log build runs clean then build in one
  // invocation; both actions go last, in order, after the container and settings.
  #expect(args.suffix(2) == ["clean", "build"])
  #expect(args.contains("-workspace"))
  #expect(args.contains("App.xcworkspace"))
  #expect(args.contains("-derivedDataPath"))
}

@Test
func toolchainTuistBuildWithoutWorkspaceDegradesNotAutoDiscovers() {
  // A tuist build with no workspace is a programmer error; the assembler must
  // never emit a bare `build` that lets xcodebuild auto-discover a container.
  let request = Toolchain.Request(generator: .tuist, scheme: "App")
  let args = Toolchain.xcodebuildArguments(request, actions: ["build"])
  #expect(!args.contains("-scheme"))
  #expect(args == ["-version"])
}

@Test
func toolchainRejectsSigningSettingInExtraSettings() {
  // swift-mk owns signing via the XCODE_XCCONFIG_FILE override; a command-line
  // CODE_SIGN_IDENTITY would out-rank it, so the chokepoint rejects it.
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "App",
    workspace: "App.xcworkspace",
    extraSettings: ["CODE_SIGN_IDENTITY": "Apple Development"]
  )
  #expect(Toolchain.forbiddenSigningSetting(in: request) == "CODE_SIGN_IDENTITY")
}

@Test
func toolchainRejectsSigningSettingInExtraArguments() {
  // A signing setting can also arrive as a bare KEY=value passthrough argument.
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "App",
    workspace: "App.xcworkspace",
    extraArguments: ["-allowProvisioningUpdates", "DEVELOPMENT_TEAM=H3BMXM4W7H"]
  )
  #expect(Toolchain.forbiddenSigningSetting(in: request) == "DEVELOPMENT_TEAM")
}

@Test
func toolchainRejectsSigningSettingCaseInsensitively() {
  // Matching uppercases the incoming key so an oddly-cased setting is still caught.
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "App",
    workspace: "App.xcworkspace",
    extraSettings: ["Code_Sign_Style": "Manual"]
  )
  #expect(Toolchain.forbiddenSigningSetting(in: request) == "Code_Sign_Style")
}

@Test
func toolchainAllowsNonSigningSettings() {
  // Non-signing settings and flags pass through untouched: only signing keys are
  // forbidden, so packaging and index-store settings still reach xcodebuild.
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "App",
    workspace: "App.xcworkspace",
    extraSettings: [
      "COMPILER_INDEX_STORE_ENABLE": "YES", "SMC_FAN_HELPER_APP": "/tmp/Helper.app",
    ],
    extraArguments: ["-allowProvisioningUpdates"]
  )
  #expect(Toolchain.forbiddenSigningSetting(in: request) == nil)
}

@Test
func toolchainBuildReturnsRejectionStatusForSigningSetting() {
  // The build entry point fails loudly with the rejection status rather than
  // running xcodebuild when a signing setting is present.
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "App",
    workspace: "App.xcworkspace",
    extraSettings: ["CODE_SIGN_IDENTITY": "Developer ID Application"]
  )
  #expect(Toolchain.build(request) == Toolchain.signingOverrideRejectionStatus)
}

// MARK: - Xcode-app DerivedData redirect tests

@Suite(.serialized)
enum ToolchainGuiDerivedDataTests {
  @Test
  static func redirectSettingsUseAbsolutePathKeys() {
    let settings = Toolchain.derivedDataRedirectSettings(
      derivedDataPath: "/repo/.derived-data")
    #expect(settings["DerivedDataLocationStyle"] == "AbsolutePath")
    #expect(settings["DerivedDataCustomLocation"] == "/repo/.derived-data")
    #expect(settings["BuildLocationStyle"] == "UseAppPreferences")
  }

  @Test
  static func findsTuistWorkspaceInDirectory() throws {
    try withTemporaryDirectory { dir in
      let workspace = (dir as NSString).appendingPathComponent("App.xcworkspace")
      try FileManager.default.createDirectory(
        atPath: workspace, withIntermediateDirectories: true)
      #expect(Toolchain.generatedWorkspacePath(generator: .tuist, in: dir) == workspace)
    }
  }

  @Test
  static func findsXcodegenEmbeddedWorkspace() throws {
    try withTemporaryDirectory { dir in
      let project = (dir as NSString).appendingPathComponent("App.xcodeproj")
      try FileManager.default.createDirectory(
        atPath: project, withIntermediateDirectories: true)
      let found = Toolchain.generatedWorkspacePath(generator: .xcodegen, in: dir)
      #expect(found == project + "/project.xcworkspace")
    }
  }

  @Test
  static func writesReadablePlistAtUserSettingsPath() throws {
    try withTemporaryDirectory { dir in
      let workspace = (dir as NSString).appendingPathComponent("App.xcworkspace")
      try FileManager.default.createDirectory(
        atPath: workspace, withIntermediateDirectories: true)
      try Toolchain.writeDerivedDataRedirect(
        workspace: workspace, derivedDataPath: "/abs/.derived-data")
      let settingsPath =
        workspace
        + "/xcuserdata/\(NSUserName()).xcuserdatad/WorkspaceSettings.xcsettings"
      let data = try #require(FileManager.default.contents(atPath: settingsPath))
      let plist =
        try PropertyListSerialization.propertyList(
          from: data,
          options: [],
          format: nil) as? [String: Any]
      #expect(plist?["DerivedDataLocationStyle"] as? String == "AbsolutePath")
      #expect(plist?["DerivedDataCustomLocation"] as? String == "/abs/.derived-data")
    }
  }

  @Test
  static func resolvedDerivedDataHonorsAbsoluteEnv() {
    let prior = ProcessInfo.processInfo.environment["SWIFT_MK_DERIVED_DATA"]
    setenv("SWIFT_MK_DERIVED_DATA", "/custom/.derived-data", 1)
    defer {
      if let prior {
        setenv("SWIFT_MK_DERIVED_DATA", prior, 1)
      } else {
        unsetenv("SWIFT_MK_DERIVED_DATA")
      }
    }
    #expect(Toolchain.resolvedDerivedDataPath() == "/custom/.derived-data")
  }

  private static func withTemporaryDirectory(_ run: (String) throws -> Void) throws {
    let dir = NSTemporaryDirectory() + "swiftmk-gui-dd-" + UUID().uuidString
    try FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try run(dir)
  }
}
