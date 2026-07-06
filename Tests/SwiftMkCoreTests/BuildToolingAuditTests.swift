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
  #expect(BuildToolingAudit.lineInvokesToolchain("\t\"xcodegen\" generate"))
}

@Test
func auditFlagsToolAfterShellSeparator() {
  #expect(BuildToolingAudit.lineInvokesToolchain("\tcd foo && xcodebuild test"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\t\"$(SWIFT_MK_BIN)\" build; xcodegen generate"))
}

@Test
func auditAllowsSanctionedToolchainCall() {
  #expect(
    !BuildToolingAudit.lineInvokesToolchain(
      "\t$(SWIFT_MK_BIN) toolchain build --workspace App.xcworkspace --scheme App"))
  #expect(
    !BuildToolingAudit.lineInvokesToolchain(
      "\t\"$(SWIFT_MK_BIN)\" toolchain generate --generator xcodegen"))
  #expect(
    !BuildToolingAudit.lineInvokesToolchain(
      "\t\"$(SWIFT_MK_BIN)\" toolchain build --generator xcodegen --project X.xcodeproj"))
}

@Test
func auditFlagsRecipeSwiftBuildRunTest() {
  // A tab-indented recipe running the compiling subcommands must route through
  // $(SWIFT_MK_BIN); a leading env-assignment prefix does not exempt it.
  #expect(BuildToolingAudit.lineInvokesToolchain("\tswift build -c release"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\tswift test"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\tFOO=tuist swift run"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\tcd Tools && swift build"))
}

@Test
func auditFlagsRecipeWithMakePrefix() {
  // GNU make recipe prefixes (@ silent, - ignore-errors, + always-run) attach to the
  // command word, so a prefixed recipe still spawns the tool and must be flagged.
  #expect(BuildToolingAudit.lineInvokesToolchain("\t@swift build"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\t-swift test"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\t+@swift run tool"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\t@xcodebuild -scheme App build"))
}

@Test
func auditFlagsEnvWrappedRecipe() {
  // `env [OPTION]... [VAR=val ...] cmd` runs cmd, so an env-wrapped compiler or
  // toolchain spawn must still be flagged rather than resolving to `env`. Option flags,
  // including `-u`/`-C`/`-S` that take a following argument, are skipped.
  #expect(BuildToolingAudit.lineInvokesToolchain("\tenv FOO=1 swift build"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\tenv swift test"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\tenv FOO=1 xcodebuild -scheme App build"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\tenv -i swift build"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\tenv -u FOO swift test"))
  #expect(BuildToolingAudit.lineInvokesToolchain("\t@env -i FOO=1 swift run tool"))
  // A non-toolchain command wrapped in env stays clean.
  #expect(!BuildToolingAudit.lineInvokesToolchain("\tenv FOO=1 make submodule"))
  #expect(!BuildToolingAudit.lineInvokesToolchain("\tenv -i make submodule"))
}

@Test
func auditAllowsSwiftPackageScriptAndVariableBuild() {
  // swift package (metadata/clean) and a script argument are not compiling
  // subcommands. A `swift build` in a make variable assignment is not a recipe
  // command line, so the consumer's configured SWIFT_BUILD_CMD stays clean.
  #expect(!BuildToolingAudit.lineInvokesToolchain("\tswift package clean"))
  #expect(!BuildToolingAudit.lineInvokesToolchain("\tswift Tools/Build.swift"))
  #expect(!BuildToolingAudit.lineInvokesToolchain("SWIFT_BUILD_CMD := swift build"))
  #expect(!BuildToolingAudit.lineInvokesToolchain("xcodegen generate"))
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
  #expect(
    !BuildToolingAudit.lineInvokesToolchain("\tFOO=\"$(XCODEGEN)\" cmd"))
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

@Test
func codesignDetectorFlagsDirectSignLines() {
  #expect(
    BuildToolingAudit.lineRunsCodesign(
      #"          codesign -s "${ID}" -f --options runtime "$APP""#))
  #expect(BuildToolingAudit.lineRunsCodesign(#"        "/usr/bin/codesign","#))
  #expect(BuildToolingAudit.lineRunsCodesign(#"      "codesign","#))
  #expect(BuildToolingAudit.lineRunsCodesign("\tcodesign --sign x dmgpath"))
}

@Test
func codesignDetectorPassesSanctionedLines() {
  #expect(!BuildToolingAudit.lineRunsCodesign(#"  # Codesign the copy in LaunchServices"#))
  #expect(!BuildToolingAudit.lineRunsCodesign(#"  // fall back to direct codesign"#))
  #expect(
    !BuildToolingAudit.lineRunsCodesign(
      #"  runPassthrough("codesign", ["--verify", "--strict", path])"#))
  #expect(BuildToolingAudit.lineRunsCodesign(#"  codesign --verify -s id app"#))
  #expect(!BuildToolingAudit.lineRunsCodesign(#"  swift-mk codesign-run --mode binary app"#))
  #expect(!BuildToolingAudit.lineRunsCodesign(#"  codesign --force --sign - "$out" || true"#))
  #expect(!BuildToolingAudit.lineRunsCodesign("  let unrelated = 1"))
}

@Test
func codesignScanExcludesVendoredCheckouts() {
  // A dev-tool SPM package under Tools/ vendors swift-mk into
  // Tools/.build/checkouts/, whose engine source spawns codesign legitimately.
  // The scan must skip that subtree but keep real consumer sources.
  #expect(
    BuildToolingAudit.pathIsInExcludedDirectory(
      ".build/checkouts/swift-makefile/Sources/SwiftMkCore/Codesign.swift"))
  #expect(BuildToolingAudit.pathIsInExcludedDirectory("CellTunnelDev/.build/x.swift"))
  #expect(BuildToolingAudit.pathIsInExcludedDirectory("DerivedData/Build/x.swift"))
  #expect(!BuildToolingAudit.pathIsInExcludedDirectory("CellTunnelDev/BuildActions.swift"))
  #expect(!BuildToolingAudit.pathIsInExcludedDirectory("lmd-dev/Signing.swift"))
}
