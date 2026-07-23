//
//  VersionMeta.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//
//  The one place the version scheme lives. A release build's version arrives as
//  MARKETING_VERSION / CURRENT_PROJECT_VERSION in the environment and passes
//  through unchanged. A CI run without those (the release meta job) computes the
//  release scheme: calendar short version yy.m.d and a <timestamp><run-number>
//  build number. A local build computes a dev version marked as such so it is
//  never mistaken for a shipped build. The build chokepoint injects the resolved
//  MARKETING_VERSION / CURRENT_PROJECT_VERSION, and `swift-mk version-meta` prints
//  the same triple for the release workflow, so both paths share one scheme.
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
  static func compute(_ inputs: Inputs) throws -> Version {
    let tag = resolveTag(inputs)
    if !inputs.marketingEnv.isEmpty, !inputs.buildEnv.isEmpty {
      try assertBuildLength(inputs.buildEnv)
      return Version(marketing: inputs.marketingEnv, build: inputs.buildEnv, tag: tag)
    }
    if !inputs.githubRunNumber.isEmpty {
      let build = inputs.timestamp + inputs.githubRunNumber
      try assertBuildLength(build)
      return Version(marketing: inputs.calendar, build: build, tag: tag)
    }
    try assertBuildLength(inputs.timestamp)
    let marketing =
      inputs.shortSHA.isEmpty
      ? "\(inputs.calendar)-dev"
      : "\(inputs.calendar)+\(inputs.shortSHA)-dev"
    return Version(marketing: marketing, build: inputs.timestamp, tag: tag)
  }

  /// The release tag: the pushed tag name on a tag ref, else `<timestamp>-<hex run
  /// number>-<sha>` in CI, else a dev tag for a local build.
  static func resolveTag(_ inputs: Inputs) -> String {
    if inputs.githubRefType == "tag", !inputs.githubRefName.isEmpty {
      return inputs.githubRefName
    }
    if !inputs.githubRunNumber.isEmpty {
      let runNumber = UInt64(inputs.githubRunNumber) ?? 0
      let runHex = String(runNumber, radix: 16)
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

  // MARK: Environment resolution

  /// Resolve the version from the live environment, the UTC clock, and git.
  public static func resolve() throws -> Version {
    let now = Date()
    let components = utcComponents(from: now)
    let inputs = Inputs(
      marketingEnv: Env.get("MARKETING_VERSION"),
      buildEnv: Env.get("CURRENT_PROJECT_VERSION"),
      githubRefType: Env.get("GITHUB_REF_TYPE"),
      githubRefName: Env.get("GITHUB_REF_NAME"),
      githubRunNumber: Env.get("GITHUB_RUN_NUMBER"),
      timestamp: timestamp(from: components),
      calendar: calendarVersion(from: components),
      shortSHA: shortSHA())
    return try compute(inputs)
  }

  /// The two build settings the chokepoint injects into a product build. Returns an
  /// empty dictionary when resolution fails, so a version problem never blocks a
  /// build; the failure surfaces at `version-meta` (the release path) instead.
  public static func buildSettings() -> [String: String] {
    guard let version = try? resolve() else {
      return [:]
    }
    return [
      "MARKETING_VERSION": version.marketing,
      "CURRENT_PROJECT_VERSION": version.build,
    ]
  }

  // MARK: Clock and git

  private static func utcComponents(from date: Date) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
    return calendar.dateComponents(
      [.year, .month, .day, .hour, .minute], from: date)
  }

  private static func timestamp(from components: DateComponents) -> String {
    String(
      format: "%04d%02d%02d%02d%02d",
      components.year ?? 0, components.month ?? 0, components.day ?? 0,
      components.hour ?? 0, components.minute ?? 0)
  }

  private static func calendarVersion(from components: DateComponents) -> String {
    let year = String(format: "%02d", (components.year ?? 0) % 100)
    let month = String(components.month ?? 0)
    let day = String(components.day ?? 0)
    return "\(year).\(month).\(day)"
  }

  private static func shortSHA() -> String {
    let result = Shell.run("git", ["rev-parse", "--short", "HEAD"])
    guard result.status == 0 else {
      return ""
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
