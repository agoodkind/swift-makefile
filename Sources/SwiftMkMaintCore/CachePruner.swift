//
//  CachePruner.swift
//  SwiftMkMaintCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - CachePruneError

public enum CachePruneError: Error, CustomStringConvertible, Equatable {
  case filesystem(String)
  case missingPath(String)
  case notDirectory(String)
  case pathRequired

  public var description: String {
    switch self {
    case .filesystem(let message):
      return message
    case .missingPath(let path):
      return "cache prune: missing path \(path)"
    case .notDirectory(let path):
      return "cache prune: path is not a directory \(path)"
    case .pathRequired:
      return "cache prune: --path is required"
    }
  }
}

// MARK: - CachePruneSkippedEntry

public struct CachePruneSkippedEntry: Equatable {
  public let name: String
  public let reason: String

  public init(name: String, reason: String) {
    self.name = name
    self.reason = reason
  }
}

// MARK: - CachePruneDiagnostics

public struct CachePruneDiagnostics {
  private let infoHandler: (String) -> Void
  private let warningHandler: (String) -> Void
  private let errorHandler: (String) -> Void

  public init() {
    self.init(info: Self.ignore, warning: Self.ignore, error: Self.ignore)
  }

  public init(
    info: @escaping (String) -> Void,
    warning: @escaping (String) -> Void,
    error: @escaping (String) -> Void
  ) {
    self.infoHandler = info
    self.warningHandler = warning
    self.errorHandler = error
  }

  public func info(_ message: String) {
    infoHandler(message)
  }

  public func warning(_ message: String) {
    warningHandler(message)
  }

  public func error(_ message: String) {
    errorHandler(message)
  }

  private static func ignore(_ message: String) {
    _ = message
  }
}

// MARK: - CachePruneResult

public struct CachePruneResult: Equatable {
  public let path: String
  public let maxBytes: UInt64
  public let totalBytes: UInt64
  public let remainingBytes: UInt64
  public let evictedBytes: UInt64
  public let evictedEntries: [CachePruneEntry]
  public let skippedEntries: [CachePruneSkippedEntry]

  public init(
    path: String,
    maxBytes: UInt64,
    totalBytes: UInt64,
    remainingBytes: UInt64,
    evictedBytes: UInt64,
    evictedEntries: [CachePruneEntry],
    skippedEntries: [CachePruneSkippedEntry]
  ) {
    self.path = path
    self.maxBytes = maxBytes
    self.totalBytes = totalBytes
    self.remainingBytes = remainingBytes
    self.evictedBytes = evictedBytes
    self.evictedEntries = evictedEntries
    self.skippedEntries = skippedEntries
  }
}

// MARK: - CachePruner

public struct CachePruner {
  private static let resourceKeys: Set<URLResourceKey> = [
    .contentModificationDateKey,
    .fileSizeKey,
    .isDirectoryKey,
    .isSymbolicLinkKey,
  ]

  private let fileManager: FileManager
  private let diagnostics: CachePruneDiagnostics

  public init(
    fileManager: FileManager = .default,
    diagnostics: CachePruneDiagnostics = CachePruneDiagnostics()
  ) {
    self.fileManager = fileManager
    self.diagnostics = diagnostics
  }

  @discardableResult
  public func prune(
    path: String,
    maxBytes: UInt64
  ) throws -> CachePruneResult {
    let directoryURL = try resolvedDirectoryURL(path)
    diagnostics.info("cache prune: inspecting \(directoryURL.path)")
    var skippedEntries: [CachePruneSkippedEntry] = []
    let entries = try collectEntries(under: directoryURL, skippedEntries: &skippedEntries)
    let evictions = CachePrunePlanner.evictions(entries: entries, maxBytes: maxBytes)

    for entry in evictions {
      let entryURL = directoryURL.appendingPathComponent(entry.name, isDirectory: false)
      do {
        try fileManager.removeItem(at: entryURL)
      } catch {
        diagnostics.error("cache prune: could not remove \(entryURL.path): \(error)")
        throw CachePruneError.filesystem(
          "cache prune: could not remove \(entryURL.path): \(error)")
      }
    }

    let totalBytes = CachePrunePlanner.totalSize(entries)
    let remainingBytes = CachePrunePlanner.remainingSize(
      totalBytes: totalBytes,
      evictedEntries: evictions)
    let evictedBytes = CachePrunePlanner.totalSize(evictions)
    return CachePruneResult(
      path: directoryURL.path,
      maxBytes: maxBytes,
      totalBytes: totalBytes,
      remainingBytes: remainingBytes,
      evictedBytes: evictedBytes,
      evictedEntries: evictions,
      skippedEntries: skippedEntries)
  }

  private func resolvedDirectoryURL(_ path: String) throws -> URL {
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedPath.isEmpty {
      throw CachePruneError.pathRequired
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: trimmedPath, isDirectory: &isDirectory) else {
      throw CachePruneError.missingPath(trimmedPath)
    }
    guard isDirectory.boolValue else {
      throw CachePruneError.notDirectory(trimmedPath)
    }
    return URL(fileURLWithPath: trimmedPath, isDirectory: true).standardizedFileURL
  }

  private func collectEntries(
    under directoryURL: URL,
    skippedEntries: inout [CachePruneSkippedEntry]
  ) throws -> [CachePruneEntry] {
    let entryURLs: [URL]
    do {
      entryURLs = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: Array(Self.resourceKeys),
        options: [])
    } catch {
      diagnostics.error("cache prune: could not list \(directoryURL.path): \(error)")
      throw CachePruneError.filesystem(
        "cache prune: could not list \(directoryURL.path): \(error)")
    }

    var entries: [CachePruneEntry] = []
    for entryURL in entryURLs {
      do {
        entries.append(try entry(for: entryURL, skippedEntries: &skippedEntries))
      } catch {
        skippedEntries.append(
          CachePruneSkippedEntry(name: entryURL.lastPathComponent, reason: "\(error)"))
        diagnostics.warning("cache prune: skipped \(entryURL.lastPathComponent): \(error)")
        continue
      }
    }
    return entries
  }

  private func entry(
    for entryURL: URL,
    skippedEntries: inout [CachePruneSkippedEntry]
  ) throws -> CachePruneEntry {
    let values = try entryURL.resourceValues(forKeys: Self.resourceKeys)
    let size = size(
      of: entryURL,
      values: values,
      skippedEntries: &skippedEntries)
    return CachePruneEntry(
      name: entryURL.lastPathComponent,
      size: size,
      modificationDate: values.contentModificationDate ?? Date.distantPast)
  }

  private func size(
    of entryURL: URL,
    values: URLResourceValues,
    skippedEntries: inout [CachePruneSkippedEntry]
  ) -> UInt64 {
    let isDirectory = values.isDirectory == true
    let isSymbolicLink = values.isSymbolicLink == true
    if isDirectory, !isSymbolicLink {
      return directoryContentsSize(entryURL, skippedEntries: &skippedEntries)
    }
    return fileSize(values)
  }

  private func directoryContentsSize(
    _ directoryURL: URL,
    skippedEntries: inout [CachePruneSkippedEntry]
  ) -> UInt64 {
    var enumerationSkippedEntries: [CachePruneSkippedEntry] = []
    guard
      let enumerator = fileManager.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: Array(Self.resourceKeys),
        options: [],
        errorHandler: { url, error in
          enumerationSkippedEntries.append(
            CachePruneSkippedEntry(name: url.lastPathComponent, reason: "\(error)"))
          return true
        })
    else {
      // A nil enumerator (for example a directory we cannot open) must not be
      // silently counted as zero bytes: record it as skipped so the total is not
      // under-counted and the entry is visibly not pruned.
      skippedEntries.append(
        CachePruneSkippedEntry(
          name: directoryURL.lastPathComponent, reason: "could not enumerate directory"))
      diagnostics.warning("cache prune: could not enumerate \(directoryURL.path)")
      return 0
    }

    var total: UInt64 = 0
    for case let childURL as URL in enumerator {
      do {
        let values = try childURL.resourceValues(forKeys: Self.resourceKeys)
        if values.isSymbolicLink == true {
          total = CachePrunePlanner.add(total, fileSize(values))
          enumerator.skipDescendants()
          continue
        }
        if values.isDirectory == true {
          continue
        }
        total = CachePrunePlanner.add(total, fileSize(values))
      } catch {
        skippedEntries.append(
          CachePruneSkippedEntry(name: childURL.lastPathComponent, reason: "\(error)"))
        diagnostics.warning("cache prune: skipped \(childURL.lastPathComponent): \(error)")
        continue
      }
    }
    skippedEntries.append(contentsOf: enumerationSkippedEntries)
    return total
  }

  private func fileSize(_ values: URLResourceValues) -> UInt64 {
    guard let size = values.fileSize, size > 0 else {
      return 0
    }
    return UInt64(size)
  }
}
