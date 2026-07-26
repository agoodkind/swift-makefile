//
//  VersionMeta.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//
//  The one place the version scheme lives. A release build's version arrives in
//  the environment as the marketing and build variables and passes through
//  unchanged. A CI run without them (the release meta job) computes the release
//  scheme: calendar short version yy.m.d and a <timestamp><run-number> build
//  number. A local build computes a dev version marked as such so it is never
//  mistaken for a shipped build. The build chokepoint injects the resolved version
//  settings, and `swift-mk version-meta` prints the same triple for the release
//  workflow, so both paths share one scheme.
//

import Foundation

// MARK: - VersionMeta

public enum VersionMeta {
  public enum ReleaseTrack: String, Sendable, Equatable {
    case prerelease
    case stable
  }

  /// A resolved version: the marketing (short) string, the build number, and the
  /// release tag.
  public struct Version: Sendable, Equatable {
    public let marketing: String
    public let build: String
    public let tag: String
    public let artifact: String
    public let track: ReleaseTrack?

    public init(
      marketing: String,
      build: String,
      tag: String,
      artifact: String? = nil,
      track: ReleaseTrack? = nil
    ) {
      self.marketing = marketing
      self.build = build
      self.tag = tag
      self.artifact = artifact ?? artifactVersion(for: tag)
      self.track = track
    }
  }

  /// `CFBundleVersion` accepts at most 18 characters, so a build number past that
  /// would fail the build at packaging time; fail loud here instead.
  static let buildVersionMaxLength = 18

  /// Base for the run-number hex in the tag, matching `printf '%x'` in the shell
  /// release-meta.
  static let tagHexRadix = 16

  /// GitHub run numbers are encoded into the final six build-number digits.
  static let releaseRunNumberMaxDigits = 6

  /// A release run number must be positive because zero is reserved for absence.
  static let minimumReleaseRunNumber = 1

  /// The xcodebuild build-setting keys the chokepoint injects, uppercased. The
  /// stamp resolves the version only when at least one of these is missing from a
  /// request, so a build that already carries both never triggers resolution.
  public static let injectableKeys = ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION"]

  // MARK: Errors

  public enum VersionError: Error, CustomStringConvertible {
    case buildVersionTooLong(String)
    case invalidReleaseRunNumber(String)
    case invalidReleaseTag(String)
    case invalidSourceSelection(String)

    public var description: String {
      switch self {
      case .buildVersionTooLong(let value):
        return
          "version-meta: build_version \(value) exceeds CFBundleVersion's "
          + "\(VersionMeta.buildVersionMaxLength) characters"
      case .invalidReleaseRunNumber(let value):
        return
          "version-meta: release run number \(value) must be a nonzero decimal "
          + "value up to six digits"
      case .invalidReleaseTag(let value):
        return "version-meta: invalid release tag \(value)"
      case .invalidSourceSelection(let reason):
        return "version-meta: invalid release source selection: \(reason)"
      }
    }
  }

  // MARK: Inputs

  /// Everything `compute` needs, gathered so the computation is pure and testable
  /// without touching the clock, git, or the environment.
  struct Inputs: Sendable {
    let marketingEnv: String
    let buildEnv: String
    let githubRefType: String
    let githubRefName: String
    let githubRunNumber: String
    /// UTC `YYYYMMDDHHMM`.
    let timestamp: String
    /// Calendar short version `yy.m.d` (two-digit year, month and day without
    /// leading zeros).
    let calendar: String
    /// Short git sha, or empty when git is unavailable.
    let shortSHA: String
    let releaseTrack: ReleaseTrack?
    let releaseTag: String
  }

  // MARK: Pure computation

  /// Resolve the version from gathered inputs. Precedence:
  ///
  /// 1. An explicit `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the
  ///    environment win (the release build step already decided them).
  /// 2. Otherwise a CI run (a run number is present) computes the release scheme.
  /// 3. Otherwise a local build computes the dev scheme.
  /// Compute the version without enforcing the build-number cap, so a caller that
  /// needs only the marketing value is not coupled to a build number it will not
  /// use. `compute` wraps this and enforces the cap for the authoritative path.
  static func computed(_ inputs: Inputs) -> Version {
    let tag = resolveTag(inputs)
    if !inputs.marketingEnv.isEmpty, !inputs.buildEnv.isEmpty {
      return Version(
        marketing: inputs.marketingEnv,
        build: inputs.buildEnv,
        tag: tag,
        track: inputs.releaseTrack)
    }
    if let releaseTrack = inputs.releaseTrack {
      let build = fixedWidthBuildVersion(inputs.timestamp, runNumber: inputs.githubRunNumber)
      let marketing: String
      if releaseTrack == .stable {
        marketing = stableMarketingVersion(for: tag)
      } else {
        marketing = inputs.calendar
      }
      return Version(
        marketing: marketing, build: build, tag: tag, track: releaseTrack)
    }
    if isPositiveInteger(inputs.githubRunNumber) {
      return Version(
        marketing: inputs.calendar, build: inputs.timestamp + inputs.githubRunNumber, tag: tag)
    }
    let marketing =
      inputs.shortSHA.isEmpty
      ? "\(inputs.calendar)-dev"
      : "\(inputs.calendar)+\(inputs.shortSHA)-dev"
    return Version(marketing: marketing, build: inputs.timestamp, tag: tag)
  }

  /// Compute the version and enforce the 18-character build-number cap, the
  /// authoritative path `version-meta` prints and the release relies on.
  static func compute(_ inputs: Inputs) throws -> Version {
    if inputs.releaseTrack != nil {
      try assertReleaseRunNumber(inputs.githubRunNumber)
      try assertReleaseTag(resolveTag(inputs), track: inputs.releaseTrack)
    }
    let version = computed(inputs)
    try assertBuildLength(version.build)
    if version.track != nil {
      try assertFixedWidthBuildVersion(version.build)
    }
    return version
  }

  /// The release tag: the pushed tag name on a tag ref, else `<timestamp>-<hex run
  /// number>-<sha>` in CI, else a dev tag for a local build.
  static func resolveTag(_ inputs: Inputs) -> String {
    if !inputs.releaseTag.isEmpty {
      return inputs.releaseTag
    }
    if inputs.releaseTrack == .prerelease {
      return "\(inputs.calendar)-pre.\(inputs.timestamp)+\(inputs.shortSHA)"
    }
    if inputs.releaseTrack == .stable {
      return inputs.calendar
    }
    if inputs.githubRefType == "tag", !inputs.githubRefName.isEmpty {
      return inputs.githubRefName
    }
    if let runNumber = UInt64(inputs.githubRunNumber) {
      let runHex = String(runNumber, radix: tagHexRadix)
      return "\(inputs.timestamp)-\(runHex)-\(inputs.shortSHA)"
    }
    if inputs.shortSHA.isEmpty {
      return "\(inputs.timestamp)-dev"
    }
    return "\(inputs.timestamp)-\(inputs.shortSHA)-dev"
  }

  static func assertBuildLength(_ build: String) throws {
    if build.count > buildVersionMaxLength {
      throw VersionError.buildVersionTooLong(build)
    }
  }

  static func fixedWidthBuildVersion(_ timestamp: String, runNumber: String) -> String {
    let parsedRunNumber = UInt64(runNumber) ?? 0
    return timestamp + String(format: "%06llu", parsedRunNumber)
  }

  static func assertReleaseRunNumber(_ runNumber: String) throws {
    guard let parsedRunNumber = UInt64(runNumber),
      parsedRunNumber >= minimumReleaseRunNumber,
      runNumber.count <= releaseRunNumberMaxDigits
    else {
      throw VersionError.invalidReleaseRunNumber(runNumber)
    }
  }

  static func assertFixedWidthBuildVersion(_ build: String) throws {
    let fixedWidthBuildPattern = "^[0-9]{18}$"
    if build.range(of: fixedWidthBuildPattern, options: .regularExpression) == nil {
      throw VersionError.invalidReleaseTag(build)
    }
  }

  public static func isValidStableTag(_ tag: String) -> Bool {
    let stableTagPattern = "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-r[1-9][0-9]*)?$"
    return tag.range(of: stableTagPattern, options: .regularExpression) != nil
  }

  static func stableMarketingVersion(for tag: String) -> String {
    let revisionPattern = "-r[1-9][0-9]*$"
    guard let revisionRange = tag.range(of: revisionPattern, options: .regularExpression) else {
      return tag
    }
    return String(tag[..<revisionRange.lowerBound])
  }

  public static func isValidPrereleaseTag(_ tag: String) -> Bool {
    let prereleaseTagPattern =
      "^[0-9]+\\.[0-9]+\\.[0-9]+-pre\\.[0-9]{12}\\+[A-Za-z0-9]+$"
    return tag.range(of: prereleaseTagPattern, options: .regularExpression) != nil
  }

  public static func artifactVersion(for tag: String) -> String {
    tag.replacingOccurrences(of: "+", with: "-")
  }

  static func assertReleaseTag(_ tag: String, track: ReleaseTrack?) throws {
    guard let track else {
      return
    }
    let isValid: Bool
    switch track {
    case .prerelease:
      isValid = isValidPrereleaseTag(tag)
    case .stable:
      isValid = isValidStableTag(tag)
    }
    if !isValid {
      throw VersionError.invalidReleaseTag(tag)
    }
  }

  public static func validateSource(
    track: ReleaseTrack,
    candidateTag: String,
    sourceSHA: String,
    allowSourceSHA: Bool
  ) throws {
    let hasCandidateTag = !candidateTag.isEmpty
    let hasSourceSHA = !sourceSHA.isEmpty
    if track == .prerelease {
      if hasCandidateTag || hasSourceSHA || allowSourceSHA {
        throw VersionError.invalidSourceSelection("pre-release builds use the workflow commit")
      }
      return
    }
    if hasCandidateTag, hasSourceSHA {
      throw VersionError.invalidSourceSelection("candidate-tag and source-sha conflict")
    }
    if hasCandidateTag {
      if !isValidPrereleaseTag(candidateTag) {
        throw VersionError.invalidSourceSelection(
          "candidate-tag must use the pre-release tag format")
      }
      return
    }
    if hasSourceSHA, allowSourceSHA {
      return
    }
    if hasSourceSHA {
      throw VersionError.invalidSourceSelection("source-sha requires allow-source-sha=true")
    }
    throw VersionError.invalidSourceSelection(
      "stable builds require candidate-tag or acknowledged source-sha")
  }

  /// A run number is only usable when it parses as a base-ten unsigned integer.
  /// GitHub always sets a plain decimal `GITHUB_RUN_NUMBER`. Gating on `UInt64`
  /// parsing (not `Character.isNumber`, which accepts non-ASCII Unicode digits the
  /// tag's `UInt64` conversion then rejects) keeps the build number and the tag on
  /// the same scheme; a value that does not parse is treated as absent.
  static func isPositiveInteger(_ value: String) -> Bool {
    UInt64(value) != nil
  }

  // MARK: Environment resolution

  /// Gather the resolver inputs from the live environment, the UTC clock, and git.
  /// The two version variables are trimmed so a whitespace-only value counts as
  /// absent, matching how the chokepoint treats a blank forwarded setting; a value
  /// that is only spaces or newlines must not pass through as an explicit version.
  private static func currentInputs() -> Inputs {
    let components = utcComponents(from: Date())
    return Inputs(
      marketingEnv: Env.get("MARKETING_VERSION").trimmingCharacters(in: .whitespacesAndNewlines),
      buildEnv: Env.get("CURRENT_PROJECT_VERSION").trimmingCharacters(in: .whitespacesAndNewlines),
      githubRefType: Env.get("GITHUB_REF_TYPE"),
      githubRefName: Env.get("GITHUB_REF_NAME"),
      githubRunNumber: Env.get("GITHUB_RUN_NUMBER"),
      timestamp: timestamp(from: components),
      calendar: calendarVersion(from: components),
      shortSHA: shortSHA(),
      releaseTrack: ReleaseTrack(rawValue: Env.get("RELEASE_TRACK")),
      releaseTag: Env.get("RELEASE_TAG"))
  }

  /// Resolve the version from the live environment, enforcing the build cap. This
  /// is the authoritative path `version-meta` prints.
  public static func resolve() throws -> Version {
    try compute(currentInputs())
  }

  /// The build settings the chokepoint injects for the given missing keys. The
  /// build-number cap is enforced only when `CURRENT_PROJECT_VERSION` is actually
  /// injected, so a build that already supplies its own build number is never
  /// failed by an overlong computed one it does not use. Pure over an explicit
  /// version so tests cover every combination without the clock or environment.
  static func injectionSettings(
    forMissing missing: Set<String>, version: Version
  ) throws -> [String: String] {
    var settings: [String: String] = [:]
    if missing.contains("MARKETING_VERSION") {
      settings["MARKETING_VERSION"] = version.marketing
    }
    if missing.contains("CURRENT_PROJECT_VERSION") {
      try assertBuildLength(version.build)
      settings["CURRENT_PROJECT_VERSION"] = version.build
    }
    return settings
  }

  /// The build settings the chokepoint injects for the given missing keys, resolved
  /// from the current environment. Throws only when it must inject an overlong
  /// build number, so the build fails loudly rather than shipping an invalid one.
  public static func injectionSettings(forMissing missing: Set<String>) throws
    -> [String: String]
  {
    try injectionSettings(forMissing: missing, version: computed(currentInputs()))
  }

  // MARK: Clock and git

  private static func utcComponents(from date: Date) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    // UTC always resolves; keep the default zone as a non-force-unwrapped fallback.
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    return calendar.dateComponents(
      [.year, .month, .day, .hour, .minute], from: date)
  }

  private static func timestamp(from components: DateComponents) -> String {
    String(
      format: "%04d%02d%02d%02d%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0,
      components.hour ?? 0,
      components.minute ?? 0)
  }

  private static func calendarVersion(from components: DateComponents) -> String {
    let year = String(format: "%02d", (components.year ?? 0) % 100)
    let month = String(components.month ?? 0)
    let day = String(components.day ?? 0)
    return "\(year).\(month).\(day)"
  }

  private static func shortSHA() -> String {
    Output.debug("version-meta: reading git short sha")
    let result = Shell.run("git", ["rev-parse", "--short", "HEAD"])
    guard result.status == 0 else {
      return ""
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
