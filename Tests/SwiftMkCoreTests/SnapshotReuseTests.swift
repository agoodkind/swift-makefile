//
//  SnapshotReuseTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - SnapshotReuseTests

enum SnapshotReuseTests {}

/// Both snapshot_extract and swift.mk's inline fetch commands try `gh` before
/// falling back to curl, and SWIFT_MK_CODELOAD_BASE only redirects the curl
/// fallback (gh talks to the GitHub API directly, not codeload, and carries no
/// override). A dev machine with `gh` installed and authenticated would
/// otherwise silently hit real GitHub and bypass the local FetchServer
/// entirely. /usr/bin:/bin carries curl, tar, awk, make, and /bin/bash, but not
/// `gh` (typically under /opt/homebrew/bin or /usr/local/bin), forcing the
/// curl fallback deterministically regardless of the host's own tool install.
let pathWithoutGh = "/usr/bin:/bin"

@Test
func snapshotExtractWritesTheThreeFieldMarker() async throws {
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()

    let script = BootstrapHelperRunner.repositoryRoot() + "/scripts/swift-mk-sync.sh"
    // cd explicitly rather than setting PWD: snapshot_extract resolves .make
    // relative to the working directory, and exporting PWD does not change it.
    let command = #"cd "${WORK_DIR}"; source "${SCRIPT_PATH}"; snapshot_extract"#
    let result = Shell.run(
      "/bin/bash", ["-c", command],
      environment: [
        "PATH": pathWithoutGh,
        "SCRIPT_PATH": script,
        "WORK_DIR": directory,
        "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
        "SWIFT_MK_API_REPO": "agoodkind/swift-makefile",
        "SWIFT_MK_API_REF": "main",
        "SWIFT_MK_DEV_DIR": "",
      ])
    #expect(result.status == 0, "\(result.stderr)")

    let marker = readMarker(directory)
    #expect(marker["ref"] == "main", "marker must carry a ref field, not a bare ref name")
    #expect(marker["etag"]?.isEmpty == false, "marker must carry the content ETag")
  }
}

@Test
func snapshotIsNotConsideredCurrentWithoutAnEtag() throws {
  let directory = try temporaryConsumer()
  try writeMakeFile(directory, "Package.swift", "// warm\n")
  // The bare ref name the previous engine wrote. It must not count as current,
  // because a branch ref always equals itself and the consumer would freeze.
  try writeMakeFile(directory, ".swift-mk-snapshot-ref", "main\n")

  let marker = readMarker(directory)
  #expect(marker["etag"] == nil)
}

/// Copies swift.mk alone, with no sibling scripts/ directory, into an isolated
/// location under `directory`. SWIFT_MK_HELPER_DIR falls back to the fetched
/// .make/scripts path only when a local scripts/swift-mk-build.sh next to
/// swift.mk is absent; invoking the real repo's swift.mk directly would find
/// its own sibling scripts/ and resolve to dev/local mode, never exercising
/// the fetched-snapshot path this test needs.
func isolatedSwiftMkCopy(in directory: String) throws -> String {
  let isolatedDirectory = (directory as NSString).appendingPathComponent("swift-mk-copy")
  try FileManager.default.createDirectory(
    atPath: isolatedDirectory, withIntermediateDirectories: true)
  let source = BootstrapHelperRunner.repositoryRoot() + "/swift.mk"
  let destination = (isolatedDirectory as NSString).appendingPathComponent("swift.mk")
  try FileManager.default.copyItem(atPath: source, toPath: destination)
  return destination
}

@Test
func swiftMkUnfreezesABareRefMarkerAndRewritesIt() async throws {
  // The migration case that matters: a consumer's .make predates the helper
  // (warmSnapshotPredatingHelper excludes scripts/swift-mk-bootstrap.sh,
  // matching every existing consumer today) and its marker holds the bare ref
  // name the old engine wrote. The old comparison (marker content ==
  // SWIFT_MK_API_REF) read "main" as current forever, so a branch-pinned
  // consumer never re-fetched past its first commit. This drives the real
  // swift.mk, not a stand-in, so it proves the fix in the actual Makefile
  // logic under test.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try warmSnapshotPredatingHelper(directory)
    try writeMakeFile(directory, ".swift-mk-snapshot-ref", "main\n")

    let isolatedSwiftMk = try isolatedSwiftMkCopy(in: directory)
    let result = Shell.run(
      "make",
      [
        "--no-print-directory", "-C", directory,
        "-f", isolatedSwiftMk,
        "clean",
        "SWIFT_MK_CODELOAD_BASE=\(server.codeloadBase)",
        "SWIFT_MK_API_REPO=agoodkind/swift-makefile",
        "SWIFT_MK_API_REF=main",
      ],
      environment: ["PATH": pathWithoutGh])
    #expect(result.status == 0, "\(result.stderr)")

    #expect(
      server.requests().count == 1,
      "a bare-ref marker on a complete .make must still force a real fetch")

    let marker = readMarker(directory)
    #expect(marker["ref"] == "main")
    #expect(marker["etag"]?.isEmpty == false, "the marker must be rewritten with a real etag")
    #expect(
      readMakeFile(directory, "scripts/swift-mk-bootstrap.sh") != nil,
      "the forced fetch must have landed the helper, which the old .make predates")
  }
}

@Test
func swiftMkOldPathPreservesTheWarmTreeWhenUpstreamFails() async throws {
  // The path a consumer whose committed bootstrap.mk predates the helper still
  // runs (SWIFT_MK_SNAPSHOT_HELPER absent, SWIFT_MK_SNAPSHOT_CURRENT not 1) used
  // to clear .make before fetching, so a failed fetch left that consumer with
  // an engine tree it had just destroyed. It must now stage into .make.next and
  // swap, the same non-destructive shape the helper's own install_from_stage
  // uses, so a failed fetch here leaves the warm tree exactly as it was.
  try await FetchServer.withServer(files: engineFiles()) { server in
    server.forceStatus(500)
    let directory = try temporaryConsumer()
    try warmSnapshotPredatingHelper(directory)
    // A bare ref marker, the old format: SWIFT_MK_SNAPSHOT_CURRENT reads false
    // from it, so swift.mk takes the old inline path instead of treating the
    // warm tree as already current and skipping the fetch entirely.
    try writeMakeFile(directory, ".swift-mk-snapshot-ref", "main\n")

    let isolatedSwiftMk = try isolatedSwiftMkCopy(in: directory)
    let result = Shell.run(
      "make",
      [
        "--no-print-directory", "-C", directory,
        "-f", isolatedSwiftMk,
        "clean",
        "SWIFT_MK_CODELOAD_BASE=\(server.codeloadBase)",
        "SWIFT_MK_API_REPO=agoodkind/swift-makefile",
        "SWIFT_MK_API_REF=main",
      ],
      environment: ["PATH": pathWithoutGh])
    #expect(result.status != 0, "a failed upstream fetch must fail the parse, not silently continue")

    for (name, body) in engineFiles() where name != "scripts/swift-mk-bootstrap.sh" {
      #expect(readMakeFile(directory, name) == body, "\(name) must survive a failed re-provision")
    }
  }
}

/// Reads a path relative to `directory` directly, rather than under `.make/`
/// like `readMakeFile`: the mise target (.config/mise/conf.d/swift-mk.toml)
/// lands at the consumer root, not inside .make.
func readConsumerFile(_ directory: String, _ relative: String) -> String? {
  let path = (directory as NSString).appendingPathComponent(relative)
  return try? String(contentsOfFile: path, encoding: .utf8)
}

/// The renamed targets install_renamed_configs writes, as (source, target)
/// pairs relative to .make, plus the mise target held apart since it lands
/// outside .make entirely.
let renamedConfigMapping = [
  (".swiftlint.yml", "swiftlint.yml"),
  (".swift-format", "swift-format.json"),
  (".periphery.yml", "periphery.yml"),
  ("osv-scanner.toml", "osv-scanner.toml"),
]
let miseTargetRelativePath = ".config/mise/conf.d/swift-mk.toml"

@Test
func warmParseTakesConfigsFromTheSnapshotWithNoNetwork() async throws {
  // Content matching alone would not distinguish "copied from the snapshot
  // already on disk" from "some fetch mechanism ran again and happened to
  // produce the same bytes," so this asserts the request count too. Deleting
  // the renamed targets after the cold run and before the warm one is what
  // makes the test meaningful rather than vacuous: the cold run's own
  // install_from_stage already creates them, so without deleting them first, a
  // warm run that did nothing at all would still leave this test green. This
  // simulates the actual motivating case: a consumer whose marker already
  // validates (Task 4's fix landed for them) but who never had this task's
  // copy step run, because they have not re-provisioned since. The warm run
  // must recreate every target via the 304 path's own copy call, at zero
  // additional network cost beyond the one validation request.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()

    let cold = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(cold.status == 0, "\(cold.stderr)")
    #expect(readMakeFile(directory, ".swiftlint.yml") == "# swiftlint v1\n")

    for (_, target) in renamedConfigMapping {
      try? FileManager.default.removeItem(atPath: makePath(directory, target))
    }
    let miseTargetPath = (directory as NSString).appendingPathComponent(miseTargetRelativePath)
    try? FileManager.default.removeItem(atPath: miseTargetPath)

    let warm = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(warm.status == 0, "\(warm.stderr)")

    #expect(
      server.requests().count == coldThenValidateRequestCount,
      "a warm parse must cost no additional network request beyond the one validation check")

    for (source, target) in renamedConfigMapping {
      let sourceBody = readMakeFile(directory, source)
      let targetBody = readMakeFile(directory, target)
      #expect(
        sourceBody == targetBody,
        "\(target) should be a copy of \(source), got \(String(describing: targetBody))")
    }
    #expect(
      readMakeFile(directory, "mise.toml") == readConsumerFile(directory, miseTargetRelativePath),
      "the mise target should be a copy of mise.toml")
  }
}

// MARK: - Bootstrap delegation

/// One `make -n help` invocation's combined output and exit status. `-n` (dry run)
/// still runs every parse-time $(shell) call bootstrap.mk and swift.mk make, which
/// is exactly the fetch and provisioning logic under test here; it only skips
/// recipe commands, and `help` needs none.
struct MakeResult {
  let output: String
  let status: Int32
}

/// Builds a temp repo shaped like a real consumer: its own Makefile that includes
/// the current, committed bootstrap.mk.
func consumerWithBootstrap() throws -> String {
  let directory = try temporaryConsumer()
  let bootstrap = try String(
    contentsOfFile: BootstrapHelperRunner.repositoryRoot() + "/bootstrap.mk", encoding: .utf8)
  try bootstrap.write(
    toFile: (directory as NSString).appendingPathComponent("bootstrap.mk"),
    atomically: true, encoding: .utf8)
  try "include bootstrap.mk\n".write(
    toFile: (directory as NSString).appendingPathComponent("Makefile"),
    atomically: true, encoding: .utf8)
  return directory
}

/// Runs `make -n` against `goals` in `directory`, off the cooperative pool (see
/// `OffPoolWork`). `-n` (dry run) still runs every parse-time $(shell) call, so it
/// exercises the fetch and provisioning logic under test without needing a real
/// Swift toolchain to actually execute a recipe. `goals` defaults to `help`, whose
/// target real swift.mk defines unconditionally; a goal other than exactly `help`
/// also runs the rest of swift.mk's own parse-time logic, which is gated behind
/// `ifneq ($(MAKECMDGOALS),help)`. PATH defaults to `pathWithoutGh`: gh is
/// installed and authenticated on a dev machine, and unlike SWIFT_MK_CODELOAD_BASE
/// it carries no override, so leaving the ambient PATH in place would let a real
/// `gh api` call reach actual GitHub instead of the local FetchServer.
func runMakeHelp(
  directory: String, environment: [String: String], goals: [String] = ["help"]
) async -> MakeResult {
  var defaults: [String: String] = TestGlobalLock.withLock {
    [
      "PATH": pathWithoutGh,
      "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "",
      "GITHUB_ACTIONS": "",
      "GITHUB_RUN_ID": "",
      "SWIFT_MK_DEV_DIR": "",
    ]
  }
  for (key, value) in environment {
    defaults[key] = value
  }
  let merged = defaults
  return await OffPoolWork.run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/make")
    process.arguments = ["-n"] + goals
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    process.environment = merged
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return MakeResult(output: Output.decodeCapturedUTF8(data), status: process.terminationStatus)
  }
}

@Test
func warmSnapshotHelperParseIssuesExactlyOneRequest() async throws {
  // Real swift.mk and real scripts/swift-mk-bootstrap.sh, not stubs, and a goal
  // other than "help": real swift.mk's own snapshot check (guarded by
  // SWIFT_MK_HELPER_DIR == SWIFT_MK_FETCHED_SCRIPT_DIR) re-invokes the landed
  // helper on every parse whose goal is not exactly "help", the same fast path
  // HelpFastPathTests covers. Only a real parse with a real goal can prove
  // bootstrap.mk's own SWIFT_MK_SKIP_FETCH override actually stops that second
  // invocation from costing a second network round trip; a stubbed swift.mk or
  // a bare "help" goal would pass this test whether or not the override exists.
  var files = engineFiles()
  files["swift.mk"] = try String(
    contentsOfFile: BootstrapHelperRunner.repositoryRoot() + "/swift.mk", encoding: .utf8)
  files["scripts/swift-mk-bootstrap.sh"] = try String(
    contentsOfFile: BootstrapHelperRunner.repositoryRoot() + "/scripts/swift-mk-bootstrap.sh",
    encoding: .utf8)
  try await FetchServer.withServer(files: files) { server in
    let directory = try consumerWithBootstrap()

    let cold = await runMakeHelp(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase],
      goals: ["clean"])
    #expect(cold.status == 0, "\(cold.output)")
    let coldCount = server.requests().count

    let warm = await runMakeHelp(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase],
      goals: ["clean"])
    #expect(warm.status == 0, "\(warm.output)")

    let warmRequests = Array(server.requests().dropFirst(coldCount))
    #expect(warmRequests.count == 1, "a warm parse issued \(warmRequests.count) requests, want 1")
    #expect(warmRequests.first?.status == notModifiedStatus)
  }
}

@Test
func oldBootstrapWithNewSwiftMkStillProvisionsTheSnapshotHelper() async throws {
  // The migration case that matters: a consumer's committed bootstrap.mk predates
  // this task (Fixtures/pre-helper-bootstrap.mk, captured before it changed) and
  // never runs the helper at all, but swift.mk has already picked up this task's
  // change. That consumer must keep working until it merges the new bootstrap.mk.
  var files = engineFiles()
  files["swift.mk"] = try String(
    contentsOfFile: BootstrapHelperRunner.repositoryRoot() + "/swift.mk", encoding: .utf8)
  try await FetchServer.withServer(files: files) { server in
    let directory = try temporaryConsumer()
    let oldBootstrap = try String(
      contentsOfFile: BootstrapHelperRunner.repositoryRoot()
        + "/Tests/SwiftMkCoreTests/Fixtures/pre-helper-bootstrap.mk", encoding: .utf8)
    try oldBootstrap.write(
      toFile: (directory as NSString).appendingPathComponent("bootstrap.mk"),
      atomically: true, encoding: .utf8)
    try "include bootstrap.mk\n".write(
      toFile: (directory as NSString).appendingPathComponent("Makefile"),
      atomically: true, encoding: .utf8)

    // The old bootstrap.mk's single-file fetch has only two paths that need no
    // real network: SWIFT_MK_DEV_DIR, or a raw.githubusercontent.com curl that
    // SWIFT_MK_CODELOAD_BASE cannot redirect. A dev dir carrying only swift.mk,
    // with no sibling scripts/swift-mk-build.sh, lands the current swift.mk
    // hermetically without also diverting swift.mk's own dev-dir resolution once
    // it parses: that still falls through to the fetched-snapshot path this test
    // means to exercise.
    let devDir = try temporaryConsumer()
    try files["swift.mk"]!.write(
      toFile: (devDir as NSString).appendingPathComponent("swift.mk"),
      atomically: true, encoding: .utf8)

    // "clean" rather than "help": real swift.mk gates its own snapshot-fetch
    // logic behind `ifneq ($(MAKECMDGOALS),help)`, the same fast path
    // HelpFastPathTests covers, so a goal of exactly "help" would never reach
    // the provisioning logic this test means to exercise.
    let result = await runMakeHelp(
      directory: directory,
      environment: [
        "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
        "SWIFT_MK_DEV_DIR": devDir,
      ],
      goals: ["clean"])
    #expect(result.status == 0, "\(result.output)")
    #expect(readMakeFile(directory, "Package.swift") != nil)
    #expect(readMakeFile(directory, "scripts/swift-mk-build.sh") != nil)
  }
}
