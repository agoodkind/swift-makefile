//
//  CachePlan.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-24.
//  Copyright © 2026, all rights reserved.
//
//  The CI cache plan: which caches are enabled for a profile, and the keys that
//  namespace them. This is the engine-owned port of the former cache-plan.sh, so
//  the cache keys live in one place (Swift), unit-tested, instead of duplicated
//  in a shell script.
//

import Foundation

// MARK: - CachePlan

public enum CachePlan {
  public enum PlanError: Error, CustomStringConvertible {
    case unknownProfile(String)

    public var description: String {
      switch self {
      case .unknownProfile(let value):
        return "unknown cache-profile \(value)"
      }
    }
  }

  /// The raw inputs to a cache plan. Version probes (xcode/swift) and the weekly
  /// epoch are passed in rather than read here, so the computation is pure and
  /// fully testable.
  public struct Inputs {
    public var profile: String
    public var version: String
    public var dependencyHash: String
    public var buildHash: String
    public var runnerOS: String
    public var runnerArch: String
    public var xcodeVersion: String
    public var swiftVersion: String
    public var weeklyEpoch: String
    /// The gate writing the compile cache (the make target / CI gate name). It scopes
    /// the rolling compile key, so each gate keeps its own pile and a gate that
    /// compiles one configuration never overwrites a gate that compiles another.
    public var compileWriter: String
    /// A value unique to this run attempt, appended to the compile key so every save
    /// lands under a fresh name (the cache action only saves when the exact key is
    /// new), which is what lets the pile roll forward instead of freezing.
    public var compileRunUnique: String
    /// Whether this gate actually compiles. Only a compiling gate restores and saves
    /// the compile cache, so a lint gate cannot freeze an empty pile.
    public var isCompileWriter: Bool

    public init(
      profile: String,
      version: String,
      dependencyHash: String,
      buildHash: String,
      runnerOS: String,
      runnerArch: String,
      xcodeVersion: String,
      swiftVersion: String,
      weeklyEpoch: String,
      compileWriter: String = "",
      compileRunUnique: String = "",
      isCompileWriter: Bool = false
    ) {
      self.profile = profile
      self.version = version
      self.dependencyHash = dependencyHash
      self.buildHash = buildHash
      self.runnerOS = runnerOS
      self.runnerArch = runnerArch
      self.xcodeVersion = xcodeVersion
      self.swiftVersion = swiftVersion
      self.weeklyEpoch = weeklyEpoch
      self.compileWriter = compileWriter
      self.compileRunUnique = compileRunUnique
      self.isCompileWriter = isCompileWriter
    }
  }

  public struct Result: Equatable {
    public var dependencyCacheEnabled: Bool
    public var buildCacheEnabled: Bool
    public var compileCacheEnabled: Bool
    public var dependencyKey: String
    public var dependencyRestoreKeys: [String]
    public var buildKey: String
    public var buildRestoreKeys: [String]
    public var compileKey: String
    public var compileRestoreKeys: [String]
  }

  private static let allowedKeyCharacters: Set<Character> = Set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")

  /// Sanitize one key segment the way `tr -cs '[:alnum:]_.-' '-'` does: every run
  /// of characters outside `[A-Za-z0-9_.-]` collapses to a single `-`, and runs of
  /// `-` (including ones already present) collapse too. Leading and trailing `-`
  /// are kept, matching `tr`.
  public static func sanitizeKeyPart(_ raw: String) -> String {
    var result = ""
    var lastWasDash = false
    for character in raw {
      let mapped: Character = allowedKeyCharacters.contains(character) ? character : "-"
      if mapped == "-" {
        if lastWasDash {
          continue
        }
        lastWasDash = true
      } else {
        lastWasDash = false
      }
      result.append(mapped)
    }
    return result
  }

  /// Compute the cache plan: the enabled flags for the profile, and the dependency
  /// and build keys. Throws `PlanError.unknownProfile` for an unrecognized profile,
  /// matching cache-plan.sh's exit-2 behavior.
  public static func compute(_ inputs: Inputs) throws -> Result {
    let profile = inputs.profile.lowercased()
    let dependencyEnabled: Bool
    let buildEnabled: Bool
    switch profile {
    case "safe":
      dependencyEnabled = true
      buildEnabled = true
    case "dependencies", "dependency", "deps":
      dependencyEnabled = true
      buildEnabled = false
    case "off", "none", "false", "0":
      dependencyEnabled = false
      buildEnabled = false
    default:
      throw PlanError.unknownProfile(profile)
    }

    var version = sanitizeKeyPart(inputs.version.isEmpty ? "v1" : inputs.version)
    if version.isEmpty {
      version = "v1"
    }
    let dependencyHash = inputs.dependencyHash.isEmpty ? "no-dependencies" : inputs.dependencyHash
    let buildHash = inputs.buildHash.isEmpty ? "no-build-config" : inputs.buildHash
    let runnerOS = sanitizeKeyPart(inputs.runnerOS)
    let runnerArch = sanitizeKeyPart(inputs.runnerArch)
    let xcode = sanitizeKeyPart(inputs.xcodeVersion)
    let swift = sanitizeKeyPart(inputs.swiftVersion)

    let prefix = "\(runnerOS)-\(runnerArch)-swift-mk-\(version)-\(xcode)-\(swift)"

    // The compile cache rolls: it participates only on a compiling gate, and only when
    // any caching is on (the same profiles that restore the cross-commit dependency
    // bucket). A lint gate never touches it, so it cannot freeze an empty pile.
    let compileEnabled = dependencyEnabled && inputs.isCompileWriter
    let writer = sanitizeKeyPart(inputs.compileWriter.isEmpty ? "gate" : inputs.compileWriter)
    let runUnique = sanitizeKeyPart(inputs.compileRunUnique.isEmpty ? "0" : inputs.compileRunUnique)
    // The weekly epoch caps the rolling history: within a week the family is stable so
    // the pile rolls forward, and each new week starts a fresh family so last week's
    // piles fall out of the restore prefix and age out under GitHub's expiry, rather
    // than one fresh entry per run accumulating forever against the cache quota.
    let compileFamily = "\(prefix)-compile-\(inputs.weeklyEpoch)-deps-\(dependencyHash)"

    return Result(
      dependencyCacheEnabled: dependencyEnabled,
      buildCacheEnabled: buildEnabled,
      compileCacheEnabled: compileEnabled,
      dependencyKey: "\(prefix)-deps-\(dependencyHash)",
      dependencyRestoreKeys: ["\(prefix)-deps-"],
      buildKey: "\(prefix)-build-\(inputs.weeklyEpoch)-deps-\(dependencyHash)-build-\(buildHash)",
      // Deliberately empty: a fallback restore can mix incompatible compiled
      // module maps across different dependency or build hashes.
      buildRestoreKeys: [],
      // The unique run value makes every save land under a fresh name, so the pile
      // rolls forward. Restore prefers this gate's own latest pile, then falls back to
      // any sibling gate's pile for the same dependencies (content-addressing keeps only
      // the matching entries, so a mismatched sibling pile is harmless, never wrong).
      compileKey: "\(compileFamily)-\(writer)-\(runUnique)",
      compileRestoreKeys: ["\(compileFamily)-\(writer)-", "\(compileFamily)-"])
  }
}
