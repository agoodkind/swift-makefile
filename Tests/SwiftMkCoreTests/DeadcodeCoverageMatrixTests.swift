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

/// Covers scheme selection (`isCoverageTarget`, `schemeHasCoverageTarget`) over an
/// in-memory `XcodeProj` object graph, and `entries` end to end with an injected
/// platform source, so the matrix logic is exercised without shelling xcodebuild. The
/// on-disk `coverageSchemeNames(containerPath:...)` file-resolution path is not covered
/// by a written fixture here; it reuses `IndexCompleteness.xcodeProjectPaths` and
/// `XcodeProj(path:)`, both exercised elsewhere, and gets real coverage from a live
/// consumer.
@Suite(.serialized)
enum DeadcodeCoverageMatrixTests {
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
    #expect(
      !DeadcodeCoverageMatrix.isCoverageTarget(
        productType: nil, name: "Mystery", packageTargetNames: []))
  }

  // MARK: schemeHasCoverageTarget

  @Test
  static func schemeHasCoverageTargetIsTrueForAnAppSchemeBuiltForTesting() {
    let fixture = makeFixtureProject()
    #expect(
      DeadcodeCoverageMatrix.schemeHasCoverageTarget(
        fixture.scheme, project: fixture.project, packageTargetNames: ["PackageLib"]))
  }

  @Test
  static func schemeHasCoverageTargetIsFalseWhenOnlyExcludedTargetsBuildForTesting() {
    let fixture = makeTestOnlyScheme()
    #expect(
      !DeadcodeCoverageMatrix.schemeHasCoverageTarget(
        fixture.scheme, project: fixture.project, packageTargetNames: []))
  }

  // MARK: expandPlatforms with an injected platform source

  @Test
  static func expandPlatformsExpandsEachSchemeAcrossItsInjectedPlatforms() throws {
    let entries = try DeadcodeCoverageMatrix.expandPlatforms(schemeNames: ["App"]) { _ in
      [.iphonesimulator, .maccatalyst]
    }
    let pairs = Set(entries.map { "\($0.scheme)|\($0.platform.rawValue)" })
    #expect(pairs == ["App|iphonesimulator", "App|maccatalyst"])
  }

  @Test
  static func expandPlatformsThrowsWhenASchemeReportsNoCoveragePlatform() {
    #expect(throws: DeadcodeCoverageMatrix.EnumerationError.self) {
      try DeadcodeCoverageMatrix.expandPlatforms(schemeNames: ["App"]) { _ in [] }
    }
  }

  @Test
  static func expandPlatformsIsSortedAndDeduplicated() throws {
    let entries = try DeadcodeCoverageMatrix.expandPlatforms(
      schemeNames: ["Beta", "Alpha"]
    ) { _ in [.macosx] }
    #expect(entries.map(\.scheme) == ["Alpha", "Beta"])
    #expect(entries.allSatisfy { $0.platform == .macosx })
  }

  // MARK: fixtures

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

  /// A project whose "App" scheme builds an app, its test bundle, a command-line tool,
  /// and a package framework for testing, so scheme selection keeps the scheme on the
  /// strength of the app alone.
  static func makeFixtureProject() -> (project: XcodeProj, scheme: XCScheme) {
    let appTarget = PBXNativeTarget(name: "App", productType: .application)
    let testsTarget = PBXNativeTarget(name: "AppTests", productType: .unitTestBundle)
    let toolTarget = PBXNativeTarget(name: "Tool", productType: .commandLineTool)
    let packageTarget = PBXNativeTarget(name: "PackageLib", productType: .framework)
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
    ]
    let scheme = makeScheme(name: "App", entries: entries)
    let objects: [PBXObject] = [appTarget, testsTarget, toolTarget, packageTarget]
    let project = XcodeProj(
      workspace: XCWorkspace(data: XCWorkspaceData(children: [])),
      pbxproj: PBXProj(objects: objects),
      sharedData: XCSharedData(schemes: [scheme]))
    return (project, scheme)
  }

  /// A scheme whose only build-for-testing entry is a test bundle, so it contributes no
  /// coverage target.
  static func makeTestOnlyScheme() -> (project: XcodeProj, scheme: XCScheme) {
    let testsTarget = PBXNativeTarget(name: "OnlyTests", productType: .unitTestBundle)
    let entries = [
      XCScheme.BuildAction.Entry(
        buildableReference: makeBuildableReference(name: "OnlyTests"), buildFor: [.testing])
    ]
    let scheme = makeScheme(name: "OnlyTests", entries: entries)
    let project = XcodeProj(
      workspace: XCWorkspace(data: XCWorkspaceData(children: [])),
      pbxproj: PBXProj(objects: [testsTarget]),
      sharedData: XCSharedData(schemes: [scheme]))
    return (project, scheme)
  }
}

// MARK: - DeadcodeCoverageMatrixDestinationTests

/// Covers `coveragePlatforms` and its helpers, the pure parser that reads an
/// `xcodebuild -showdestinations` transcript into the coverage platform set. This is the
/// authoritative platform source, so the parser is tested against the real transcript
/// shape, including the ineligible section and Mac Catalyst variant.
@Suite(.serialized)
enum DeadcodeCoverageMatrixDestinationTests {
  // MARK: coveragePlatform mapper

  @Test
  static func coveragePlatformMapsMacOS() {
    #expect(DeadcodeCoverageMatrix.coveragePlatform(platform: "macOS", variant: nil) == .macosx)
  }

  @Test
  static func coveragePlatformMapsMacCatalystVariant() {
    #expect(
      DeadcodeCoverageMatrix.coveragePlatform(platform: "macOS", variant: "Mac Catalyst")
        == .maccatalyst)
  }

  @Test
  static func coveragePlatformMapsIOSAndSimulatorToSimulator() {
    #expect(
      DeadcodeCoverageMatrix.coveragePlatform(platform: "iOS Simulator", variant: nil)
        == .iphonesimulator)
    #expect(
      DeadcodeCoverageMatrix.coveragePlatform(platform: "iOS", variant: nil) == .iphonesimulator)
  }

  @Test
  static func coveragePlatformIgnoresUnsupportedPlatforms() {
    #expect(DeadcodeCoverageMatrix.coveragePlatform(platform: "watchOS", variant: nil) == nil)
    #expect(DeadcodeCoverageMatrix.coveragePlatform(platform: "DriverKit", variant: nil) == nil)
  }

  // MARK: destinationField

  @Test
  static func destinationFieldReadsAValueWithSpaces() {
    let line = "{ platform:iOS Simulator, arch:arm64, id:ABC, name:iPhone 17 }"
    #expect(DeadcodeCoverageMatrix.destinationField("platform", in: line) == "iOS Simulator")
    #expect(DeadcodeCoverageMatrix.destinationField("arch", in: line) == "arm64")
  }

  @Test
  static func destinationFieldReadsTheMacCatalystVariant() {
    let line = "{ platform:macOS, arch:arm64, variant:Mac Catalyst, id:XYZ, name:My Mac }"
    #expect(DeadcodeCoverageMatrix.destinationField("variant", in: line) == "Mac Catalyst")
  }

  @Test
  static func destinationFieldIsNilForAnAbsentKey() {
    let line = "{ platform:macOS, name:My Mac }"
    #expect(DeadcodeCoverageMatrix.destinationField("variant", in: line) == nil)
  }

  // MARK: coveragePlatforms parser

  @Test
  static func coveragePlatformsReadsAnIOSPlusCatalystScheme() {
    // The real CellTunnelPhone transcript shape: Mac Catalyst, an iOS device
    // placeholder, and many iOS simulators. The result is the base iOS simulator plus
    // Mac Catalyst, so the iPhone build compiles the non-Catalyst branch.
    let output = """
        Available destinations for the "PhoneApp" scheme:
      \t\t{ platform:macOS, arch:arm64, variant:Mac Catalyst, id:00, name:My Mac }
      \t\t{ platform:iOS, id:dvtdevice-...:placeholder, name:Any iOS Device }
      \t\t{ platform:iOS Simulator, id:dvt-...:placeholder, name:Any iOS Simulator Device }
      \t\t{ platform:iOS Simulator, arch:arm64, id:AA, OS:26.5, name:iPhone 17 }
      """
    #expect(
      DeadcodeCoverageMatrix.coveragePlatforms(showDestinationsOutput: output)
        == [.iphonesimulator, .maccatalyst])
  }

  @Test
  static func coveragePlatformsReadsAMacOnlyScheme() {
    let output = """
        Available destinations for the "Helper" scheme:
      \t\t{ platform:macOS, arch:arm64, id:00, name:My Mac }
      """
    #expect(
      DeadcodeCoverageMatrix.coveragePlatforms(showDestinationsOutput: output) == [.macosx])
  }

  @Test
  static func coveragePlatformsIgnoresTheIneligibleSection() {
    // A destination under "Ineligible destinations" must never enter the matrix, so a
    // scheme whose only iOS destination is ineligible does not gain the iOS platform.
    let output = """
        Available destinations for the "MacApp" scheme:
      \t\t{ platform:macOS, arch:arm64, id:00, name:My Mac }
        Ineligible destinations for the "MacApp" scheme:
      \t\t{ platform:iOS Simulator, id:11, name:iPhone 17, error:unavailable }
      """
    #expect(
      DeadcodeCoverageMatrix.coveragePlatforms(showDestinationsOutput: output) == [.macosx])
  }

  @Test
  static func coveragePlatformsIsEmptyForNoUsableDestinations() {
    let output = """
        Available destinations for the "Watch" scheme:
      \t\t{ platform:watchOS Simulator, arch:arm64, id:00, name:Apple Watch }
      """
    #expect(
      DeadcodeCoverageMatrix.coveragePlatforms(showDestinationsOutput: output).isEmpty)
  }
}
