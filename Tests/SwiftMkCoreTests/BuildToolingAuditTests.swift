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
func auditAllowsAliasPassedAsEnvValue() {
  // A variable assignment that threads `$(TUIST)` through as an env value is data,
  // not an invocation, whether it sits at column 0 or inside a recipe command.
  #expect(
    !BuildToolingAudit.lineInvokesToolchain(
      "LMD_DEV = SWIFT_MK_BIN=\"$(SWIFT_MK_BIN)\" TUIST=\"$(TUIST)\" swift run lmd-dev"))
  #expect(
    !BuildToolingAudit.lineInvokesToolchain("\t@FOO=\"$(TUIST)\" some-command --flag"))
}

@Test
func runBuildToolingAuditGatesOnEntryMakefile() throws {
  // The wired gate reads SWIFT_MK_ENTRY_MAKEFILE and fails on a direct invocation,
  // passes on a clean one, so `make check` enforces the routing contract.
  let dir = NSTemporaryDirectory() + "swiftmk-audit-gate-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  let dirty = (dir as NSString).appendingPathComponent("Dirty.mk")
  try "build:\n\txcodebuild -scheme App build\n".write(
    toFile: dirty, atomically: true, encoding: .utf8)
  let clean = (dir as NSString).appendingPathComponent("Clean.mk")
  try "build:\n\t$(SWIFT_MK_BIN) toolchain build --scheme App\n".write(
    toFile: clean, atomically: true, encoding: .utf8)

  setenv("SWIFT_MK_ENTRY_MAKEFILE", dirty, 1)
  #expect(!Lint.runBuildToolingAudit(context: PathContext.current()))
  setenv("SWIFT_MK_ENTRY_MAKEFILE", clean, 1)
  #expect(Lint.runBuildToolingAudit(context: PathContext.current()))
  unsetenv("SWIFT_MK_ENTRY_MAKEFILE")
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
