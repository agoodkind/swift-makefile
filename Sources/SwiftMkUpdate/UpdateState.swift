//
//  UpdateState.swift
//  SwiftMkUpdate
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-02.
//  Copyright © 2026, all rights reserved.
//

import Darwin
import Foundation

// MARK: - UpdateResult

public enum UpdateResult: String, Codable, Equatable {
  case applied
  case checked
  case dryRun = "dry_run"
  case error
  case upToDate = "up_to_date"
}

// MARK: - UpdateState

public struct UpdateState: Codable, Equatable {
  public let lastCheck: Date?
  public let lastResult: UpdateResult?
  public let lastError: String?
  public let lastAppliedTag: String?

  public init(
    lastCheck: Date? = nil,
    lastResult: UpdateResult? = nil,
    lastError: String? = nil,
    lastAppliedTag: String? = nil
  ) {
    self.lastCheck = lastCheck
    self.lastResult = lastResult
    self.lastError = lastError
    self.lastAppliedTag = lastAppliedTag
  }

  enum CodingKeys: String, CodingKey {
    case lastAppliedTag = "last_applied_tag"
    case lastCheck = "last_check"
    case lastError = "last_error"
    case lastResult = "last_result"
  }
}

// MARK: - State persistence

public func loadState(path: String) throws -> UpdateState {
  UpdateDiagnostics.debug("update state load \(path)")
  if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    throw UpdateError.validation("update state path is required")
  }
  guard FileManager.default.fileExists(atPath: path) else {
    return UpdateState()
  }
  do {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(UpdateState.self, from: data)
  } catch {
    throw UpdateError.filesystem("read update state \(path): \(error)")
  }
}

public func saveState(_ state: UpdateState, path: String) throws {
  UpdateDiagnostics.debug("update state save \(path)")
  if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    throw UpdateError.validation("update state path is required")
  }
  let url = URL(fileURLWithPath: path)
  let directory = url.deletingLastPathComponent()
  do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(state)
    data.append(Data("\n".utf8))
    let temporaryURL = directory.appendingPathComponent(
      "\(url.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      try data.write(to: temporaryURL)
    } catch {
      // Remove the partial temp file so a failed write (disk full, permissions)
      // does not leave stale *.tmp files in the state directory. renameFile
      // handles its own source cleanup on the rename path.
      removeTemporaryStateFile(temporaryURL)
      throw error
    }
    try renameFile(from: temporaryURL.path, to: path, context: "replace update state")
  } catch let error as UpdateError {
    throw error
  } catch {
    throw UpdateError.filesystem("save update state \(path): \(error)")
  }
}

/// Best-effort removal of a leftover atomic-write temp file. A cleanup failure
/// is logged rather than thrown so it cannot mask the original write error.
private func removeTemporaryStateFile(_ url: URL) {
  do {
    try FileManager.default.removeItem(at: url)
  } catch {
    UpdateDiagnostics.warning("update state temp cleanup failed: \(error)")
  }
}

// MARK: - Default paths

/// Return the XDG base for `key`, honoring the spec: an unset, empty, or
/// relative value is invalid and falls back to the default, so state and cache
/// never land under the current working directory.
private func xdgBase(
  _ environment: [String: String],
  key: String,
  fallback: () -> String
) -> String {
  if let value = environment[key], value.hasPrefix("/") {
    return value
  }
  return fallback()
}

public func defaultStatePath(
  binary: String,
  environment: [String: String] = ProcessInfo.processInfo.environment,
  homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> String {
  let base = xdgBase(environment, key: "XDG_STATE_HOME") {
    homeDirectory
      .appendingPathComponent(".local")
      .appendingPathComponent("state")
      .path
  }
  return URL(fileURLWithPath: base, isDirectory: true)
    .appendingPathComponent(binary)
    .appendingPathComponent("update-state.json")
    .path
}

public func defaultCacheDir(
  binary: String,
  environment: [String: String] = ProcessInfo.processInfo.environment,
  homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> String {
  let base = xdgBase(environment, key: "XDG_CACHE_HOME") {
    homeDirectory
      .appendingPathComponent("Library")
      .appendingPathComponent("Caches")
      .path
  }
  return URL(fileURLWithPath: base, isDirectory: true)
    .appendingPathComponent(binary)
    .appendingPathComponent("update")
    .path
}

// MARK: - File replacement

func renameFile(from sourcePath: String, to targetPath: String, context: String) throws {
  UpdateDiagnostics.debug("update rename \(context)")
  if Darwin.rename(sourcePath, targetPath) != 0 {
    let code = errno
    do {
      try FileManager.default.removeItem(atPath: sourcePath)
    } catch {
      UpdateDiagnostics.warning("update rename cleanup failed: \(error)")
    }
    throw UpdateError.filesystem("\(context): \(String(cString: strerror(code)))")
  }
}
