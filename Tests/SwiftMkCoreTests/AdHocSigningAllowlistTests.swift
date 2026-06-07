//
//  AdHocSigningAllowlistTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - AdHocSigningAllowlistTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `AdHocSigningAllowlistTests.swift`; the suite is written as free `@Test` functions.
enum AdHocSigningAllowlistTests {}

private func writeManifest(name: String) throws -> String {
    let directory = NSTemporaryDirectory() + "swiftmk-allowlist-" + UUID().uuidString
    try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true)
    let manifest = """
        // swift-tools-version:6.3
        import PackageDescription
        let package = Package(
            name: "\(name)",
            targets: [.executableTarget(name: "\(name)")]
        )
        """
    try manifest.write(
        toFile: (directory as NSString).appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8)
    return directory
}

@Test
func adHocAllowlistParsesPackageNameTakingTheFirstNameField() throws {
    // The package name is the first `name:` in the manifest, before any target's.
    let directory = try writeManifest(name: "Shim")
    #expect(AdHocSigningAllowlist.packageName(inDirectory: directory) == "Shim")
}

@Test
func adHocAllowlistPermitsTheAllowlistedShimPackage() throws {
    let directory = try writeManifest(name: "Shim")
    #expect(AdHocSigningAllowlist.allowedPackageName(inDirectory: directory) == "Shim")
}

@Test
func adHocAllowlistRejectsAPackageNotOnTheList() throws {
    // A consumer cannot grant itself the exception by any name it picks.
    let directory = try writeManifest(name: "SomeOtherConsumer")
    #expect(AdHocSigningAllowlist.allowedPackageName(inDirectory: directory) == nil)
}

@Test
func adHocAllowlistReturnsNilWhenNoManifestPresent() {
    let directory = NSTemporaryDirectory() + "swiftmk-allowlist-missing-" + UUID().uuidString
    #expect(AdHocSigningAllowlist.packageName(inDirectory: directory) == nil)
    #expect(AdHocSigningAllowlist.allowedPackageName(inDirectory: directory) == nil)
}

@Test
func adHocAllowlistContainsOnlyTheShim() {
    // A guard so widening the carve-out is a deliberate, visible change.
    #expect(AdHocSigningAllowlist.packages == ["Shim"])
}
