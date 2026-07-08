//
//  CachePrunerTests.swift
//  SwiftMkMaintCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkMaintCore

// MARK: - CachePrunerTests

@Suite(.serialized)
enum CachePrunerTests {
  @Test
  static func missingPathReportsTypedError() throws {
    try withTemporaryDirectory { directory in
      let missingPath = directory.appendingPathComponent("missing").path
      let pruner = CachePruner()

      #expect(throws: CachePruneError.self) {
        try pruner.prune(path: missingPath, maxBytes: 1)
      }
    }
  }

  @Test
  static func symlinkedPruneRootResolvesBeforeSafetyValidation() throws {
    try withTemporaryDirectory { directory in
      let symlink = directory.appendingPathComponent("cache-link", isDirectory: true)
      try FileManager.default.createSymbolicLink(
        at: symlink,
        withDestinationURL: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
      let resolvedTarget = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path

      #expect(throws: CachePruneError.unsafePath(resolvedTarget)) {
        try CachePruner().prune(path: symlink.path, maxBytes: UInt64.max)
      }
    }
  }

  @Test
  static func symlinkAndUnreadableEntryDoNotCrashDriver() throws {
    try withTemporaryDirectory { directory in
      let target = directory.appendingPathComponent("target.txt")
      let symlink = directory.appendingPathComponent("link.txt")
      let unreadable = directory.appendingPathComponent("unreadable", isDirectory: true)
      try writeBytes(8, to: target)
      try FileManager.default.createSymbolicLink(
        at: symlink,
        withDestinationURL: target)
      try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0],
        ofItemAtPath: unreadable.path)
      defer {
        restorePermissions(for: unreadable)
      }

      let result = try CachePruner().prune(path: directory.path, maxBytes: UInt64.max)

      #expect(result.evictedEntries.isEmpty)
      #expect(FileManager.default.fileExists(atPath: symlink.path))
      #expect(FileManager.default.fileExists(atPath: unreadable.path))
    }
  }

  @Test
  static func driverEvictsOldestFirstKeepsTemporaryEntriesAndStopsAtCap() throws {
    try withTemporaryDirectory { directory in
      let oldest = directory.appendingPathComponent("oldest.bin")
      let middle = directory.appendingPathComponent("middle.bin")
      let newest = directory.appendingPathComponent("newest.bin")
      let temporary = directory.appendingPathComponent(".tmp-in-flight")
      try writeBytes(50, to: oldest)
      try writeBytes(40, to: middle)
      try writeBytes(10, to: newest)
      try writeBytes(80, to: temporary)
      try setModificationDate(100, for: oldest)
      try setModificationDate(200, for: middle)
      try setModificationDate(300, for: newest)
      try setModificationDate(50, for: temporary)

      let result = try CachePruner().prune(path: directory.path, maxBytes: 90)

      #expect(result.evictedEntries.map(\.name) == ["oldest.bin", "middle.bin"])
      #expect(result.remainingBytes == 90)
      #expect(!FileManager.default.fileExists(atPath: oldest.path))
      #expect(!FileManager.default.fileExists(atPath: middle.path))
      #expect(FileManager.default.fileExists(atPath: newest.path))
      #expect(FileManager.default.fileExists(atPath: temporary.path))
    }
  }

  private static func withTemporaryDirectory(_ run: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-maint-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      removeTemporaryDirectory(directory)
    }
    try run(directory)
  }

  private static func restorePermissions(for url: URL) {
    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: url.path)
    } catch {
      TestDiagnostics.warning("could not restore permissions for \(url.path): \(error)")
    }
  }

  private static func removeTemporaryDirectory(_ directory: URL) {
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      TestDiagnostics.warning("could not remove temporary directory \(directory.path): \(error)")
    }
  }

  private static func writeBytes(_ count: Int, to url: URL) throws {
    let data = Data(repeating: 0x61, count: count)
    try data.write(to: url)
  }

  private static func setModificationDate(_ timestamp: TimeInterval, for url: URL) throws {
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: timestamp)],
      ofItemAtPath: url.path)
  }
}

// MARK: - TestDiagnostics

private enum TestDiagnostics {
  static func warning(_ message: String) {
    Issue.record(TestIssue(message: message))
  }
}

// MARK: - TestIssue

private struct TestIssue: Error, CustomStringConvertible {
  let message: String

  var description: String {
    message
  }
}
