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

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `ToolchainTests.swift`; the suite is written as free `@Test` functions.
enum ToolchainTests {}

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
func toolchainTuistBuildWithoutWorkspaceDegradesNotAutoDiscovers() {
    // A tuist build with no workspace is a programmer error; the assembler must
    // never emit a bare `build` that lets xcodebuild auto-discover a container.
    let request = Toolchain.Request(generator: .tuist, scheme: "App")
    let args = Toolchain.buildArguments(request)
    #expect(!args.contains("-scheme"))
    #expect(args == ["-version"])
}
