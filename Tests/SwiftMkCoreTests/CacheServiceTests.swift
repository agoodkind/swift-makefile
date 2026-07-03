//
//  CacheServiceTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-24.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - CacheServiceTests

enum CacheServiceTests {}

@Test
func cleanRefusesPathsOutsideKnownCacheRoots() {
  // Reads the process working directory, so serialize against the gate tests that
  // temporarily chdir into a scratch checkout.
  TestGlobalLock.withLock {
    let home = Env.get("HOME", FileManager.default.homeDirectoryForCurrentUser.path)
    let cwd = FileManager.default.currentDirectoryPath
    // The filesystem root, $HOME, and the workspace itself are never removable, nor is
    // a sibling tree a misconfigured EXTRA_CACHE_PATHS (`.`, `..`) could resolve to.
    #expect(!CacheService.isWithinSafeRoots("/"))
    #expect(!CacheService.isWithinSafeRoots(""))
    #expect(!CacheService.isWithinSafeRoots("/usr/local/bin"))
    #expect(!CacheService.isWithinSafeRoots(home))
    #expect(!CacheService.isWithinSafeRoots(cwd))
    #expect(
      !CacheService.isWithinSafeRoots(
        (cwd as NSString).deletingLastPathComponent + "/other-repo"))
    #expect(!CacheService.isWithinSafeRoots("\(home)/Sites/some-project"))
  }
}

@Test
func cleanAllowsKnownCacheRoots() {
  // Reads the process working directory, so serialize against the gate tests that
  // temporarily chdir into a scratch checkout.
  TestGlobalLock.withLock {
    let home = Env.get("HOME", FileManager.default.homeDirectoryForCurrentUser.path)
    let cwd = FileManager.default.currentDirectoryPath
    #expect(CacheService.isWithinSafeRoots("\(home)/Library/Caches/swift-mk/ModuleCache"))
    #expect(CacheService.isWithinSafeRoots("\(home)/.local/share/mise/installs"))
    #expect(CacheService.isWithinSafeRoots("\(cwd)/.build"))
    #expect(CacheService.isWithinSafeRoots("\(cwd)/.derived-data/Index.noindex"))
  }
}

@Test
func customDerivedDataOutsideBoundaryIsNotCleanable() {
  // A consumer-set SWIFT_MK_DERIVED_DATA outside $HOME/workspace must not enter the
  // cleanable allowlist, or cache clean could delete an unrelated tree.
  #expect(
    CacheService.boundedDerivedDataRoot("/opt/external/.derived-data", home: "/h", cwd: "/ws")
      == nil)
  #expect(
    CacheService.boundedDerivedDataRoot("/ws/.derived-data", home: "/h", cwd: "/ws")
      == "/ws/.derived-data")
  // The workspace root itself (no subpath) is not a cleanable DerivedData root.
  #expect(CacheService.boundedDerivedDataRoot("/ws", home: "/h", cwd: "/ws") == nil)
}

@Test
func pruneRemovesLeastRecentlyUsedEntriesUntilUnderMaxBytes() throws {
  let root = try makeTemporaryCacheRoot()
  defer { removeTemporary(root.path) }

  let oldEntry = root.appendingPathComponent("old-cas-entry", isDirectory: true)
  let newEntry = root.appendingPathComponent("new-cas-entry", isDirectory: true)
  let temporaryEntry = root.appendingPathComponent(".tmp-populating", isDirectory: true)
  try writeCacheEntry(oldEntry, byteCount: 8, date: Date(timeIntervalSince1970: 100))
  try writeCacheEntry(newEntry, byteCount: 8, date: Date(timeIntervalSince1970: 200))
  try writeCacheEntry(temporaryEntry, byteCount: 64, date: Date(timeIntervalSince1970: 50))

  let result = try CacheService.prune(maxBytes: 8, path: root.path)

  #expect(result.initialBytes == 16)
  #expect(result.finalBytes == 8)
  #expect(result.removedEntries == 1)
  #expect(!FileManager.default.fileExists(atPath: oldEntry.path))
  #expect(FileManager.default.fileExists(atPath: newEntry.path))
  #expect(FileManager.default.fileExists(atPath: temporaryEntry.path))
}

@Test
func pruneRejectsUnsafePaths() {
  for unsafe in ["", " ", "/", "/Users", "/Users/runner"] {
    #expect(throws: CachePruneError.self) {
      _ = try CacheService.prune(maxBytes: 0, path: unsafe)
    }
  }
}

@Test
func pruneExpandsTildePathBeforeValidation() throws {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let path = "~/swift-mk-prune-\(UUID().uuidString)"
  let result = try CacheService.prune(maxBytes: 0, path: path)

  #expect(result.path == "\(home)/\(path.dropFirst(2))")
}

@Test
func pruneThrowsWhenDeletionFailuresLeaveCacheOverBudget() throws {
  let root = try makeTemporaryCacheRoot()
  defer {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: root.path
    )
    removeTemporary(root.path)
  }

  let entry = root.appendingPathComponent("kept-entry", isDirectory: true)
  try writeCacheEntry(entry, byteCount: 8, date: Date(timeIntervalSince1970: 100))
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

  #expect(
    throws: CachePruneError.limitNotReached(path: root.path, currentBytes: 8, maxBytes: 0)
  ) {
    _ = try CacheService.prune(maxBytes: 0, path: root.path)
  }
}

private func makeTemporaryCacheRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swiftmk-cache-prune-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private func writeCacheEntry(_ directory: URL, byteCount: Int, date: Date) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = directory.appendingPathComponent("payload.bin")
  try Data(repeating: 1, count: byteCount).write(to: file)
  try setDates(date, for: file)
  try setDates(date, for: directory)
}

private func setDates(_ date: Date, for url: URL) throws {
  var mutableURL = url
  var values = URLResourceValues()
  values.contentAccessDate = date
  values.contentModificationDate = date
  try mutableURL.setResourceValues(values)
}
