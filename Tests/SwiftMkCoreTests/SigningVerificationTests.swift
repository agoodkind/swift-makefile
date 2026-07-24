//
//  SigningVerificationTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - SigningVerificationTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `SigningVerificationTests.swift`; the suite is written as free `@Test` functions.
enum SigningVerificationTests {}

@Test
func artifactAdHocPassesWhenAdHocExpected() {
  let output = "Signature=adhoc\nTeamIdentifier=not set\n"
  #expect(
    SigningVerification.artifactSignatureSatisfies(
      output: output, status: 0, expectAdHoc: true, expectedTeam: ""))
}

@Test
func artifactAdHocFailsWhenTeamExpected() {
  let output = "Signature=adhoc\nTeamIdentifier=not set\n"
  #expect(
    !SigningVerification.artifactSignatureSatisfies(
      output: output, status: 0, expectAdHoc: false, expectedTeam: "H3BMXM4W7H"))
}

@Test
func artifactTeamMatchPasses() {
  let output = "Authority=Apple Development\nTeamIdentifier=H3BMXM4W7H\n"
  #expect(
    SigningVerification.artifactSignatureSatisfies(
      output: output, status: 0, expectAdHoc: false, expectedTeam: "H3BMXM4W7H"))
}

@Test
func artifactTeamMismatchFails() {
  let output = "TeamIdentifier=WRONG00000\n"
  #expect(
    !SigningVerification.artifactSignatureSatisfies(
      output: output, status: 0, expectAdHoc: false, expectedTeam: "H3BMXM4W7H"))
}

@Test
func artifactNonZeroStatusFails() {
  #expect(
    !SigningVerification.artifactSignatureSatisfies(
      output: "", status: 1, expectAdHoc: false, expectedTeam: "H3BMXM4W7H"))
}

@Test
func settingsMatchPassesForDeveloperSigning() {
  let output =
    "CODE_SIGN_IDENTITY = Apple Development\n"
    + "CODE_SIGN_STYLE = Automatic\n"
    + "DEVELOPMENT_TEAM = H3BMXM4W7H\n"
  #expect(
    SigningVerification.settingsMatch(
      output: output, expectedIdentity: "Apple Development", expectedTeam: "H3BMXM4W7H"))
}

@Test
func settingsMatchFailsWhenTargetIsAdHoc() {
  let output = "CODE_SIGN_IDENTITY = -\nDEVELOPMENT_TEAM = H3BMXM4W7H\n"
  #expect(
    !SigningVerification.settingsMatch(
      output: output, expectedIdentity: "Apple Development", expectedTeam: "H3BMXM4W7H"))
}

@Test
func settingsMatchFailsOnWrongTeam() {
  let output =
    "CODE_SIGN_IDENTITY = Apple Development\nDEVELOPMENT_TEAM = WRONG00000\n"
  #expect(
    !SigningVerification.settingsMatch(
      output: output, expectedIdentity: "Apple Development", expectedTeam: "H3BMXM4W7H"))
}

@Test
func settingsMatchAdHocContextAcceptsDashAndRejectsRealIdentity() {
  #expect(
    SigningVerification.settingsMatch(
      output: "CODE_SIGN_IDENTITY = -\n", expectedIdentity: "-", expectedTeam: ""))
  #expect(
    !SigningVerification.settingsMatch(
      output: "CODE_SIGN_IDENTITY = Apple Development\n",
      expectedIdentity: "-",
      expectedTeam: ""))
}

// MARK: - Product discovery

@Test
func simulatorProductDetectedByConfigurationDirectorySuffix() {
  #expect(
    SigningVerification.isSimulatorProduct(
      path: "Products/Debug-iphonesimulator/CellTunnelPhone.app"))
  #expect(
    SigningVerification.isSimulatorProduct(
      path: "/abs/Products/Release-appletvsimulator/App.app"))
  #expect(
    SigningVerification.isSimulatorProduct(
      path: "Products/Debug-watchsimulator/App.app"))
}

@Test
func deviceMacAndCatalystProductsAreNotSimulator() {
  #expect(
    !SigningVerification.isSimulatorProduct(
      path: "Products/Debug-iphoneos/CellTunnelPhone.app"))
  #expect(
    !SigningVerification.isSimulatorProduct(path: "Products/Debug/CellTunnelAgent.app"))
  #expect(
    !SigningVerification.isSimulatorProduct(
      path: "Products/Debug-maccatalyst/CellTunnelPhone.app"))
}

@Test
func simulatorDetectionIgnoresUnrelatedAncestorDirectories() {
  // A device product whose ancestor directory merely ends in a simulator suffix
  // is not a simulator product; only the app's enclosing configuration directory
  // decides.
  #expect(
    !SigningVerification.isSimulatorProduct(
      path: "/w/test-iphonesimulator/Products/Debug-iphoneos/CellTunnelPhone.app"))
  #expect(
    SigningVerification.isSimulatorProduct(
      path: "/w/anything/Products/Debug-iphonesimulator/CellTunnelPhone.app"))
}

@Test
func discoverAppBundlesFindsTopLevelAppsAcrossPlatformDirectories() throws {
  try withTemporaryProductsTree { root, fileManager in
    for relative in [
      "Debug/CellTunnelAgent.app",
      "Debug-iphoneos/CellTunnelPhone.app",
      "Debug-iphonesimulator/CellTunnelPhone.app",
      "Debug-maccatalyst/CellTunnelPhone.app",
    ] {
      try fileManager.createDirectory(
        atPath: (root as NSString).appendingPathComponent(relative),
        withIntermediateDirectories: true)
    }

    let discovered = SigningVerification.discoverAppBundles(under: [root])
      .map { ($0 as NSString).lastPathComponent }
    let expected = [
      "CellTunnelAgent.app",
      "CellTunnelPhone.app",
      "CellTunnelPhone.app",
      "CellTunnelPhone.app",
    ]

    #expect(discovered.sorted() == expected.sorted())
    #expect(discovered.count == 4)
  }
}

@Test
func discoverAppBundlesDoesNotDescendIntoAnAppOrSkippedDirectories() throws {
  try withTemporaryProductsTree { root, fileManager in
    // A nested helper app inside an app must not be returned.
    try fileManager.createDirectory(
      atPath: (root as NSString).appendingPathComponent(
        "Debug/CellTunnelAgent.app/Contents/PlugIns/Helper.app"),
      withIntermediateDirectories: true)
    // An app under a build-output directory must be skipped.
    try fileManager.createDirectory(
      atPath: (root as NSString).appendingPathComponent(
        "Intermediates.noindex/Stale.app"),
      withIntermediateDirectories: true)

    let discovered = SigningVerification.discoverAppBundles(under: [root])
      .map { ($0 as NSString).lastPathComponent }

    #expect(discovered == ["CellTunnelAgent.app"])
  }
}

@Test
func discoverProductsReportsMissingRootAsUnreadable() {
  let missing = "/nonexistent-\(UUID().uuidString)/Products"
  let result = SigningVerification.discoverProducts(under: [missing])
  #expect(result.apps.isEmpty)
  #expect(result.unreadable == [missing])
}

private func withTemporaryProductsTree(
  _ body: (_ root: String, _ fileManager: FileManager) throws -> Void
) throws {
  let fileManager = FileManager.default
  let root = fileManager.temporaryDirectory
    .appendingPathComponent("swift-mk-products-\(UUID().uuidString)", isDirectory: true).path
  try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
  defer {
    do {
      try fileManager.removeItem(atPath: root)
    } catch {
      Output.warning("cleanup failed: \(error.localizedDescription)")
    }
  }
  try body(root, fileManager)
}
