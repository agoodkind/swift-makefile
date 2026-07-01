//
//  DeadcodeCoverageMatrixTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import PathKit
import Testing
import XcodeProj

@testable import SwiftMkCore

// MARK: - DeadcodeCoverageMatrixTests

/// Covers the pure `platforms`/`isCoverageTarget` decision helpers directly (the bulk of
/// this suite, per the task brief), plus an in-memory `XcodeProj` object graph that
/// exercises `coverageEntries` end to end: scheme resolution, build-for-testing
/// filtering, target-name matching, and the test-bundle/command-line-tool/package
/// exclusions together. The on-disk `entries(containerPath:...)` file-resolution path is
/// not covered by a written fixture here (see the task report for the reasoning); it
/// reuses `IndexCompleteness.xcodeProjectPaths` and `XcodeProj(path:)`, both already
/// exercised elsewhere, and gets its real coverage from a live consumer in a later task.
@Suite(.serialized)
enum DeadcodeCoverageMatrixTests {
  // MARK: platforms

  @Test
  static func platformsParsesASingleToken() {
    #expect(
      DeadcodeCoverageMatrix.platforms(supportedPlatforms: "macosx", supportsMacCatalyst: false)
        == [.macosx])
  }

  @Test
  static func platformsParsesSpaceSeparatedTokens() {
    #expect(
      DeadcodeCoverageMatrix.platforms(
        supportedPlatforms: "iphoneos iphonesimulator", supportsMacCatalyst: false)
        == [.iphoneos, .iphonesimulator])
  }

  @Test
  static func platformsParsesCommaSeparatedTokens() {
    #expect(
      DeadcodeCoverageMatrix.platforms(
        supportedPlatforms: "iphoneos,macosx", supportsMacCatalyst: false)
        == [.iphoneos, .macosx])
  }

  @Test
  static func platformsAddsMacCatalystWhenSupported() {
    #expect(
      DeadcodeCoverageMatrix.platforms(supportedPlatforms: "iphoneos", supportsMacCatalyst: true)
        == [.iphoneos, .maccatalyst])
  }

  @Test
  static func platformsDropsAnUnknownToken() {
    #expect(
      DeadcodeCoverageMatrix.platforms(
        supportedPlatforms: "macosx watchos", supportsMacCatalyst: false) == [.macosx])
  }

  @Test
  static func platformsIsEmptyForNilOrBlankInputWithNoMacCatalyst() {
    #expect(
      DeadcodeCoverageMatrix.platforms(supportedPlatforms: nil, supportsMacCatalyst: false)
        .isEmpty)
    #expect(
      DeadcodeCoverageMatrix.platforms(supportedPlatforms: "", supportsMacCatalyst: false)
        .isEmpty)
  }

  // MARK: isCoverageTarget

  @Test
  static func isCoverageTargetKeepsAnAppNotInThePackageSet() {
    #expect(
      DeadcodeCoverageMatrix.isCoverageTarget(
        productType: .application, name: "App", packageTargetNames: []))
  }

  @Test
  static func isCoverageTargetDropsATestBundle() {
    #expect(
      !DeadcodeCoverageMatrix.isCoverageTarget(
        productType: .unitTestBundle, name: "AppTests", packageTargetNames: []))
  }

  @Test
  static func isCoverageTargetDropsACommandLineTool() {
    #expect(
      !DeadcodeCoverageMatrix.isCoverageTarget(
        productType: .commandLineTool, name: "Tool", packageTargetNames: []))
  }

  @Test
  static func isCoverageTargetDropsAnAppNamedInThePackageSet() {
    #expect(
      !DeadcodeCoverageMatrix.isCoverageTarget(
        productType: .application, name: "PackageLib", packageTargetNames: ["PackageLib"]))
  }

  @Test
  static func isCoverageTargetKeepsAFramework() {
    #expect(
      DeadcodeCoverageMatrix.isCoverageTarget(
        productType: .framework, name: "Lib", packageTargetNames: []))
  }

  @Test
  static func isCoverageTargetDropsAnUnresolvedProductType() {
    // An unresolved product type carries no known kind, so there is no safe basis to
    // build the target for testing; this documents that choice as a test, not just a
    // comment, since a `nil` product type is easy to mistake for "unknown, so keep it".
    #expect(
      !DeadcodeCoverageMatrix.isCoverageTarget(
        productType: nil, name: "Mystery", packageTargetNames: []))
  }

  // MARK: resolvedPlatforms(for:)

  @Test
  static func resolvedPlatformsUnionsAcrossConfigurations() {
    let debug = XCBuildConfiguration(
      name: "Debug", buildSettings: ["SUPPORTED_PLATFORMS": "macosx"])
    let release = XCBuildConfiguration(
      name: "Release",
      buildSettings: ["SUPPORTED_PLATFORMS": "macosx", "SUPPORTS_MACCATALYST": "YES"])
    let configurationList = XCConfigurationList(buildConfigurations: [debug, release])
    let target = PBXNativeTarget(
      name: "App", buildConfigurationList: configurationList, productType: .application)
    #expect(DeadcodeCoverageMatrix.resolvedPlatforms(for: target) == [.macosx, .maccatalyst])
  }

  @Test
  static func resolvedPlatformsIsEmptyWithNoBuildConfigurationList() {
    let target = PBXNativeTarget(name: "App", productType: .application)
    #expect(DeadcodeCoverageMatrix.resolvedPlatforms(for: target).isEmpty)
  }

  // MARK: sharedSchemes(for:projectFile:)

  @Test
  static func sharedSchemesReadsSchemesAttachedToTheProject() {
    let scheme = makeScheme(name: "App", entries: [])
    let project = XcodeProj(
      workspace: XCWorkspace(data: XCWorkspaceData(children: [])),
      pbxproj: PBXProj(objects: []),
      sharedData: XCSharedData(schemes: [scheme]))
    let schemes = DeadcodeCoverageMatrix.sharedSchemes(
      for: project, projectFile: "/nowhere.xcodeproj")
    #expect(schemes.map(\.name) == ["App"])
  }

  // MARK: coverageEntries end to end (in-memory object graph)

  @Test
  static func coverageEntriesDerivesTheFullMatrixFromAScheme() throws {
    let fixture = makeFixtureProject()
    let entries = try DeadcodeCoverageMatrix.coverageEntries(
      scheme: fixture.scheme, project: fixture.project, packageTargetNames: ["PackageLib"])
    let pairs = Set(entries.map { "\($0.scheme)|\($0.platform.rawValue)" })
    #expect(pairs == ["App|iphoneos", "App|iphonesimulator"])
  }

  @Test
  static func coverageEntriesSkipsAnEntryNotBuiltForTesting() throws {
    let fixture = makeFixtureProject()
    let entries = try DeadcodeCoverageMatrix.coverageEntries(
      scheme: fixture.scheme, project: fixture.project, packageTargetNames: ["PackageLib"])
    #expect(!entries.contains { $0.scheme == "App" && $0.platform == .macosx })
  }

  @Test
  static func coverageEntriesSkipsAnEntryWithNoMatchingTarget() throws {
    let fixture = makeFixtureProject()
    let entries = try DeadcodeCoverageMatrix.coverageEntries(
      scheme: fixture.scheme, project: fixture.project, packageTargetNames: [])
    #expect(!entries.contains { $0.scheme == "Ghost" })
  }

  @Test
  static func coverageEntriesThrowsWhenAKeptTargetHasNoKnownPlatform() {
    let configuration = XCBuildConfiguration(name: "Debug", buildSettings: [:])
    let configurationList = XCConfigurationList(
      buildConfigurations: [configuration])
    let target = PBXNativeTarget(
      name: "NoPlatform", buildConfigurationList: configurationList, productType: .application)
    let entry = XCScheme.BuildAction.Entry(
      buildableReference: makeBuildableReference(name: "NoPlatform"), buildFor: [.testing])
    let scheme = makeScheme(name: "NoPlatform", entries: [entry])
    let objects: [PBXObject] = [target, configurationList, configuration]
    let project = XcodeProj(
      workspace: XCWorkspace(data: XCWorkspaceData(children: [])),
      pbxproj: PBXProj(objects: objects),
      sharedData: XCSharedData(schemes: [scheme]))
    #expect(throws: DeadcodeCoverageMatrix.EnumerationError.self) {
      try DeadcodeCoverageMatrix.coverageEntries(
        scheme: scheme, project: project, packageTargetNames: [])
    }
  }

  // MARK: autoSchemeEntries (no shared schemes)

  @Test
  static func autoSchemeEntriesDerivesOneSchemePerBuildableNativeTarget() throws {
    let project = makeNoSharedSchemeProject()
    let entries = try DeadcodeCoverageMatrix.autoSchemeEntries(
      project: project, packageTargetNames: ["PackageLib"])
    let pairs = Set(entries.map { "\($0.scheme)|\($0.platform.rawValue)" })
    // The two macOS app/helper targets each become a same-named auto-scheme; the test
    // bundle, the command-line tool, and the package target drop out.
    #expect(pairs == ["Helper|macosx", "MainApp|macosx"])
  }

  @Test
  static func autoSchemeEntriesThrowsWhenAKeptTargetHasNoKnownPlatform() {
    let noPlatformTarget = PBXNativeTarget(name: "NoPlatform", productType: .application)
    let project = XcodeProj(
      workspace: XCWorkspace(data: XCWorkspaceData(children: [])),
      pbxproj: PBXProj(objects: [noPlatformTarget]),
      sharedData: nil)
    #expect(throws: DeadcodeCoverageMatrix.EnumerationError.self) {
      try DeadcodeCoverageMatrix.autoSchemeEntries(
        project: project, packageTargetNames: [])
    }
  }

  /// A project with no shared schemes and four native targets: two macOS
  /// app/helper targets that must each become an auto-scheme, plus a test bundle, a
  /// command-line tool, and a package-owned framework that must all drop out. This is
  /// the xcodegen shape, where `xcodebuild -list` reports auto-created schemes but no
  /// `xcshareddata` scheme file exists.
  static func makeNoSharedSchemeProject() -> XcodeProj {
    let mainConfiguration = XCBuildConfiguration(
      name: "Debug", buildSettings: ["SUPPORTED_PLATFORMS": "macosx"])
    let mainConfigurationList = XCConfigurationList(buildConfigurations: [mainConfiguration])
    let mainTarget = PBXNativeTarget(
      name: "MainApp",
      buildConfigurationList: mainConfigurationList,
      productType: .application)
    let helperConfiguration = XCBuildConfiguration(
      name: "Debug", buildSettings: ["SUPPORTED_PLATFORMS": "macosx"])
    let helperConfigurationList = XCConfigurationList(
      buildConfigurations: [helperConfiguration])
    let helperTarget = PBXNativeTarget(
      name: "Helper",
      buildConfigurationList: helperConfigurationList,
      productType: .application)
    let testsTarget = PBXNativeTarget(name: "AppTests", productType: .unitTestBundle)
    let toolTarget = PBXNativeTarget(name: "Tool", productType: .commandLineTool)
    let packageConfiguration = XCBuildConfiguration(
      name: "Debug", buildSettings: ["SUPPORTED_PLATFORMS": "macosx"])
    let packageConfigurationList = XCConfigurationList(
      buildConfigurations: [packageConfiguration])
    let packageTarget = PBXNativeTarget(
      name: "PackageLib",
      buildConfigurationList: packageConfigurationList,
      productType: .framework)
    let objects: [PBXObject] = [
      mainTarget, helperTarget, testsTarget, toolTarget, packageTarget,
      mainConfigurationList, helperConfigurationList, packageConfigurationList,
      mainConfiguration, helperConfiguration, packageConfiguration,
    ]
    return XcodeProj(
      workspace: XCWorkspace(data: XCWorkspaceData(children: [])),
      pbxproj: PBXProj(objects: objects),
      sharedData: nil)
  }

  // MARK: fixture builders

  /// A `BuildableReference` matched by name only, the same resolution
  /// `coverageEntries` uses: no `PBXObject` blueprint link required.
  static func makeBuildableReference(name: String) -> XCScheme.BuildableReference {
    XCScheme.BuildableReference(
      referencedContainer: "container:Fixture.xcodeproj",
      blueprintIdentifier: nil,
      buildableName: "\(name).app",
      blueprintName: name)
  }

  static func makeScheme(name: String, entries: [XCScheme.BuildAction.Entry]) -> XCScheme {
    XCScheme(
      name: name,
      lastUpgradeVersion: nil,
      version: nil,
      buildAction: XCScheme.BuildAction(buildActionEntries: entries))
  }

  /// One project with four targets exercising every exclusion the derivation rule
  /// makes (an app, its test bundle, a command-line tool, and a SwiftPM package
  /// target), plus a build-for-testing-only entry, a build-for-running-only entry, and
  /// an entry naming a target absent from the project.
  static func makeFixtureProject() -> (project: XcodeProj, scheme: XCScheme) {
    let appConfiguration = XCBuildConfiguration(
      name: "Debug",
      buildSettings: ["SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"])
    let appConfigurationList = XCConfigurationList(
      buildConfigurations: [appConfiguration])
    let appTarget = PBXNativeTarget(
      name: "App", buildConfigurationList: appConfigurationList, productType: .application)
    let testsTarget = PBXNativeTarget(name: "AppTests", productType: .unitTestBundle)
    let toolTarget = PBXNativeTarget(name: "Tool", productType: .commandLineTool)
    let packageConfiguration = XCBuildConfiguration(
      name: "Debug",
      buildSettings: ["SUPPORTED_PLATFORMS": "macosx"])
    let packageConfigurationList = XCConfigurationList(
      buildConfigurations: [packageConfiguration])
    let packageTarget = PBXNativeTarget(
      name: "PackageLib",
      buildConfigurationList: packageConfigurationList,
      productType: .framework)

    let entries = [
      XCScheme.BuildAction.Entry(
        buildableReference: makeBuildableReference(name: "App"),
        buildFor: [.testing, .running]),
      XCScheme.BuildAction.Entry(
        buildableReference: makeBuildableReference(name: "AppTests"), buildFor: [.testing]),
      XCScheme.BuildAction.Entry(
        buildableReference: makeBuildableReference(name: "Tool"), buildFor: [.testing]),
      XCScheme.BuildAction.Entry(
        buildableReference: makeBuildableReference(name: "PackageLib"), buildFor: [.testing]),
      XCScheme.BuildAction.Entry(
        buildableReference: makeBuildableReference(name: "App"), buildFor: [.running]),
      XCScheme.BuildAction.Entry(
        buildableReference: makeBuildableReference(name: "Ghost"), buildFor: [.testing]),
    ]
    let scheme = makeScheme(name: "App", entries: entries)

    let objects: [PBXObject] =
      [
        appTarget, testsTarget, toolTarget, packageTarget, appConfigurationList,
        packageConfigurationList, appConfiguration, packageConfiguration,
      ]
    let project = XcodeProj(
      workspace: XCWorkspace(data: XCWorkspaceData(children: [])),
      pbxproj: PBXProj(objects: objects),
      sharedData: XCSharedData(schemes: [scheme]))
    return (project, scheme)
  }
}
