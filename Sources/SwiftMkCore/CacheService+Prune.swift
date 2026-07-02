//
//  CacheService+Prune.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - CachePruneResult

public struct CachePruneResult: Equatable, Sendable {
  public let path: String
  public let maxBytes: UInt64
  public let initialBytes: UInt64
  public let finalBytes: UInt64
  public let removedBytes: UInt64
  public let removedEntries: Int
}

// MARK: - CachePruneError

/// Refuses to prune a path that is empty, root, or too shallow, so a mistyped
/// `--path` cannot delete unrelated directories.
public enum CachePruneError: Error, Equatable, Sendable {
  case unsafePath(String)
}

// MARK: - CacheService Prune

extension CacheService {
  /// `cache prune`: remove least-recently-used entries under the shared cache root
  /// until the cache is at or below `maxBytes`. Directories whose names start with
  /// `.tmp` are ignored because another process may still be populating them.
  public static func runPrune(maxBytes: UInt64, path: String? = nil) -> Int32 {
    let prunePath = path ?? defaultSharedCacheRootPath()
    Output.info("cache prune: pruning \(prunePath) to \(maxBytes) bytes")
    do {
      let result = try prune(maxBytes: maxBytes, path: prunePath)
      Output.log(
        "cache prune: \(result.initialBytes) -> \(result.finalBytes) bytes, "
          + "removed \(result.removedEntries) entr\(result.removedEntries == 1 ? "y" : "ies")"
      )
      return 0
    } catch {
      Output.error("cache prune: \(error)")
      return usageExitCode
    }
  }

  public static func prune(maxBytes: UInt64, path: String? = nil) throws -> CachePruneResult {
    let prunePath = path ?? defaultSharedCacheRootPath()
    try validatePrunePath(prunePath)
    let root = URL(fileURLWithPath: prunePath, isDirectory: true)
    Output.debug("cache prune: inspecting \(root.path)")
    guard FileManager.default.fileExists(atPath: root.path) else {
      return CachePruneResult(
        path: root.path,
        maxBytes: maxBytes,
        initialBytes: 0,
        finalBytes: 0,
        removedBytes: 0,
        removedEntries: 0
      )
    }

    let snapshot = try pruneSnapshot(root: root)
    var currentBytes = snapshot.totalBytes
    var removedBytes: UInt64 = 0
    var removedEntries = 0
    if currentBytes > maxBytes {
      for entry in snapshot.entries.sorted(by: pruneEntrySort) {
        if currentBytes <= maxBytes {
          break
        }
        // Isolate per-entry failures: a single undeletable entry (a permission
        // error or a file vanishing mid-run) must not discard the eviction
        // progress already made, so log it and keep going.
        do {
          try FileManager.default.removeItem(at: entry.url)
          currentBytes = currentBytes > entry.bytes ? currentBytes - entry.bytes : 0
          removedBytes += entry.bytes
          removedEntries += 1
        } catch {
          Output.error("cache prune: skipping \(entry.url.path): \(error)")
        }
      }
    }
    return CachePruneResult(
      path: root.path,
      maxBytes: maxBytes,
      initialBytes: snapshot.totalBytes,
      finalBytes: currentBytes,
      removedBytes: removedBytes,
      removedEntries: removedEntries
    )
  }

  /// The fewest path components a prune root must have below filesystem root. A
  /// cache dir like /Users/x/pool-cache clears the bar; "/" or "/Users" does
  /// not, so a mistyped `--path` cannot evict unrelated data.
  private static let minimumPrunePathComponents = 2

  /// Rejects an empty, root, or shallow prune path so a mistyped `--path` like
  /// "/" or "/Users" cannot evict unrelated data.
  private static func validatePrunePath(_ path: String) throws {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw CachePruneError.unsafePath(path)
    }
    let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
    let components = standardized.split(separator: "/", omittingEmptySubsequences: true)
    if standardized == "/" || components.count < minimumPrunePathComponents {
      throw CachePruneError.unsafePath(standardized)
    }
  }

  private struct PruneEntry {
    var url: URL
    var bytes: UInt64
    var lastUsed: Date
  }

  private static func pruneSnapshot(
    root: URL
  ) throws -> (totalBytes: UInt64, entries: [PruneEntry]) {
    let contents = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [
        .contentAccessDateKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey,
      ]
    )
    var totalBytes: UInt64 = 0
    var entries: [PruneEntry] = []
    for url in contents {
      if isTemporaryDirectory(url) {
        continue
      }
      let bytes = cacheEntrySize(url)
      totalBytes += bytes
      entries.append(PruneEntry(url: url, bytes: bytes, lastUsed: lastUsedDate(url)))
    }
    return (totalBytes, entries)
  }

  private static func pruneEntrySort(_ left: PruneEntry, _ right: PruneEntry) -> Bool {
    if left.lastUsed == right.lastUsed {
      return left.url.path < right.url.path
    }
    return left.lastUsed < right.lastUsed
  }

  private static func cacheEntrySize(_ url: URL) -> UInt64 {
    if isDirectory(url) {
      return directoryByteCount(url)
    }
    return UInt64(max(fileSize(url), 0))
  }

  private static func directoryByteCount(_ url: URL) -> UInt64 {
    let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: keys
      )
    else {
      return 0
    }
    var totalBytes: UInt64 = 0
    for case let item as URL in enumerator {
      if isTemporaryDirectory(item) {
        enumerator.skipDescendants()
        continue
      }
      if !isDirectory(item) {
        totalBytes += UInt64(max(fileSize(item), 0))
      }
    }
    return totalBytes
  }

  private static func isTemporaryDirectory(_ url: URL) -> Bool {
    url.lastPathComponent.hasPrefix(".tmp") && isDirectory(url)
  }

  private static func isDirectory(_ url: URL) -> Bool {
    do {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      return values.isDirectory == true
    } catch {
      Output.debug("cache prune: could not inspect directory flag for \(url.path): \(error)")
      return false
    }
  }

  private static func fileSize(_ url: URL) -> Int {
    do {
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      return values.fileSize ?? 0
    } catch {
      Output.debug("cache prune: could not inspect file size for \(url.path): \(error)")
      return 0
    }
  }

  private static func lastUsedDate(_ url: URL) -> Date {
    do {
      let values = try url.resourceValues(forKeys: [
        .contentAccessDateKey, .contentModificationDateKey,
      ])
      return values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
    } catch {
      Output.debug("cache prune: could not inspect access date for \(url.path): \(error)")
      return .distantPast
    }
  }
}
