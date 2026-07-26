//
//  FetchServerTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

// MARK: - FetchServerTests

enum FetchServerTests {}

@Test
func fetchServerServesTarballAndHonorsIfNoneMatch() async throws {
  let server = try FetchServer(files: ["swift.mk": "SWIFT_MK := 1\n"])
  defer { server.shutdown() }

  let url = try #require(
    URL(string: server.codeloadBase + "/agoodkind/swift-makefile/tar.gz/main"))
  let (firstBody, firstResponse) = try await URLSession.shared.data(from: url)
  let firstHTTP = try #require(firstResponse as? HTTPURLResponse)
  #expect(firstHTTP.statusCode == 200)
  #expect(!firstBody.isEmpty)

  let etag = try #require(firstHTTP.value(forHTTPHeaderField: "ETag"))

  var conditional = URLRequest(url: url)
  conditional.setValue(etag, forHTTPHeaderField: "If-None-Match")
  conditional.cachePolicy = .reloadIgnoringLocalCacheData
  let (_, secondResponse) = try await URLSession.shared.data(for: conditional)
  #expect((secondResponse as? HTTPURLResponse)?.statusCode == 304)

  server.setFiles(["swift.mk": "SWIFT_MK := 2\n"])
  let (_, thirdResponse) = try await URLSession.shared.data(for: conditional)
  #expect((thirdResponse as? HTTPURLResponse)?.statusCode == 200)

  #expect(server.requests().count == 3)
}

@Test
func fetchServerArchiveExtractsWithSystemTar() throws {
  let server = try FetchServer(
    files: [
      "swift.mk": "# swift.mk v1\n",
      "scripts/swift-mk-build.sh": "#!/usr/bin/env bash\nexit 0\n",
    ])
  defer { server.shutdown() }

  let manager = FileManager.default
  let workDirectory = manager.temporaryDirectory.appendingPathComponent(
    "fetch-extract-" + UUID().uuidString, isDirectory: true)
  try manager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
  defer { try? manager.removeItem(at: workDirectory) }

  let archive = workDirectory.appendingPathComponent("snapshot.tar.gz")
  let url = try #require(
    URL(string: server.codeloadBase + "/agoodkind/swift-makefile/tar.gz/main"))
  try Data(contentsOf: url).write(to: archive)

  // The helper extracts with --strip-components 1, so prove the archive has the
  // single top-level directory that flattening depends on.
  let target = workDirectory.appendingPathComponent("tree", isDirectory: true)
  try manager.createDirectory(at: target, withIntermediateDirectories: true)
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [
    "tar", "-xzf", archive.path, "-C", target.path, "--strip-components", "1",
  ]
  try process.run()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)

  let extracted = try String(
    contentsOf: target.appendingPathComponent("swift.mk"), encoding: .utf8)
  #expect(extracted == "# swift.mk v1\n")
  #expect(manager.fileExists(atPath: target.appendingPathComponent("scripts/swift-mk-build.sh").path))
}
