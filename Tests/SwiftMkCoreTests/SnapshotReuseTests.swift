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
  // (warmSnapshot excludes scripts/swift-mk-bootstrap.sh, matching every
  // existing consumer today) and its marker holds the bare ref name the old
  // engine wrote. The old comparison (marker content == SWIFT_MK_API_REF) read
  // "main" as current forever, so a branch-pinned consumer never re-fetched
  // past its first commit. This drives the real swift.mk, not a stand-in, so
  // it proves the fix in the actual Makefile logic under test.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try warmSnapshot(directory)
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
