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

/// Namesake suite for environment-sensitive toolchain tests. The remaining
/// suite is written as free `@Test` functions below.
@Suite(.serialized)
enum ToolchainTests {
  private static let resultBundleDirectoryKey = "SWIFT_MK_RESULT_BUNDLE_DIR"

  @Test
  static func resultBundlePathIsAddedWhenDirectoryIsConfigured() throws {
    try withTemporaryResultBundleDirectory { resultBundleDirectory in
      let request = Toolchain.Request(
        generator: .tuist,
        scheme: "App",
        configuration: "Debug",
        workspace: "App.xcworkspace"
      )
      let args = Toolchain.xcodebuildArguments(request, action: "build")
      let path = try #require(resultBundlePath(in: args))
      #expect(args.contains("-resultBundlePath"))
      #expect(path.hasSuffix("/App-Debug.xcresult"))
      #expect(path.hasPrefix(resultBundleDirectory))
    }
  }

  @Test
  static func resultBundlePathSanitizesSchemeSpaces() throws {
    try withTemporaryResultBundleDirectory { _ in
      let request = Toolchain.Request(
        generator: .tuist,
        scheme: "Fan Curve",
        configuration: "Release",
        workspace: "FanCurveApp.xcworkspace"
      )
      let args = Toolchain.xcodebuildArguments(request, action: "build")
      let path = try #require(resultBundlePath(in: args))
      #expect(path.hasSuffix("/Fan-Curve-Release.xcresult"))
      #expect(!path.contains(" "))
    }
  }

  @Test
  static func resultBundlePathIsOmittedWhenDirectoryIsUnset() throws {
    try withResultBundleDirectory(nil) {
      let request = Toolchain.Request(
        generator: .tuist,
        scheme: "App",
        configuration: "Debug",
        workspace: "App.xcworkspace"
      )
      let args = Toolchain.xcodebuildArguments(request, action: "build")
      #expect(!args.contains("-resultBundlePath"))
    }
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
      let args = Toolchain.xcodebuildArguments(request, action: "build")
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
    try withResultBundleDirectory(resultBundleDirectory) {
      try run(resultBundleDirectory)
    }
  }

  private static func withResultBundleDirectory(
    _ value: String?,
    run: () throws -> Void
  ) rethrows {
    let previousValue = getenv(resultBundleDirectoryKey)
      .map { String(cString: $0) }
    if let value {
      setenv(resultBundleDirectoryKey, value, 1)
    } else {
      unsetenv(resultBundleDirectoryKey)
    }
    defer {
      if let previousValue {
        setenv(resultBundleDirectoryKey, previousValue, 1)
      } else {
        unsetenv(resultBundleDirectoryKey)
      }
    }
    try run()
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
  let args = Toolchain.buildArguments(request)
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
  let args = Toolchain.buildArguments(request)
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
  let args = Toolchain.xcodebuildArguments(request, action: "analyze")
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
  let args = Toolchain.xcodebuildArguments(request, action: "build-for-testing")
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
  let args = Toolchain.buildArguments(request)
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
  let args = Toolchain.xcodebuildArguments(request, action: "test")
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
  let args = Toolchain.buildArguments(request)
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
