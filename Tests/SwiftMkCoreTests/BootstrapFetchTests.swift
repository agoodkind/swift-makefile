//
//  BootstrapFetchTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BootstrapFetchTests

enum BootstrapFetchTests {}

/// The engine tree the test server serves. It carries every asset the helper
/// must provision, so a cold run has a complete source.
func engineFiles() -> [String: String] {
  [
    "swift.mk": "# swift.mk v1\n",
    "Package.swift": "// swift-tools-version: 6.0\n",
    "scripts/swift-mk-build.sh": "#!/usr/bin/env bash\nexit 0\n",
    "scripts/swift-mk-fetch-one.sh": "#!/usr/bin/env bash\nexit 0\n",
    "scripts/swift-mk-sync.sh": "#!/usr/bin/env bash\nexit 0\n",
    "scripts/swift-mk-bootstrap.sh": "#!/usr/bin/env bash\nexit 0\n",
    ".swiftlint.yml": "# swiftlint v1\n",
    ".swift-format": "{}\n",
    ".periphery.yml": "# periphery v1\n",
    "osv-scanner.toml": "# osv v1\n",
    "mise.toml": "# mise v1\n",
  ]
}

func temporaryConsumer() throws -> String {
  let path = NSTemporaryDirectory() + "swift-mk-consumer-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

func makePath(_ directory: String, _ relative: String) -> String {
  (directory as NSString).appendingPathComponent(".make/" + relative)
}

func writeMakeFile(_ directory: String, _ relative: String, _ body: String) throws {
  let path = makePath(directory, relative)
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try body.write(toFile: path, atomically: true, encoding: .utf8)
}

func readMakeFile(_ directory: String, _ relative: String) -> String? {
  try? String(contentsOfFile: makePath(directory, relative), encoding: .utf8)
}

/// Run the bootstrap helper. See `BootstrapHelperRunner` for why the wait happens on a
/// thread of its own.
func runHelper(
  directory: String,
  environment: [String: String]
) async -> BootstrapHelperRunner.Result {
  await BootstrapHelperRunner.run(directory: directory, environment: environment)
}

/// A marker just written, which the helper reads as current.
let freshMarkerAge = 0
/// A marker old enough to be worth validating, young enough to still serve from disk.
let recentMarkerAge = 600
/// A marker old enough that the helper must force a real provision.
let staleMarkerAge = 7_200
/// Longer than the filesystem's one-second timestamp granularity, so a rewrite that did
/// happen is detectable.
let pastTimestampGranularityMilliseconds = 1_100
/// How many requests a cold provision followed by one validation makes.
let coldThenValidateRequestCount = 2
/// The status a matching conditional request gets back.
let notModifiedStatus = 304

@Test
func helperColdProvisionWritesEveryAsset() async throws {
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status == 0, "helper failed: \(result.stderr)")

    #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v1\n")
    #expect(readMakeFile(directory, "Package.swift") != nil)
    #expect(readMakeFile(directory, "scripts/swift-mk-build.sh") != nil)
    let requests = server.requests()
    #expect(requests.count == 1)
    // Proves the helper asked for the configured repo and ref, not just any
    // path the test server happened to answer.
    #expect(requests.first?.path == "/agoodkind/swift-makefile/tar.gz/main")
  }
}

@Test
func helperLeavesSnapshotIntactWhenUpstreamReturnsAnError() async throws {
  // A real server that answers with a real HTTP error, not an unreachable
  // port. A helper that merely runs `exit 1`, is missing entirely (exit 127),
  // or has a syntax error would also leave the warm tree untouched, without
  // ever making a request; asserting the request count rules those out and
  // proves the helper actually reached the network and then chose, on a real
  // failure response, not to touch .make.
  try await FetchServer.withServer(files: engineFiles()) { server in
    server.forceStatus(500)

    let directory = try temporaryConsumer()
    try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
    try writeMakeFile(directory, "Package.swift", "// warm\n")
    try writeMakeFile(directory, "scripts/swift-mk-build.sh", "#!/usr/bin/env bash\nexit 0\n")

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status != 0)
    #expect(server.requests().count == 1)

    // The point of the task: a failed fetch must not remove what was there.
    #expect(readMakeFile(directory, "swift.mk") == "# warm swift.mk\n")
    #expect(readMakeFile(directory, "Package.swift") == "// warm\n")
  }
}

@Test
func helperRejectsIncompleteSnapshotAndPreservesWarmTree() async throws {
  // The server answers 200 with a real tarball that extracts cleanly, but the
  // tarball is missing Package.swift. This is the case the staged-verification
  // design exists for: a fetch that succeeds at the transport level must
  // still be rejected, and rejected before anything under .make is touched.
  var incompleteFiles = engineFiles()
  incompleteFiles.removeValue(forKey: "Package.swift")
  try await FetchServer.withServer(files: incompleteFiles) { server in
    let directory = try temporaryConsumer()
    try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
    try writeMakeFile(directory, "Package.swift", "// warm\n")
    try writeMakeFile(directory, "scripts/swift-mk-build.sh", "#!/usr/bin/env bash\nexit 0\n")

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status != 0)
    #expect(server.requests().count == 1)

    #expect(readMakeFile(directory, "swift.mk") == "# warm swift.mk\n")
    #expect(readMakeFile(directory, "Package.swift") == "// warm\n")
  }
}

@Test
func helperSwapFailureLeavesWarmTreeIntactForLaterSkipFetch() async throws {
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
    try writeMakeFile(directory, "Package.swift", "// warm\n")
    try writeMakeFile(directory, "scripts/swift-mk-build.sh", "#!/usr/bin/env bash\nexit 0\n")
    try writeMakeFile(directory, "scripts/swift-mk-bootstrap.sh", "#!/usr/bin/env bash\nexit 0\n")
    // A file outside the assets assets_complete checks, so a partial swap that
    // happened to keep only those would still be caught here.
    try writeMakeFile(directory, "scripts/swift-mk-fetch-one.sh", "#!/usr/bin/env bash\nexit 0\n")

    // Deny write access to the consumer root itself, so the helper cannot
    // create the staging directory it needs before it may touch .make. This is
    // a real, unmocked failure (EACCES), not an injected one.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: directory)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
    }

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status != 0)

    #expect(readMakeFile(directory, "swift.mk") == "# warm swift.mk\n")
    #expect(readMakeFile(directory, "Package.swift") == "// warm\n")
    #expect(readMakeFile(directory, "scripts/swift-mk-fetch-one.sh") != nil)

    // Restore write access and prove the untouched warm tree is still complete:
    // the earlier failure never left .make half swapped.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
    let skipFetchResult = await runHelper(
      directory: directory,
      environment: [
        "SWIFT_MK_CODELOAD_BASE": server.codeloadBase, "SWIFT_MK_SKIP_FETCH": "1",
      ])
    #expect(skipFetchResult.status == 0, "skip-fetch failed: \(skipFetchResult.stderr)")
  }
}

@Test
func helperFailsWhenPreservingAGeneratedFileCannotBeCopied() async throws {
  // `if provision; then` puts everything provision calls in bash's -e ignore
  // list, so a step inside install_from_stage that fails without an explicit
  // check would be silently ignored rather than aborting. Forwarding a
  // preserved runtime file that cannot be read is exactly such a step: it
  // must fail loudly instead of quietly dropping the file from the new .make.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
    try writeMakeFile(directory, "Package.swift", "// warm\n")
    try writeMakeFile(directory, "scripts/swift-mk-build.sh", "#!/usr/bin/env bash\nexit 0\n")
    try writeMakeFile(directory, "build.lock", "warm lock\n")
    let lockPath = makePath(directory, "build.lock")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockPath)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockPath)
    }

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status != 0)

    // The install must abort rather than silently swap in a tree that dropped
    // build.lock; the original warm tree, unreadable file included, survives.
    #expect(readMakeFile(directory, "swift.mk") == "# warm swift.mk\n")
    #expect(readMakeFile(directory, "Package.swift") == "// warm\n")
  }
}

@Test
func helperSkipFetchRejectsARequiredAssetThatIsActuallyADirectory() async throws {
  // assets_complete's old check, `-s` alone, is true for a non-empty
  // directory as well as a regular file, so a required asset path that is
  // actually a directory would have been accepted as complete.
  let directory = try temporaryConsumer()
  try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
  try writeMakeFile(directory, "Package.swift", "// warm\n")
  try writeMakeFile(directory, "scripts/swift-mk-build.sh/placeholder", "not a script\n")

  let result = await runHelper(
    directory: directory,
    environment: ["SWIFT_MK_CODELOAD_BASE": "http://127.0.0.1:9", "SWIFT_MK_SKIP_FETCH": "1"])
  #expect(result.status != 0)
}

func readMarker(_ directory: String) -> [String: String] {
  guard let body = readMakeFile(directory, ".swift-mk-snapshot-ref") else {
    return [:]
  }
  var fields: [String: String] = [:]
  for line in body.split(separator: "\n") {
    let parts = line.split(separator: "=", maxSplits: 1)
    if parts.count == 2 {
      fields[String(parts[0])] = String(parts[1])
    }
  }
  return fields
}

func writeMarker(_ directory: String, ref: String, etag: String, timestamp: Int) throws {
  try writeMakeFile(
    directory, ".swift-mk-snapshot-ref", "ref=\(ref)\netag=\(etag)\ntimestamp=\(timestamp)\n")
}

/// Write a marker for `main` dated `age` seconds in the past.
func writeMarker(_ directory: String, etag: String, age: Int) throws {
  let timestamp = Int(Date().timeIntervalSince1970) - age
  try writeMarker(directory, ref: "main", etag: etag, timestamp: timestamp)
}

/// Populates .make with a complete engine tree, scripts/swift-mk-bootstrap.sh
/// included since required_assets now covers the helper's own successor, so
/// only the validation decision is under test.
func warmSnapshot(_ directory: String) throws {
  for (name, body) in engineFiles() {
    try writeMakeFile(directory, name, body)
  }
}

/// The migration case: every asset the pre-helper engine wrote, but not
/// scripts/swift-mk-bootstrap.sh itself, since a consumer whose .make predates
/// this task's helper never had it. Driving swift.mk directly (not the
/// standalone helper script) branches on this file's presence under
/// .make/scripts, so a test of that branch needs it genuinely absent, not just
/// a marker in the old format.
func warmSnapshotPredatingHelper(_ directory: String) throws {
  for (name, body) in engineFiles() where name != "scripts/swift-mk-bootstrap.sh" {
    try writeMakeFile(directory, name, body)
  }
}

@Test
func helperRecordsMarkerWithEtagOnColdProvision() async throws {
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status == 0, "\(result.stderr)")

    let marker = readMarker(directory)
    #expect(marker["ref"] == "main")
    #expect(marker["etag"]?.isEmpty == false)
    #expect(Int(marker["timestamp"] ?? "") != nil)
  }
}

@Test
func helperInstallsANewlyPublishedSuccessorOnAContentChange() async throws {
  // required_assets omits scripts/swift-mk-bootstrap.sh itself; this proves
  // whether a full re-provision (triggered by upstream content actually
  // changing, so the tarball ETag no longer matches) still lands a newer
  // helper script over the one bootstrap.mk is about to run next.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()

    let cold = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(cold.status == 0, "\(cold.stderr)")

    var updatedFiles = engineFiles()
    updatedFiles["scripts/swift-mk-bootstrap.sh"] =
      "#!/usr/bin/env bash\nprintf 'updated helper\\n'\nexit 0\n"
    await server.setFiles(updatedFiles)

    let warm = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(warm.status == 0, "\(warm.stderr)")
    #expect(
      readMakeFile(directory, "scripts/swift-mk-bootstrap.sh")
        == updatedFiles["scripts/swift-mk-bootstrap.sh"],
      "the consumer must run whatever the helper installed, including a newer helper itself")
  }
}

@Test
func helperTouchesNothingWhenUpstreamReturnsNotModified() async throws {
  try await FetchServer.withServer(files: engineFiles()) { server in
    try await expectNoRewriteOnNotModified(server)
  }
}

/// The body of `helperTouchesNothingWhenUpstreamReturnsNotModified`, held apart so the
/// test reads as one scoped server rather than one deeply nested block.
private func expectNoRewriteOnNotModified(_ server: FetchServer) async throws {
  let directory = try temporaryConsumer()

  let first = await runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(first.status == 0, "\(first.stderr)")

  let path = makePath(directory, "swift.mk")
  let markerPath = makePath(directory, ".swift-mk-snapshot-ref")
  let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
  // The marker's raw bytes, not just its parsed fields, so a rewrite that
  // happens to preserve every field's value but reorders the lines would
  // still be caught. Content alone is not enough, though: the recorded
  // timestamp field has one-second resolution, so a rewrite landing in the
  // same wall-clock second as the original write would still produce
  // byte-identical content. The marker's own modification time closes that
  // gap, since the filesystem records it independently of what was written.
  let markerBefore = readMakeFile(directory, ".swift-mk-snapshot-ref")
  #expect(markerBefore != nil)
  let markerMtimeBefore =
    try FileManager.default.attributesOfItem(atPath: markerPath)[.modificationDate] as? Date
  // Sleep past the filesystem timestamp granularity so a re-extract, or a
  // marker rewrite, would be detectable.
  try await Task.sleep(for: .milliseconds(pastTimestampGranularityMilliseconds))

  let second = await runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(second.status == 0, "\(second.stderr)")

  let after = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
  #expect(before == after, "a 304 re-extracted the tree and moved mtimes")

  let markerAfter = readMakeFile(directory, ".swift-mk-snapshot-ref")
  #expect(markerBefore == markerAfter, "a 304 rewrote the marker instead of leaving it untouched")
  let markerMtimeAfter =
    try FileManager.default.attributesOfItem(atPath: markerPath)[.modificationDate] as? Date
  #expect(
    markerMtimeBefore == markerMtimeAfter,
    "a 304 touched the marker's modification time instead of leaving it untouched")

  let requests = server.requests()
  #expect(requests.count == coldThenValidateRequestCount)
  #expect(requests[1].status == notModifiedStatus)
  #expect(requests[1].bytes == 0)
}

@Test
func helperUnfreezesAMarkerThatHoldsOnlyARefName() async throws {
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try warmSnapshot(directory)
    // The format the current engine writes: a bare ref name, no ETag.
    try writeMakeFile(directory, ".swift-mk-snapshot-ref", "main\n")

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status == 0, "\(result.stderr)")

    #expect(server.requests().count == 1)
    #expect(server.requests()[0].status == 200, "a bare-ref marker must force a real fetch")
    #expect(readMarker(directory)["etag"]?.isEmpty == false)
  }
}

@Test
func helperServesSnapshotWhenUpstreamStallsAndMarkerIsRecent() async throws {
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try warmSnapshot(directory)
    try writeMarker(directory, etag: "\"cached\"", age: recentMarkerAge)
    // The 304 path (helperTouchesNothingWhenUpstreamReturnsNotModified) locks
    // its own no-write invariant with both content and modification time; the
    // offline-reuse path is the second place a marker write must never happen,
    // since a write here would slide the one-hour window forward on every
    // offline run, turning bounded reuse into unbounded reuse with the whole
    // suite still green.
    let markerPath = makePath(directory, ".swift-mk-snapshot-ref")
    let markerBefore = readMakeFile(directory, ".swift-mk-snapshot-ref")
    let markerMtimeBefore =
      try FileManager.default.attributesOfItem(atPath: markerPath)[.modificationDate] as? Date
    server.stall(5)

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status == 0, "\(result.stderr)")
    #expect(result.stderr.contains("serving the .make snapshot validated"))
    // The probe's own curl output used to be discarded with 2>/dev/null, so a
    // validation that failed on every run left no trace. The warning must now
    // carry why validation failed, not just that it did.
    #expect(result.stderr.contains("validation curl exit"))
    #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v1\n")

    let markerAfter = readMakeFile(directory, ".swift-mk-snapshot-ref")
    #expect(
      markerBefore == markerAfter,
      "the offline-reuse path rewrote the marker instead of leaving it untouched")
    let markerMtimeAfter =
      try FileManager.default.attributesOfItem(atPath: markerPath)[.modificationDate] as? Date
    #expect(
      markerMtimeBefore == markerMtimeAfter,
      "the offline-reuse path touched the marker's modification time instead of leaving it untouched"
    )
  }
}

@Test
func helperFailsWhenUpstreamStallsAndMarkerIsStale() async throws {
  // The validation request stalls past its own 3 second budget and times out,
  // but a stale marker forces a real provision attempt next, so the upstream
  // also has to genuinely fail that second request (a real 500, not just a
  // slow response) for the whole run to fail. Without forceStatus(500) here,
  // the forced provision would stall the same 5 seconds and then succeed,
  // since its budget is 60 seconds; see
  // helperForceProvisionsWhenValidationTimesOutAndMarkerIsStale for that case.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try warmSnapshot(directory)
    try writeMarker(directory, etag: "\"cached\"", age: staleMarkerAge)
    server.stall(5)
    server.forceStatus(500)

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status != 0)
    #expect(!result.stderr.contains("serving the .make snapshot validated"))
    // A validation that fails on the stale fall-through path (no serve-from-disk
    // eligible) must still be logged, not silently swallowed by 2>/dev/null,
    // before the fall-through to a full provision attempt.
    #expect(result.stderr.contains("validation curl exit"))
    #expect(result.stderr.contains("falling through to a full provision"))
    // Nothing may be destroyed even on the failing path.
    #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v1\n")
  }
}

@Test
func helperForceProvisionsWhenValidationTimesOutAndMarkerIsStale() async throws {
  // Regression guard: a validation timeout only proves the cheap 3 second
  // check did not finish, not that the network is down. A stale marker must
  // still force a real provision attempt with its own budget, and that
  // attempt can succeed even though validation did not.
  //
  // server.stall(5) alone used to cover this: the validation HEAD request
  // (a 3 second budget) timed out, and the forced provision GET, sharing the
  // same dead 5 second pre-response delay, still finished inside the old 60
  // second --max-time. Once the provision fetch also gained a progress-based
  // abort (--speed-limit 1024 --speed-time 3), a dead 5 second stall before
  // any byte arrives now aborts that GET too: 5 seconds of zero throughput
  // trips the 3 second speed-time window well before the stall even ends.
  // trickle keeps the stall on the HEAD (bodyless, so the dead delay still
  // applies and validation still times out) while giving the GET a real,
  // continuously-progressing body instead, which is what "slow but working"
  // actually means now.
  var updatedFiles = engineFiles()
  updatedFiles["swift.mk"] = "# swift.mk v2\n"
  try await FetchServer.withServer(files: updatedFiles) { server in
    let directory = try temporaryConsumer()
    try warmSnapshot(directory)
    try writeMarker(directory, etag: "\"cached\"", age: staleMarkerAge)
    server.stall(5)
    server.trickle(bytesPerSecond: 2048)

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status == 0, "\(result.stderr)")
    #expect(!result.stderr.contains("serving the .make snapshot validated"))
    // The forced provision reached the upstream and installed its current
    // content, not the stale warm tree the marker described.
    #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v2\n")
  }
}

@Test
func helperProvisionsUnconditionallyInCI() async throws {
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try warmSnapshot(directory)
    try writeMarker(directory, etag: "\"cached\"", age: freshMarkerAge)

    let result = await runHelper(
      directory: directory,
      environment: [
        "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
        "GITHUB_ACTIONS": "true",
        "GITHUB_RUN_ID": "1",
      ])
    #expect(result.status == 0, "\(result.stderr)")
    #expect(server.requests().count == 1)
    #expect(server.requests()[0].ifNoneMatch.isEmpty, "CI sent a conditional request")
    #expect(server.requests()[0].status == 200)
  }
}

@Test
func helperInstallsAndWarnsWhenUpstreamOmitsTheETagHeader() async throws {
  // Reversal: a hard failure here was judged worse than the defect it guarded
  // against. If codeload ever stops sending ETag on archives, refusing to
  // install would break every consumer at once, including a cold one left
  // with no engine at all. Instead the verified tree installs, no marker is
  // written (so every later run has no known etag and downloads
  // unconditionally, today's pre-Task-3 behavior), and a warning is printed
  // every time so the degradation stays visible rather than silent. Renamed
  // from helperFailsWhenUpstreamOmitsTheETagHeader to match the new contract.
  try await FetchServer.withServer(files: engineFiles()) { server in
    server.setETagEnabled(false)
    let directory = try temporaryConsumer()

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status == 0, "\(result.stderr)")
    #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v1\n")
    #expect(readMarker(directory)["etag"] == nil)
    #expect(result.stderr.contains("no ETag header"))
  }
}

@Test
func helperValidatesWithAHeadRequestCarryingNoBody() async throws {
  // A GET-based probe would download and discard the full tarball on every
  // run whose upstream moved, doubling the transfer and making the 3 second
  // validation budget dishonest for anything but a tiny snapshot. A HEAD
  // probe carries no body either way, so the budget stays honest and a moved
  // upstream costs one real transfer instead of two. The cold run's marker
  // carries the real recorded etag, so the follow-up run's validation
  // genuinely matches and 304s, proving the HEAD request alone is enough
  // to confirm nothing changed.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()

    #expect(
      await runHelper(
        directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase]
      ).status == 0)

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status == 0, "\(result.stderr)")

    let requests = server.requests()
    #expect(requests.count == 2)
    #expect(requests[1].method == "HEAD")
    #expect(requests[1].bytes == 0)
    #expect(requests[1].status == 304)
  }
}

@Test
func helperDoesNotReuseAnEtagRecordedForADifferentRef() async throws {
  // A marker recorded while pinned to one ref must never validate against a
  // different ref: an unreachable new ref falling back to the old ref's
  // cached snapshot would be a wrong-content serve, not a safe reuse.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try warmSnapshot(directory)
    try writeMarker(directory, etag: "\"cached-for-main\"", age: recentMarkerAge)

    let result = await runHelper(
      directory: directory,
      environment: [
        "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
        "SWIFT_MK_API_REF": "release/2.0",
      ])
    #expect(result.status == 0, "\(result.stderr)")

    #expect(server.requests().count == 1)
    #expect(
      server.requests()[0].ifNoneMatch.isEmpty,
      "a marker recorded for a different ref must not be sent as a conditional header")
    #expect(server.requests()[0].path == "/agoodkind/swift-makefile/tar.gz/release/2.0")
  }
}

@Test
func helperFailsInCIRatherThanServingFromDiskEvenWithARecentMarker() async throws {
  // Regression guard for the serve-from-disk gate's `! running_in_ci` check.
  // Today that check is never actually exercised by any test: known_etag is
  // already forced empty in CI by an earlier guard (the one that reads the
  // marker at all), so the two CI checks are redundant, and a later refactor
  // could silently drop the second one without any test noticing. This test
  // builds exactly the marker helperServesSnapshotWhenUpstreamStallsAndMarkerIsRecent
  // uses to earn a successful serve-from-disk off-CI (a recent timestamp, a
  // stalling upstream), but in CI, and additionally forces the real fetch to
  // fail (forceStatus(500)): since known_etag is empty in CI regardless, the
  // helper never even attempts validation and goes straight to provision,
  // whose failure here proves CI took the hard-failure path, not a silent
  // reuse of the warm tree.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try warmSnapshot(directory)
    try writeMarker(directory, etag: "\"cached\"", age: freshMarkerAge)
    server.stall(5)
    server.forceStatus(500)

    let result = await runHelper(
      directory: directory,
      environment: [
        "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
        "GITHUB_ACTIONS": "true",
        "GITHUB_RUN_ID": "1",
      ])
    #expect(result.status != 0)
    #expect(!result.stderr.contains("serving the .make snapshot validated"))
  }
}

@Test
func helperFailsWhenStaleStagingDirectoryCannotBeCleared() async throws {
  // install_from_stage clears .make.next and .make.previous before staging a
  // new tree, with no status check on that rm. A stale, undeletable file
  // inside .make.next (marked immutable here with chflags uchg, a real,
  // unmocked removal failure rather than an injected one) still lets
  // mkdir -p succeed against the existing directory and lets cp -R add every
  // new file alongside it, since the directory itself stays writable; only
  // the specific immutable path resists removal. Both assets_complete checks
  // would then pass, since every required asset the fetch provides is
  // present, and the swap would proceed with exit 0 even though a stale
  // orphaned file rode along into the "verified" .make, which is exactly what
  // snapshot_clear_engine exists to prevent. install_from_stage must check
  // the initial rm and fail instead of continuing past it.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()

    let staleNextDir = (directory as NSString).appendingPathComponent(".make.next")
    try FileManager.default.createDirectory(atPath: staleNextDir, withIntermediateDirectories: true)
    let stalePath = (staleNextDir as NSString).appendingPathComponent("orphaned-stale-file")
    try "stale\n".write(toFile: stalePath, atomically: true, encoding: .utf8)

    let immutableStatus = await OffPoolWork.run {
      BootstrapHelperRunner.chflagsStatus("uchg", stalePath)
    }
    #expect(immutableStatus == 0, "could not mark the stale file immutable")
    defer {
      // Synchronous on purpose: `defer` cannot await, and this is the last thing the
      // test does, so the brief block cannot pile up behind other work.
      _ = BootstrapHelperRunner.chflagsStatus("nouchg", stalePath)
    }

    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    #expect(result.status != 0)
    // The swap must never have happened: no .make with the orphaned file
    // riding along inside it.
    #expect(readMakeFile(directory, "swift.mk") == nil)
  }
}

/// 2 KB/s, matching the rate team-lead calibrated on the go side. Comfortably
/// above the script's 1024 B/s floor.
let slowButProgressingBytesPerSecond = 2_048
/// Long enough to cover several FETCH_SPEED_TIME (3s) windows, so the test
/// proves sustained non-abort rather than a lucky single window.
let slowButProgressingMinimumSeconds = 6.0
/// Random, so gzip cannot shrink it away: the trickle rate needs a compressed
/// body this large to sustain slowButProgressingMinimumSeconds of transfer.
func randomHardToCompressContent(byteCount: Int) -> String {
  var bytes = [UInt8](repeating: 0, count: byteCount)
  for index in bytes.indices {
    bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
  }
  return Data(bytes).base64EncodedString()
}

@Test
func helperCompletesASlowButProgressingTransfer() async throws {
  // The companion to the bounded-stall test above: a transfer that never stops
  // making progress, even below a comfortable margin, must not be aborted.
  // Without this, a later tightening of FETCH_SPEED_LIMIT or FETCH_SPEED_TIME
  // could silently start failing a working, merely slow, network, and nothing
  // would catch it.
  // Sized to serve roughly 9 seconds at slowButProgressingBytesPerSecond: long
  // enough to clear slowButProgressingMinimumSeconds (6s, several
  // FETCH_SPEED_TIME windows) with room to spare, short enough to stay well
  // under the script's 15 second FETCH_MAX_TIME backstop.
  var files = engineFiles()
  files["swift.mk"] = randomHardToCompressContent(byteCount: 17_000)
  try await FetchServer.withServer(files: files) { server in
    server.trickle(bytesPerSecond: slowButProgressingBytesPerSecond)
    let directory = try temporaryConsumer()

    let start = Date()
    let result = await runHelper(
      directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
    let elapsed = Date().timeIntervalSince(start)

    #expect(result.status == 0, "\(result.stderr)")
    #expect(
      elapsed >= slowButProgressingMinimumSeconds,
      "the transfer finished in \(elapsed)s, too fast to have exercised sustained trickling; the fixture needs to be larger relative to the trickle rate"
    )
    #expect(readMakeFile(directory, "swift.mk")?.isEmpty == false)
  }
}

@Test
func helperReportsRealReasonWhenValidationTempFileCannotBeCreated() async throws {
  // On the go side, a silent local mktemp failure in the validation path
  // routed to the offline-reuse branch, so a full or unwritable TMPDIR read as
  // "upstream unreachable" and served stale assets for an hour with nothing
  // naming the real cause. This script's equivalent failure is structurally
  // not reuse-eligible (the return fires before the marker_is_recent check is
  // ever reached), but it was silent, an opaque exit 1 with no message at all.
  //
  // SWIFT_MK_BOOTSTRAP_REEXEC=1 skips the helper's own re-exec-from-temp-copy
  // step, which also calls mktemp against the same TMPDIR and would otherwise
  // fail first, masking the specific failure this test targets.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try warmSnapshot(directory)
    try writeMarker(directory, etag: "\"cached\"", age: recentMarkerAge)

    let badTmpDir = (directory as NSString).appendingPathComponent("no-such-tmp")
    let result = await runHelper(
      directory: directory,
      environment: [
        "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
        "SWIFT_MK_BOOTSTRAP_REEXEC": "1",
        "TMPDIR": badTmpDir,
      ])
    #expect(result.status != 0)
    #expect(!result.stderr.contains("serving the .make snapshot validated"))
    #expect(result.stderr.contains("could not create a temporary file for validation"))
  }
}
