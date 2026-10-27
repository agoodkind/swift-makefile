//
//  ReleaseEngineTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-27.
//  Copyright © 2026, all rights reserved.
//

import CryptoKit
import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ReleaseEngineTests

enum ReleaseEngineTests {}

private let releaseTag = "26.10.99"
private let engineAsset = "swift-mk-engine_darwin_arm64.dmg"
private let checksumsAsset = "checksums.txt"
private let resourceBundleName = "swift-makefile_SwiftMkCore.bundle"
private let resourceFileName = "swiftlint.yml"
private let indexStoreLibraryName = "libIndexStore.dylib"
private let foundStatus = 302
private let okStatus = 200
/// The server uses this status to fail release discovery after installation.
private let lookupFailureStatus = 503

/// The dmg needs an executable that can pass the installer's version launch check.
private let fakeEngineScript = """
  #!/bin/sh
  printf 'version: \(releaseTag)\\n'
  """

/// A Swift invocation leaves evidence even when the caller ignores its exit status.
private let failingSwiftScript = """
  #!/bin/sh
  printf 'swift %s\\n' "$*" >> "${SWIFT_INVOCATIONS_FILE}"
  exit 1
  """

// MARK: - ReleasePaths

/// ReleasePaths stores request paths for one repository and the fixed test tag.
private struct ReleasePaths {
  let latest: String
  let tag: String
  let checksums: String
  let engine: String

  init(repository: String) {
    latest = "/\(repository)/releases/latest"
    tag = "/\(repository)/releases/tag/\(releaseTag)"
    checksums = "/\(repository)/releases/download/\(releaseTag)/\(checksumsAsset)"
    engine = "/\(repository)/releases/download/\(releaseTag)/\(engineAsset)"
  }
}

@Test
func releaseModeInstallsTheEngineDmgWithoutBuilding() async throws {
  let fixture = try await OffPoolWork.run { try EngineDmgFixture.make() }
  defer { removeIfPresent(fixture.directory) }

  try await FetchServer.withServer(files: engineFiles()) { server in
    let paths = ReleasePaths(repository: engineRepository)
    serveRelease(server, paths: paths, dmg: fixture.dmg, checksums: fixture.checksums)
    let directory = try temporaryConsumer()
    defer { removeIfPresent(directory) }

    let helper = await runHelper(
      directory: directory,
      environment: [
        "SWIFT_MK_API_REF_PINNED": "",
        "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
        "SWIFT_MK_RELEASE_BASE": server.codeloadBase,
      ])
    #expect(helper.status == 0, "helper failed: \(helper.stderr)")
    #expect(
      readMakeFile(directory, ".swift-mk-release")
        == "repo=\(engineRepository)\ntag=\(releaseTag)\n")
    let tarballPath = "/\(engineRepository)/tar.gz/\(releaseTag)"
    #expect(server.requests().contains { $0.path == tarballPath })

    let swiftInvocations = (directory as NSString).appendingPathComponent("swift-invocations")
    let first = await resolveEngine(
      directory: directory, server: server, swiftInvocations: swiftInvocations)
    #expect(first.status == 0, "resolve failed: \(first.stderr)")

    let second = await resolveEngine(
      directory: directory, server: server, swiftInvocations: swiftInvocations)
    #expect(second.status == 0, "second resolve failed: \(second.stderr)")

    let engineDownloads = server.requests().filter { $0.path == paths.engine }
    #expect(engineDownloads.count == 1, "a recorded tag with a present binary skips the download")
    #expect(!FileManager.default.fileExists(atPath: swiftInvocations), "release mode ran swift")

    let launched = await OffPoolWork.run {
      Shell.run(makePath(directory, "swift-mk"), ["version"])
    }
    #expect(launched.stdout == "version: \(releaseTag)\n")
    #expect(readMakeFile(directory, "swift-mk.release-tag") == "\(releaseTag)\n")
    #expect(readMakeFile(directory, "\(resourceBundleName)/\(resourceFileName)") != nil)

    let linkTarget = try FileManager.default.destinationOfSymbolicLink(
      atPath: makePath(directory, indexStoreLibraryName))
    #expect(linkTarget.hasSuffix("/usr/lib/\(indexStoreLibraryName)"))
    #expect(FileManager.default.fileExists(atPath: linkTarget))
  }
}

@Test
func releaseModeRejectsAnEngineDmgThatDoesNotMatchChecksums() async throws {
  let fixture = try await OffPoolWork.run { try EngineDmgFixture.make() }
  defer { removeIfPresent(fixture.directory) }

  try await FetchServer.withServer(files: engineFiles()) { server in
    let paths = ReleasePaths(repository: engineRepository)
    let wrongDigest = String(repeating: "0", count: SHA256.byteCount * 2)
    let wrongChecksums = "\(wrongDigest)  \(engineAsset)\n"
    serveRelease(server, paths: paths, dmg: fixture.dmg, checksums: wrongChecksums)
    let directory = try temporaryConsumer()
    defer { removeIfPresent(directory) }
    try writeMakeFile(
      directory, ".swift-mk-release", "repo=\(engineRepository)\ntag=\(releaseTag)\n")

    let swiftInvocations = (directory as NSString).appendingPathComponent("swift-invocations")
    let result = await resolveEngine(
      directory: directory, server: server, swiftInvocations: swiftInvocations)

    #expect(result.status != 0)
    #expect(result.stderr.contains(releaseTag))
    #expect(result.stderr.contains(engineAsset))
    #expect(result.stderr.contains(server.codeloadBase + paths.engine))
    #expect(!FileManager.default.fileExists(atPath: makePath(directory, "swift-mk")))
  }
}

@Test
func releaseModeReusesARecentReleaseWhenTheLookupFails() async throws {
  let fixture = try await OffPoolWork.run { try EngineDmgFixture.make() }
  defer { removeIfPresent(fixture.directory) }

  try await FetchServer.withServer(files: engineFiles()) { server in
    let paths = ReleasePaths(repository: engineRepository)
    serveRelease(server, paths: paths, dmg: fixture.dmg, checksums: fixture.checksums)
    let directory = try temporaryConsumer()
    defer { removeIfPresent(directory) }
    let swiftInvocations = (directory as NSString).appendingPathComponent("swift-invocations")

    let online = await runReleaseHelper(directory: directory, server: server)
    #expect(online.status == 0, "helper failed: \(online.stderr)")
    let installed = await resolveEngine(
      directory: directory, server: server, swiftInvocations: swiftInvocations)
    #expect(installed.status == 0, "resolve failed: \(installed.stderr)")

    server.setRoute(
      paths.latest, FetchRoute(status: lookupFailureStatus, headers: [:], body: []))
    let lookupURL = server.codeloadBase + paths.latest
    let failedLookupReason =
      "latest release lookup returned HTTP \(lookupFailureStatus) for \(lookupURL)"

    let offline = await runReleaseHelper(directory: directory, server: server)
    #expect(offline.status == 0, "recent release was not reused: \(offline.stderr)")
    #expect(offline.stderr.contains(failedLookupReason))
    #expect(offline.stderr.contains("serving release \(releaseTag)"))
    #expect(
      readMakeFile(directory, ".swift-mk-release")
        == "repo=\(engineRepository)\ntag=\(releaseTag)\n")

    let reused = await resolveEngine(
      directory: directory, server: server, swiftInvocations: swiftInvocations)
    #expect(reused.status == 0, "resolve failed: \(reused.stderr)")
    let engineDownloads = server.requests().filter { $0.path == paths.engine }
    #expect(engineDownloads.count == 1)

    let marker = readMarker(directory)
    let staleTimestamp = Int(Date().timeIntervalSince1970) - staleMarkerAge
    try writeMarker(
      directory, ref: releaseTag, etag: marker["etag"] ?? "", timestamp: staleTimestamp)
    let stale = await runReleaseHelper(directory: directory, server: server)
    #expect(stale.status != 0)
    #expect(stale.stderr.contains("error: \(failedLookupReason)"))

    let emptyDirectory = try temporaryConsumer()
    defer { removeIfPresent(emptyDirectory) }
    let cold = await runReleaseHelper(directory: emptyDirectory, server: server)
    #expect(cold.status != 0)
    #expect(cold.stderr.contains("error: \(failedLookupReason)"))
  }
}

/// Run the bootstrap helper in release mode against the local test server.
private func runReleaseHelper(
  directory: String, server: FetchServer
) async -> BootstrapHelperRunner.Result {
  await runHelper(
    directory: directory,
    environment: [
      "SWIFT_MK_API_REF_PINNED": "",
      "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
      "SWIFT_MK_RELEASE_BASE": server.codeloadBase,
    ])
}

/// Keep release discovery and asset downloads on the local source-tarball server.
private func serveRelease(
  _ server: FetchServer, paths: ReleasePaths, dmg: [UInt8], checksums: String
) {
  server.setRoute(
    paths.latest,
    FetchRoute(
      status: foundStatus,
      headers: ["Location": server.codeloadBase + paths.tag],
      body: []))
  server.setRoute(
    paths.checksums,
    FetchRoute(status: okStatus, headers: [:], body: Array(checksums.utf8)))
  server.setRoute(paths.engine, FetchRoute(status: okStatus, headers: [:], body: dmg))
}

/// Shell.run waits for a subprocess. OffPoolWork keeps that wait off the threads
/// Swift uses for async tests.
private func resolveEngine(
  directory: String, server: FetchServer, swiftInvocations: String
) async -> Shell.Result {
  let script = BootstrapHelperRunner.repositoryRoot() + "/scripts/swift-mk-build.sh"
  let fakeBin = (directory as NSString).appendingPathComponent("fakebin")
  let inheritedPath = TestGlobalLock.withLock {
    ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
  }
  let environment = [
    "PATH": fakeBin + ":" + inheritedPath,
    "SWIFT_MK_ROOT": directory,
    "SWIFT_MK_BIN": makePath(directory, "swift-mk"),
    "SWIFT_MK_BIN_VERIFIED": "",
    "SWIFT_MK_DEV_DIR": "",
    "SWIFT_MK_BUILD_REPO": "",
    "SWIFT_MK_RELEASE_BASE": server.codeloadBase,
    "SWIFT_INVOCATIONS_FILE": swiftInvocations,
  ]
  return await OffPoolWork.run {
    do {
      try FileManager.default.createDirectory(
        atPath: fakeBin, withIntermediateDirectories: true)
      let swiftPath = (fakeBin as NSString).appendingPathComponent("swift")
      try failingSwiftScript.write(toFile: swiftPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: writableDirectoryMode], ofItemAtPath: swiftPath)
    } catch {
      return Shell.Result(
        status: -1, stdout: "", stderr: "test: could not write the fake swift: \(error)")
    }
    return Shell.run("/bin/bash", [script, "resolve"], environment: environment)
  }
}

// MARK: - EngineDmgFixture

/// make() creates a dmg with a swift-mk shell script and one resource bundle, then
/// returns its bytes and a checksums.txt line with the SHA-256 digest and asset name.
/// Callers use OffPoolWork because hdiutil blocks the calling thread.
private struct EngineDmgFixture {
  let directory: String
  let dmg: [UInt8]
  let checksums: String

  static func make() throws -> EngineDmgFixture {
    let manager = FileManager.default
    let fixtureDirectory = NSTemporaryDirectory() + "swift-mk-engine-dmg-" + UUID().uuidString
    let source = (fixtureDirectory as NSString).appendingPathComponent("source")
    let bundle = (source as NSString).appendingPathComponent(resourceBundleName)
    try manager.createDirectory(atPath: bundle, withIntermediateDirectories: true)
    let engine = (source as NSString).appendingPathComponent("swift-mk")
    try fakeEngineScript.write(toFile: engine, atomically: true, encoding: .utf8)
    try manager.setAttributes([.posixPermissions: writableDirectoryMode], ofItemAtPath: engine)
    try "# swiftlint\n".write(
      toFile: (bundle as NSString).appendingPathComponent(resourceFileName),
      atomically: true,
      encoding: .utf8)

    let dmgPath = (fixtureDirectory as NSString).appendingPathComponent(engineAsset)
    let created = Shell.run(
      "/usr/bin/hdiutil",
      [
        "create", "-quiet", "-srcfolder", source, "-volname", "swift-mk", "-format", "UDZO",
        dmgPath,
      ])
    guard created.status == 0 else {
      throw ReleaseEngineFixtureError.hdiutilFailed(created.stderr)
    }
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: dmgPath)))
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return EngineDmgFixture(
      directory: fixtureDirectory,
      dmg: bytes,
      checksums: "\(digest)  \(engineAsset)\n")
  }
}

// MARK: - ReleaseEngineFixtureError

private enum ReleaseEngineFixtureError: Error {
  case hdiutilFailed(String)
}
