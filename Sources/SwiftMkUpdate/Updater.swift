//
//  Updater.swift
//  SwiftMkUpdate
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-02.
//  Copyright © 2026, all rights reserved.
//

import Darwin
import Foundation

// MARK: - CheckResult

public struct CheckResult: Equatable {
  public let currentVersion: String
  public let latestTag: String
  public let assetName: String
  public let assetURL: URL?
  public let updateAvailable: Bool

  public init(
    currentVersion: String,
    latestTag: String,
    assetName: String,
    assetURL: URL?,
    updateAvailable: Bool
  ) {
    self.currentVersion = currentVersion
    self.latestTag = latestTag
    self.assetName = assetName
    self.assetURL = assetURL
    self.updateAvailable = updateAvailable
  }
}

// MARK: - ApplyResult

public struct ApplyResult: Equatable {
  public let check: CheckResult
  public let applied: Bool
  public let dryRun: Bool
  public let result: UpdateResult

  public init(check: CheckResult, applied: Bool, dryRun: Bool, result: UpdateResult) {
    self.check = check
    self.applied = applied
    self.dryRun = dryRun
    self.result = result
  }
}

// MARK: - Updater

public final class Updater {
  private static let maxDownloadBytes = 268_435_456
  private static let maxDownloadDescription = "256MiB"
  private static let successStatusCode = 200
  private static let executablePermission = 0o755

  let options: UpdateOptions

  public init(options: UpdateOptions) {
    self.options = options
  }

  public func check() throws -> CheckResult {
    do {
      let resolved = try resolveUpdate()
      try recordUpdateResult(options: options, result: .checked, error: nil, appliedTag: nil)
      return resolved.check
    } catch {
      recordUpdateFailure(error, options: options)
      throw error
    }
  }

  public func apply() throws -> ApplyResult {
    if isDevelopmentBuild(options.config.currentVersion) {
      let check = noUpdateCheck(options: options)
      try recordUpdateResult(options: options, result: .upToDate, error: nil, appliedTag: nil)
      return ApplyResult(check: check, applied: false, dryRun: options.dryRun, result: .upToDate)
    }
    do {
      return try withUpdateLock(statePath: options.statePath) {
        let resolved = try resolveUpdate()
        if !resolved.check.updateAvailable {
          try recordUpdateResult(options: options, result: .upToDate, error: nil, appliedTag: nil)
          return ApplyResult(
            check: resolved.check,
            applied: false,
            dryRun: options.dryRun,
            result: .upToDate)
        }
        return try applyResolvedUpdate(resolved)
      }
    } catch {
      recordUpdateFailure(error, options: options)
      throw error
    }
  }

  private func resolveUpdate() throws -> ResolvedUpdate {
    try options.config.validate()
    options.log("update: resolving latest release")
    let release = try ReleaseResolver.latestRelease(
      config: options.config,
      httpClient: options.httpClient)
    guard let asset = selectedAsset(in: release.assets) else {
      throw UpdateError.release("release asset \(options.config.assetName) not found")
    }
    let check = CheckResult(
      currentVersion: options.config.currentVersion,
      latestTag: release.tag,
      assetName: asset.name,
      assetURL: asset.browserDownloadURL,
      updateAvailable: ReleaseResolver.isNewer(
        latest: release.tag,
        current: options.config.currentVersion))
    return ResolvedUpdate(release: release, asset: asset, check: check)
  }

  func selectedAsset(in assets: [ReleaseAsset]) -> ReleaseAsset? {
    for asset in assets where asset.name == options.config.assetName {
      return asset
    }
    return nil
  }

  private func applyResolvedUpdate(_ resolved: ResolvedUpdate) throws -> ApplyResult {
    try stageResolvedRelease(
      resolved,
      requireSignature: true
    ) { candidatePath, _ in
      if options.dryRun {
        try recordUpdateResult(options: options, result: .dryRun, error: nil, appliedTag: nil)
        return ApplyResult(
          check: resolved.check,
          applied: false,
          dryRun: true,
          result: .dryRun)
      }
      try replaceBinary(candidatePath: candidatePath, targetPath: options.targetPath)
      try recordUpdateResult(
        options: options,
        result: .applied,
        error: nil,
        appliedTag: resolved.release.tag)
      return ApplyResult(
        check: resolved.check,
        applied: true,
        dryRun: false,
        result: .applied)
    }
  }

  func download(url: URL, to path: String) throws {
    UpdateDiagnostics.debug("update download \(url.absoluteString)")
    options.log("update: downloading \(url.absoluteString)")
    let (data, status) = try options.httpClient.get(
      url,
      headers: ReleaseResolver.downloadHeaders(config: options.config, url: url))
    guard status == Self.successStatusCode else {
      throw UpdateError.http("download \(url.absoluteString): HTTP \(status)")
    }
    guard data.count <= Self.maxDownloadBytes else {
      throw UpdateError.http(
        "download \(url.absoluteString) exceeds \(Self.maxDownloadDescription)")
    }
    let destinationURL = URL(fileURLWithPath: path)
    let directoryURL = destinationURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let temporaryURL = directoryURL.appendingPathComponent(
      "\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      try data.write(to: temporaryURL)
      try renameFile(from: temporaryURL.path, to: path, context: "replace update download")
    } catch let error as UpdateError {
      throw error
    } catch {
      removeTemporaryItem(at: temporaryURL, context: "download")
      throw UpdateError.filesystem("write update download \(path): \(error)")
    }
  }

  func verifyChecksum(
    asset: ReleaseAsset,
    release: Release,
    archivePath: String
  ) throws {
    options.log("update: verifying checksum")
    let expected = try expectedChecksum(asset: asset, release: release)
    let output = try runRequired("shasum", ["-a", "256", archivePath], context: "hash dmg")
    guard let actual = output.stdout.split(whereSeparator: \.isWhitespace).first else {
      throw UpdateError.checksum("checksum output was empty")
    }
    guard String(actual).caseInsensitiveCompare(expected) == .orderedSame else {
      throw UpdateError.checksum(
        "checksum mismatch for \(asset.name): expected \(expected), got \(actual)")
    }
  }

  private func expectedChecksum(asset: ReleaseAsset, release: Release) throws -> String {
    UpdateDiagnostics.debug("update checksum \(asset.name)")
    if let digest = asset.digest, digest.hasPrefix("sha256:") {
      return String(digest.dropFirst("sha256:".count))
    }
    guard let checksumsAsset = release.assets.first(where: { $0.name == "checksums.txt" }) else {
      throw UpdateError.checksum("checksum unavailable for \(asset.name)")
    }
    let (data, status) = try options.httpClient.get(
      checksumsAsset.browserDownloadURL,
      headers: ReleaseResolver.downloadHeaders(
        config: options.config, url: checksumsAsset.browserDownloadURL))
    guard status == Self.successStatusCode else {
      throw UpdateError.http("download checksums.txt: HTTP \(status)")
    }
    guard let text = String(data: data, encoding: .utf8),
      let expected = ReleaseResolver.expectedSHA256(checksumsText: text, assetName: asset.name)
    else {
      throw UpdateError.checksum("checksum entry not found for \(asset.name)")
    }
    return expected
  }

  func mountedVerifiedCandidate<ResultValue>(
    archivePath: String,
    releaseTag: String,
    requireSignature: Bool,
    run: (_ candidatePath: String, _ validation: CommandOutput) throws -> ResultValue
  ) throws -> ResultValue {
    UpdateDiagnostics.debug("update mount \(archivePath)")
    let mountURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(options.config.binary)-update-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
    var attached = false
    defer {
      detachMountIfNeeded(attached: attached, mountURL: mountURL, options: options)
      removeTemporaryItem(at: mountURL, context: "mount")
    }
    if requireSignature {
      try verifyArchiveStaple(archivePath: archivePath)
    }
    try runRequired(
      "hdiutil",
      ["attach", "-nobrowse", "-readonly", "-mountpoint", mountURL.path, archivePath],
      context: "mount dmg")
    attached = true
    let candidatePath = try findCandidate(in: mountURL)
    // Always run a basic codesign validity check before executing the candidate,
    // so a tampered or unsigned binary is never launched. The staple and the
    // Developer ID team-identifier pin are the stricter checks gated on
    // requireSignature.
    try verifyCandidateCodesign(candidatePath: candidatePath)
    if requireSignature {
      try verifyCandidateTeamIdentifier(candidatePath: candidatePath)
    } else {
      options.log("update: skipping staple and team-identifier verification")
    }
    let validation = try validateCandidateVersion(
      candidatePath: candidatePath,
      releaseTag: releaseTag)
    return try run(candidatePath, validation)
  }

  private func verifyArchiveStaple(archivePath: String) throws {
    try runRequired(
      "xcrun",
      ["stapler", "validate", archivePath],
      context: "validate dmg staple")
  }

  private func verifyCandidateCodesign(candidatePath: String) throws {
    UpdateDiagnostics.debug("update verify candidate \(candidatePath)")
    options.log("update: verifying candidate code signature")
    try runRequired(
      "codesign",
      ["--verify", "--strict", "--verbose=2", candidatePath],
      context: "verify candidate codesign")
  }

  private func verifyCandidateTeamIdentifier(candidatePath: String) throws {
    let details = try runRequired(
      "codesign",
      ["-dvv", candidatePath],
      context: "read candidate team")
    let teamID = ReleaseResolver.codesignTeamIdentifier(output: details.stdout + details.stderr)
    guard teamID == options.config.teamID else {
      throw UpdateError.command(
        "candidate team identifier mismatch: expected \(options.config.teamID), "
          + "got \(teamID ?? "<none>")"
      )
    }
  }

  private func validateCandidateVersion(
    candidatePath: String,
    releaseTag: String
  ) throws -> CommandOutput {
    options.log("update: running candidate validation")
    UpdateDiagnostics.debug("update command \(candidatePath)")
    let validation = options.commandRunner.run(candidatePath, options.config.validateArgs)
    guard validation.status == 0 else {
      throw UpdateError.command(
        "candidate validation failed: \(validation.stderr)\(validation.stdout)")
    }
    guard validation.stdout.contains(options.config.validateMatch),
      validation.stdout.contains(releaseTag)
    else {
      throw UpdateError.command("candidate validation output did not include \(releaseTag)")
    }
    return validation
  }

  @discardableResult
  private func runRequired(
    _ tool: String,
    _ args: [String],
    context: String
  ) throws -> CommandOutput {
    UpdateDiagnostics.debug("update command \(tool)")
    let result = options.commandRunner.run(tool, args)
    if result.status != 0 {
      throw UpdateError.command(
        "\(context): \(tool) \(args.joined(separator: " ")) failed: "
          + "\(result.stderr)\(result.stdout)")
    }
    return result
  }

  private func findCandidate(in mountURL: URL) throws -> String {
    let directURL = mountURL.appendingPathComponent(options.config.binary)
    if FileManager.default.fileExists(atPath: directURL.path) {
      return directURL.path
    }
    guard
      let enumerator = FileManager.default.enumerator(at: mountURL, includingPropertiesForKeys: nil)
    else {
      throw UpdateError.filesystem("cannot enumerate mounted dmg")
    }
    for case let url as URL in enumerator where url.lastPathComponent == options.config.binary {
      return url.path
    }
    throw UpdateError.filesystem("mounted dmg did not contain \(options.config.binary)")
  }

  private func replaceBinary(candidatePath: String, targetPath: String) throws {
    UpdateDiagnostics.debug("update replace \(targetPath)")
    options.log("update: replacing \(targetPath)")
    if targetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw UpdateError.filesystem("target path is required")
    }
    let targetURL = URL(fileURLWithPath: targetPath)
    let temporaryURL = targetURL.deletingLastPathComponent()
      .appendingPathComponent(".\(targetURL.lastPathComponent)-update-\(UUID().uuidString)")
    do {
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: candidatePath),
        to: temporaryURL)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Self.executablePermission)],
        ofItemAtPath: temporaryURL.path)
      try renameFile(from: temporaryURL.path, to: targetPath, context: "replace installed binary")
    } catch let error as UpdateError {
      throw error
    } catch {
      removeTemporaryItem(at: temporaryURL, context: "replace")
      throw UpdateError.filesystem("replace installed binary: \(error)")
    }
  }

}

// MARK: - Updater state helpers

private func recordUpdateResult(
  options: UpdateOptions,
  result: UpdateResult,
  error: String?,
  appliedTag: String?
) throws {
  // Serialize the read-modify-write of the state file through its own lock so a
  // concurrent check or failure record cannot clobber a just-applied tag. This
  // lock is distinct from the update single-flight lock, so apply() (which holds
  // that lock) can still record its result.
  try withStateLock(statePath: options.statePath) {
    let previous = previousStateForRecord(options: options)
    let tag = appliedTag ?? previous?.lastAppliedTag
    try saveState(
      UpdateState(
        lastCheck: options.now(),
        lastResult: result,
        lastError: error,
        lastAppliedTag: tag),
      path: options.statePath)
  }
}

private func previousStateForRecord(options: UpdateOptions) -> UpdateState? {
  do {
    return try loadState(path: options.statePath)
  } catch {
    UpdateDiagnostics.warning("update state load before record failed: \(error)")
    return nil
  }
}

private func recordUpdateFailure(_ failure: Error, options: UpdateOptions) {
  do {
    try recordUpdateResult(options: options, result: .error, error: "\(failure)", appliedTag: nil)
  } catch {
    UpdateDiagnostics.error("update failure record failed: \(error)")
  }
}

private func detachMountIfNeeded(attached: Bool, mountURL: URL, options: UpdateOptions) {
  if attached {
    let output = options.commandRunner.run("hdiutil", ["detach", mountURL.path])
    if output.status != 0 {
      UpdateDiagnostics.warning(
        "update detach \(mountURL.path) failed: \(output.stderr)\(output.stdout)")
    }
  }
}

private func removeTemporaryItem(at url: URL, context: String) {
  do {
    try FileManager.default.removeItem(at: url)
  } catch {
    UpdateDiagnostics.warning("update cleanup \(context) failed: \(error)")
  }
}

private func noUpdateCheck(options: UpdateOptions) -> CheckResult {
  CheckResult(
    currentVersion: options.config.currentVersion,
    latestTag: "",
    assetName: options.config.assetName,
    assetURL: nil,
    updateAvailable: false)
}

// MARK: - ResolvedUpdate

struct ResolvedUpdate {
  let release: Release
  let asset: ReleaseAsset
  let check: CheckResult
}

// MARK: - Update helpers

private func isDevelopmentBuild(_ version: String) -> Bool {
  ReleaseResolver.isDevelopmentVersion(version)
}

private func withUpdateLock<ResultValue>(
  statePath: String,
  run: () throws -> ResultValue
) throws -> ResultValue {
  UpdateDiagnostics.debug("update lock \(statePath)")
  let stateURL = URL(fileURLWithPath: statePath)
  let lockURL = stateURL.deletingLastPathComponent().appendingPathComponent(".update.lock")
  try FileManager.default.createDirectory(
    at: lockURL.deletingLastPathComponent(),
    withIntermediateDirectories: true)
  let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
  if fd < 0 {
    throw UpdateError.filesystem(
      "open update lock: \(String(cString: strerror(errno)))")
  }
  defer { Darwin.close(fd) }
  if flock(fd, LOCK_EX | LOCK_NB) != 0 {
    // Only a contended lock means another update is running; any other errno
    // (permissions, IO) is a real failure and must not be masked as such.
    let lockErrno = errno
    if lockErrno == EWOULDBLOCK {
      throw UpdateError.updateAlreadyRunning("update already running")
    }
    throw UpdateError.filesystem(
      "lock update state: \(String(cString: strerror(lockErrno)))")
  }
  defer { flock(fd, LOCK_UN) }
  return try run()
}

private func withStateLock<ResultValue>(
  statePath: String,
  run: () throws -> ResultValue
) throws -> ResultValue {
  UpdateDiagnostics.debug("update state lock \(statePath)")
  let stateURL = URL(fileURLWithPath: statePath)
  let lockURL = stateURL.deletingLastPathComponent().appendingPathComponent(".state.lock")
  try FileManager.default.createDirectory(
    at: lockURL.deletingLastPathComponent(),
    withIntermediateDirectories: true)
  let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
  if fd < 0 {
    throw UpdateError.filesystem(
      "open state lock: \(String(cString: strerror(errno)))")
  }
  defer { Darwin.close(fd) }
  // Blocking exclusive lock: state writes are brief, so wait rather than fail.
  if flock(fd, LOCK_EX) != 0 {
    throw UpdateError.filesystem(
      "lock update state: \(String(cString: strerror(errno)))")
  }
  defer { flock(fd, LOCK_UN) }
  return try run()
}
