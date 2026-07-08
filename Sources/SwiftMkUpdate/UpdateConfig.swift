//
//  UpdateConfig.swift
//  SwiftMkUpdate
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-02.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - UpdateError

public enum UpdateError: Error, CustomStringConvertible {
  case checksum(String)
  case command(String)
  case filesystem(String)
  case http(String)
  case release(String)
  case updateAlreadyRunning(String)
  case validation(String)

  public var description: String {
    switch self {
    case .checksum(let message):
      return message
    case .command(let message):
      return message
    case .filesystem(let message):
      return message
    case .http(let message):
      return message
    case .release(let message):
      return message
    case .updateAlreadyRunning(let message):
      return message
    case .validation(let message):
      return message
    }
  }
}

// MARK: - UpdateConfig

public struct UpdateConfig: Equatable {
  public static let defaultAPIBaseURL = "https://api.github.com"
  public static let defaultIntervalSeconds: TimeInterval = 86_400
  public static let defaultInterval: TimeInterval = defaultIntervalSeconds
  private static let allowedRepoCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
  private static let repoComponentCount = 2

  public let repo: String
  public let binary: String
  public let assetName: String
  public let teamID: String
  public let currentVersion: String
  public let allowPrerelease: Bool
  public let validateArgs: [String]
  public let validateMatch: String
  public let interval: TimeInterval
  public let apiBaseURL: URL?
  public let authToken: String?

  public init(
    repo: String,
    binary: String,
    teamID: String,
    currentVersion: String,
    assetName: String? = nil,
    allowPrerelease: Bool = true,
    validateArgs: [String] = ["version"],
    validateMatch: String = "version:",
    interval: TimeInterval = UpdateConfig.defaultInterval,
    apiBaseURL: URL? = URL(string: UpdateConfig.defaultAPIBaseURL),
    authToken: String? = nil
  ) {
    self.repo = repo
    self.binary = binary
    self.assetName = assetName ?? "\(binary)_darwin_arm64.dmg"
    self.teamID = teamID
    self.currentVersion = currentVersion
    self.allowPrerelease = allowPrerelease
    self.validateArgs = validateArgs
    self.validateMatch = validateMatch
    self.interval = interval
    self.apiBaseURL = apiBaseURL
    self.authToken = authToken
  }

  // requireTeamID defaults to true so the apply path keeps demanding a team id.
  // verify-release passes false when it will not check the signature, so a
  // library or API caller does not have to invent a placeholder team id just to
  // pass validation for a check that is skipped.
  public func validate(requireTeamID: Bool = true) throws {
    try validateRepo()
    if binary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw UpdateError.validation("update binary is required")
    }
    if assetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw UpdateError.validation("update asset name is required")
    }
    // The asset name is joined onto the cache dir to build the download path, so
    // reject anything but a bare file name to prevent path traversal.
    if assetName != (assetName as NSString).lastPathComponent || assetName == ".." {
      throw UpdateError.validation("update asset name must be a bare file name")
    }
    if requireTeamID, teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw UpdateError.validation("update team ID is required")
    }
    if currentVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw UpdateError.validation("current version is required")
    }
    if validateArgs.isEmpty {
      throw UpdateError.validation("validate args are required")
    }
    if validateMatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw UpdateError.validation("validate match is required")
    }
    if interval <= 0 {
      throw UpdateError.validation("update interval must be positive")
    }
    // authToken is sent as an Authorization: Bearer header, so require https to
    // avoid leaking it in plaintext over a caller-supplied base URL.
    if let apiBaseURL, apiBaseURL.scheme?.lowercased() != "https" {
      throw UpdateError.validation("update API base URL must use https")
    }
  }

  /// repo is interpolated into the release API URL, so require a strict
  /// owner/name using GitHub's identifier charset. This blocks a query,
  /// fragment, or extra path segment from altering the request target.
  private func validateRepo() throws {
    if repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw UpdateError.validation("update repo is required")
    }
    let repoParts = repo.split(separator: "/", omittingEmptySubsequences: false)
    let repoIsValid =
      repoParts.count == Self.repoComponentCount
      && !repoParts[0].isEmpty && !repoParts[1].isEmpty
      && repoParts.allSatisfy { part in
        part.unicodeScalars.allSatisfy { Self.allowedRepoCharacters.contains($0) }
      }
    if !repoIsValid {
      throw UpdateError.validation("update repo must be owner/name")
    }
  }
}
