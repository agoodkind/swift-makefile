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
  /// A resolved version: the marketing (short) string, the build number, and the
  /// release tag.
  public struct Version: Sendable, Equatable {
    public let marketing: String
    public let build: String
    public let tag: String

    public init(marketing: String, build: String, tag: String) {
      self.marketing = marketing
      self.build = build
      self.tag = tag
    }
  }

  /// `CFBundleVersion` accepts at most 18 characters, so a build number past that
  /// would fail the build at packaging time; fail loud here instead.
  static let buildVersionMaxLength = 18

  /// Base for the run-number hex in the tag, matching `printf '%x'` in the shell
  /// release-meta.
  static let tagHexRadix = 16

  /// The xcodebuild build-setting keys the chokepoint injects, uppercased. The
  /// stamp resolves the version only when at least one of these is missing from a
  /// request, so a build that already carries both never triggers resolution.
  public static let injectableKeys = ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION"]

  // MARK: Errors

  public enum VersionError: Error, CustomStringConvertible {
    case buildVersionTooLong(String)

    public var description: String {
      switch self {
      case .buildVersionTooLong(let value):
        return
          "version-meta: build_version \(value) exceeds CFBundleVersion's "
          + "\(VersionMeta.buildVersionMaxLength) characters"
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
      return Version(marketing: inputs.marketingEnv, build: inputs.buildEnv, tag: tag)
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
    let version = computed(inputs)
    try assertBuildLength(version.build)
    return version
  }

  /// The release tag: the pushed tag name on a tag ref, else `<timestamp>-<hex run
  /// number>-<sha>` in CI, else a dev tag for a local build.
  static func resolveTag(_ inputs: Inputs) -> String {
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
      shortSHA: shortSHA())
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
