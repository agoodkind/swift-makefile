//
//  VerifyReleaseResult.swift
//  SwiftMkUpdate
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - VerifyReleaseResult

public struct VerifyReleaseResult: Equatable {
  public let tag: String
  public let assetName: String
  public let assetURL: URL
  public let requireSignature: Bool
  public let validationOutput: String

  public init(
    tag: String,
    assetName: String,
    assetURL: URL,
    requireSignature: Bool,
    validationOutput: String
  ) {
    self.tag = tag
    self.assetName = assetName
    self.assetURL = assetURL
    self.requireSignature = requireSignature
    self.validationOutput = validationOutput
  }
}

// MARK: - Release verification

extension Updater {
  public func verifyRelease(tag: String, requireSignature: Bool) throws -> VerifyReleaseResult {
    let resolved = try resolveRelease(tag: tag, requireSignature: requireSignature)
    return try verifyResolvedRelease(resolved, requireSignature: requireSignature)
  }

  func stageResolvedRelease<ResultValue>(
    _ resolved: ResolvedUpdate,
    requireSignature: Bool,
    run: (_ candidatePath: String, _ validation: CommandOutput) throws -> ResultValue
  ) throws -> ResultValue {
    try FileManager.default.createDirectory(
      atPath: options.cacheDir, withIntermediateDirectories: true)
    let archivePath = URL(fileURLWithPath: options.cacheDir, isDirectory: true)
      .appendingPathComponent(resolved.asset.name)
      .path
    try download(url: resolved.asset.browserDownloadURL, to: archivePath)
    try verifyChecksum(asset: resolved.asset, release: resolved.release, archivePath: archivePath)
    return try mountedVerifiedCandidate(
      archivePath: archivePath,
      releaseTag: resolved.release.tag,
      requireSignature: requireSignature,
      run: run)
  }

  private func resolveRelease(tag: String, requireSignature: Bool) throws -> ResolvedUpdate {
    // Only require a team id when the signature (and thus the team-id check) will
    // actually run, so verify-release without a signature does not force a
    // placeholder team id past validation.
    try options.config.validate(requireTeamID: requireSignature)
    let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedTag.isEmpty {
      throw UpdateError.validation("release tag is required")
    }
    options.log("update: resolving release \(trimmedTag)")
    let release = try ReleaseResolver.release(
      config: options.config,
      httpClient: options.httpClient,
      tag: trimmedTag,
      requireTeamID: requireSignature)
    if release.tag != trimmedTag {
      throw UpdateError.release("release tag mismatch: expected \(trimmedTag), got \(release.tag)")
    }
    guard let asset = selectedAsset(in: release.assets) else {
      throw UpdateError.release("release asset \(options.config.assetName) not found")
    }
    let check = CheckResult(
      currentVersion: options.config.currentVersion,
      latestTag: release.tag,
      assetName: asset.name,
      assetURL: asset.browserDownloadURL,
      updateAvailable: false)
    return ResolvedUpdate(release: release, asset: asset, check: check)
  }

  private func verifyResolvedRelease(
    _ resolved: ResolvedUpdate,
    requireSignature: Bool
  ) throws -> VerifyReleaseResult {
    // Take the same single-flight update lock apply() uses, so a concurrent
    // apply() and verify-release cannot race on the shared cache archive path.
    try withUpdateLock(statePath: options.statePath) {
      try stageResolvedRelease(
        resolved,
        requireSignature: requireSignature
      ) { _, validation in
        VerifyReleaseResult(
          tag: resolved.release.tag,
          assetName: resolved.asset.name,
          assetURL: resolved.asset.browserDownloadURL,
          requireSignature: requireSignature,
          validationOutput: validation.stdout)
      }
    }
  }
}
