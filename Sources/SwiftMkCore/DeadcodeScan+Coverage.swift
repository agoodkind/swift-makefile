//
//  DeadcodeScan+Coverage.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - DeadcodeScan coverage options

extension DeadcodeScan {
  /// Build the engine-owned coverage request from the consumer's normal Xcode inputs.
  /// `buildableSchemes` is the scheme set `xcodebuild -list` reports, so the derived
  /// matrix drops any dependency-project target that is not a buildable scheme.
  static func coverageBuildOptions(
    path: String,
    isWorkspace: Bool,
    packageTargets: Set<String>,
    buildableSchemes: Set<String>
  ) -> Toolchain.CoverageBuildOptions {
    let rawDerivedData = Env.get("SWIFT_MK_DERIVED_DATA")
    let derivedData = DeadcodeBuildConfig.resolvedDerivedDataRoot(rawDerivedData)
    var options = Toolchain.CoverageBuildOptions()
    options.containerPath = path
    options.isWorkspace = isWorkspace
    options.generator = coverageGenerator()
    options.configuration = Env.get("SWIFT_XCODE_COVERAGE_CONFIGURATION", "Debug")
    options.derivedDataPath = rawDerivedData
    options.packageTargetNames = packageTargets
    options.buildableSchemeNames = buildableSchemes
    options.extraSettings = coverageBuildSettings()
    options.environment = DeadcodeBuildConfig.buildEnvironment(derivedData: derivedData)
    return options
  }

  private static func coverageGenerator() -> Toolchain.Generator {
    let fallback = Toolchain.Generator.tuist
    let raw = Env.get("SWIFT_XCODE_GENERATOR", fallback.rawValue)
    guard let generator = Toolchain.Generator(rawValue: raw) else {
      Output.error(
        "deadcode: unknown SWIFT_XCODE_GENERATOR '\(raw)', using \(fallback.rawValue)")
      return fallback
    }
    return generator
  }

  private static func coverageBuildSettings() -> [String: String] {
    var settings: [String: String] = [:]
    // Shell-tokenize, not whitespace-split: a consumer forwards its project build
    // settings as `KEY="value with spaces"`, and only shell tokenization keeps the
    // value intact with the quotes stripped, so xcodebuild and its run-script phases
    // read the real value rather than a quote-wrapped fragment.
    for pair in Env.shellWords(Env.get("SWIFT_XCODE_BUILD_SETTINGS")) {
      guard let equals = pair.firstIndex(of: "=") else {
        Output.error("deadcode: ignoring malformed SWIFT_XCODE_BUILD_SETTINGS value \(pair)")
        continue
      }
      let key = String(pair[..<equals])
      let value = String(pair[pair.index(after: equals)...])
      settings[key] = value
    }
    return settings
  }
}
