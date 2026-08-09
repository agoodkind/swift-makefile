//
//  BuildTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-13.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BuildTests

enum BuildTests {}

@Test
func inlineGatesSkipUnderGitHubActions() {
  // A real CI run sets GITHUB_ACTIONS=true and a non-empty GITHUB_RUN_ID. The
  // gate runs as its own decoupled CI job, so `build` must not re-run it inline.
  #expect(
    !Build.runsInlineGates(
      githubActions: "true", githubRunId: "123456789", skipInlineGates: ""))
}

@Test
func inlineGatesSkipWhenExplicitlyRequested() {
  #expect(
    !Build.runsInlineGates(
      githubActions: "", githubRunId: "", skipInlineGates: "1"))
}

@Test
func inlineGatesRunLocally() {
  // No GitHub Actions environment is a local or agent run, where `build` is the
  // unbypassable chokepoint and must run the gates inline.
  #expect(
    Build.runsInlineGates(
      githubActions: "", githubRunId: "", skipInlineGates: ""))
  #expect(
    Build.runsInlineGates(
      githubActions: "false", githubRunId: "", skipInlineGates: ""))
}

@Test
func inlineGatesRunWhenRunIdMissing() {
  // GITHUB_ACTIONS alone is not a CI run: without a run id there is no decoupled
  // gate job, so the inline gate must still fire rather than silently vanish.
  #expect(
    Build.runsInlineGates(
      githubActions: "true", githubRunId: "", skipInlineGates: ""))
}

// MARK: - Compile-cache flags on hand-written commands

/// The flags a real toolchain would produce, with a path that a naive space-joined
/// append would split at the shell, so quoting is part of what these tests pin.
private let fakeCompileCacheFlags = [
  "-Xswiftc", "-explicit-module-build",
  "-Xswiftc", "-cache-compile-job",
  "-Xswiftc", "-cas-path",
  "-Xswiftc", "/Users/a b/Library/Caches/swift-mk/SwiftPMCompilationCache",
]

@Test
func bareSwiftBuildGainsQuotedCompileCacheFlags() {
  let rewritten = Build.withSwiftPMCompileCache(
    "swift build --configuration release --build-tests -Xswiftc -enable-testing",
    flags: fakeCompileCacheFlags)

  #expect(rewritten.hasPrefix("swift build --configuration release"))
  #expect(rewritten.contains("'-cache-compile-job'"))
  // The CAS path is one shell word even with a space in it.
  #expect(rewritten.contains("'/Users/a b/Library/Caches/swift-mk/SwiftPMCompilationCache'"))
}

@Test
func bareSwiftTestGainsCompileCacheFlags() {
  let rewritten = Build.withSwiftPMCompileCache(
    "swift test --configuration release --skip-build --no-parallel",
    flags: fakeCompileCacheFlags)
  #expect(rewritten.contains("'-explicit-module-build'"))
}

@Test
func swiftRunIsNeverRewritten() {
  // `swift run <product> [args]` hands trailing words to the consumer's tool, so an
  // append would deliver the flags to that tool rather than to swift.
  let command = "swift run my-tool --serve"
  #expect(Build.withSwiftPMCompileCache(command, flags: fakeCompileCacheFlags) == command)
}

@Test
func compoundAndRoutedCommandsAreNeverRewritten() {
  // A shell operator means the append target is not determinable.
  let compound = "swift build && ditto -c out dist/out.zip"
  #expect(Build.withSwiftPMCompileCache(compound, flags: fakeCompileCacheFlags) == compound)
  // The routed form receives its flags inside the SwiftPM chokepoint as an argv
  // array; a second append here would double them.
  let routed = "\"/repo/.make/swift-mk\" toolchain swiftpm build"
  #expect(Build.withSwiftPMCompileCache(routed, flags: fakeCompileCacheFlags) == routed)
}

@Test
func explicitCasPathAndEmptyFlagsLeaveTheCommandAlone() {
  let explicit = "swift build -Xswiftc -cas-path -Xswiftc /tmp/own-cas"
  #expect(Build.withSwiftPMCompileCache(explicit, flags: fakeCompileCacheFlags) == explicit)
  let command = "swift build"
  #expect(Build.withSwiftPMCompileCache(command, flags: []) == command)
}

@Test
func shellQuotingEscapesEmbeddedSingleQuotes() {
  #expect(Build.shellQuoted("plain") == "'plain'")
  #expect(Build.shellQuoted("a'b") == "'a'\\''b'")
}

@Test
func aPassedCommandWinsAndNeverEntersTheEnvironment() {
  // `release-build` passes its command as an argument rather than through
  // SWIFT_BUILD_CMD. swift.mk exports that variable and defaults it with `?=`, so an
  // inherited value wins over the default: a release command that recurses into make
  // had the nested make read the release command back as its build command and re-enter
  // the build, until the runner ran out of processes at 256 levels deep.
  let saved = Environment.snapshot(["SWIFT_BUILD_CMD"])
  defer { saved.restore() }

  setenv("SWIFT_BUILD_CMD", "configured", 1)
  #expect(Build.resolvedBuildCommand("release") == "release")
  // Resolving a passed command leaves the environment untouched, so anything the
  // command spawns still sees the consumer's own configuration.
  #expect(Env.get("SWIFT_BUILD_CMD") == "configured")

  // With nothing passed the consumer's configured command is used, unchanged.
  #expect(Build.resolvedBuildCommand(nil) == "configured")
  #expect(Build.resolvedBuildCommand("") == "configured")
}
