//
//  BuildToolingAuditTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BuildToolingAuditTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `BuildToolingAuditTests.swift`; the suite is written as free `@Test` functions.
enum BuildToolingAuditTests {}

@Test
func auditFlagsDirectXcodebuildInvocation() {
    #expect(BuildToolingAudit.lineInvokesToolchain("\txcodebuild -workspace App.xcworkspace build"))
}

@Test
func auditFlagsTuistAliasInvocation() {
    #expect(BuildToolingAudit.lineInvokesToolchain("\t$(TUIST) generate --no-open"))
}

@Test
func auditFlagsBareTuistAndXcodegen() {
    #expect(BuildToolingAudit.lineInvokesToolchain("\ttuist build App"))
    #expect(BuildToolingAudit.lineInvokesToolchain("\txcodegen generate"))
}

@Test
func auditFlagsToolAfterShellSeparator() {
    #expect(BuildToolingAudit.lineInvokesToolchain("\tcd foo && xcodebuild test"))
}

@Test
func auditAllowsSanctionedToolchainCall() {
    #expect(
        !BuildToolingAudit.lineInvokesToolchain(
            "\t$(SWIFT_MK_BIN) toolchain build --workspace App.xcworkspace --scheme App"))
}

@Test
func auditAllowsSwiftBuild() {
    #expect(!BuildToolingAudit.lineInvokesToolchain("\tswift build -c release"))
}

@Test
func auditScanReportsFindingWithPathAndLine() throws {
    let dir = NSTemporaryDirectory() + "swiftmk-audit-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = (dir as NSString).appendingPathComponent("Makefile")
    let makefile = """
        build:
        \t$(SWIFT_MK_BIN) toolchain build --workspace App.xcworkspace --scheme App
        legacy:
        \txcodebuild -workspace App.xcworkspace -scheme App build
        # a comment mentioning xcodebuild is not a violation
        """
    try makefile.write(toFile: path, atomically: true, encoding: .utf8)
    let findings = BuildToolingAudit.scan(paths: [path])
    #expect(findings.count == 1)
    #expect(findings.first?.line == 4)
}
