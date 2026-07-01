//
//  DeadcodeCoverageMatrix.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import PathKit
import XcodeProj

// MARK: - CoveragePlatform

/// The Xcode SDK platforms the dead-code coverage build can target, one per
/// `SUPPORTED_PLATFORMS` token (or `SUPPORTS_MACCATALYST`) a target's build settings
/// name. Kept here, not on `Toolchain`: this file derives which platforms a target
/// needs, a later task maps each case to a `build-for-testing` destination, and that
/// mapping has no reason to depend on how the set was derived.
public enum CoveragePlatform: String, Sendable, CaseIterable {
  case iphoneos
  case iphonesimulator
  case maccatalyst
  case macosx
}

// MARK: - DeadcodeCoverageEntry

/// One `(scheme, platform)` pair the coverage build must build-for-testing. Carries no
/// destination: a later task derives that from `platform` at the point it drives the
/// build, so this stays a pure description of the matrix.
public struct DeadcodeCoverageEntry: Equatable, Sendable {
  public let scheme: String
  public let platform: CoveragePlatform
}

// MARK: - DeadcodeCoverageMatrix

/// Derives the dead-code coverage build matrix from a generated Xcode project or
/// workspace, so a consumer declares no deadcode knob.
///
/// The generator (Tuist or xcodegen) already wrote every shared scheme, each target's
/// product type, and each target's supported platforms; this reads that instead of a
/// consumer listing schemes and platforms by hand, the same "derive from what the
/// generator wrote" approach `IndexCompleteness` uses for its expected-source set.
public enum DeadcodeCoverageMatrix {
  /// Thrown when a kept target's build settings name no platform this enumerator
  /// recognizes. There is no safe default destination for such a target, so the
  /// caller cannot build a coverage matrix for it and must fail loud instead of
  /// silently dropping the target from coverage.
  enum EnumerationError: Error, CustomStringConvertible {
    case noKnownPlatform(scheme: String, target: String)

    var description: String {
      switch self {
      case let .noKnownPlatform(scheme, target):
        return
          "deadcode coverage: scheme \"\(scheme)\" target \"\(target)\" has no known "
          + "coverage platform (SUPPORTED_PLATFORMS / SUPPORTS_MACCATALYST); cannot "
          + "compute a build-for-testing destination"
      }
    }
  }

  // MARK: Integration entry point

  /// The full `(scheme, platform)` matrix for `containerPath`, an `.xcodeproj` path or
  /// (when `isWorkspace`) an `.xcworkspace` path. `packageTargetNames` excludes targets
  /// the SwiftPM package scan already covers, so they are not double-built here.
  /// Deduplicated and sorted by scheme then platform, so the output is deterministic.
  public static func entries(
    containerPath: String, isWorkspace: Bool, packageTargetNames: Set<String>
  ) throws -> [DeadcodeCoverageEntry] {
    Output.debug(
      "deadcode: deriving coverage matrix from \(containerPath) isWorkspace=\(isWorkspace)")
    let projectPaths =
      isWorkspace
      ? try IndexCompleteness.xcodeProjectPaths(inWorkspace: containerPath)
      : [containerPath]
    var seenKeys: Set<String> = []
    var result: [DeadcodeCoverageEntry] = []
    for projectFile in projectPaths {
      let project = try XcodeProj(path: Path(projectFile))
      let schemes = sharedSchemes(for: project, projectFile: projectFile)
      // A project with no shared schemes (xcodegen writes none by default) still
      // builds through Xcode's auto-created per-target schemes, which `xcodebuild
      // -list` reports and `xcodebuild -scheme <target>` resolves on demand. Derive
      // one auto-scheme entry per buildable native target so an xcodegen consumer
      // gets a coverage matrix, matching the schemes the periphery scan reads from
      // `xcodebuild -list`. A project with shared schemes uses those verbatim.
      let projectEntries =
        schemes.isEmpty
        ? try autoSchemeEntries(project: project, packageTargetNames: packageTargetNames)
        : try sharedSchemeEntries(
          schemes: schemes, project: project, packageTargetNames: packageTargetNames)
      for entry in projectEntries {
        let key = "\(entry.scheme)|\(entry.platform.rawValue)"
        if seenKeys.insert(key).inserted {
          result.append(entry)
        }
      }
    }
    return result.sorted { lhs, rhs in
      lhs.scheme == rhs.scheme
        ? lhs.platform.rawValue < rhs.platform.rawValue : lhs.scheme < rhs.scheme
    }
  }

  // MARK: Scheme resolution

  /// A project's shared (`xcshareddata`) schemes. `sharedData` is usually populated by
  /// `XcodeProj(path:)`, but reads it again through `XCSharedData` directly as a
  /// fallback for a project whose shared data failed to attach to the initial load, so
  /// a real on-disk scheme is never silently dropped.
  static func sharedSchemes(for project: XcodeProj, projectFile: String) -> [XCScheme] {
    if let schemes = project.sharedData?.schemes {
      return schemes
    }
    do {
      return try XCSharedData(path: XCSharedData.path(Path(projectFile))).schemes
    } catch {
      // No `xcshareddata` directory on disk at all is the expected shape for a
      // project with no shared schemes, not a failure this enumerator should
      // report; the caller sees an empty scheme list either way.
      return []
    }
  }

  // MARK: Scheme derivation

  /// The coverage entries every shared scheme contributes, flattened across the schemes.
  static func sharedSchemeEntries(
    schemes: [XCScheme], project: XcodeProj, packageTargetNames: Set<String>
  ) throws -> [DeadcodeCoverageEntry] {
    var entries: [DeadcodeCoverageEntry] = []
    for scheme in schemes {
      entries += try coverageEntries(
        scheme: scheme, project: project, packageTargetNames: packageTargetNames)
    }
    return entries
  }

  /// The coverage entries for a project with no shared schemes: one auto-scheme per
  /// buildable native target, named after the target the way Xcode names an
  /// auto-created scheme. Each qualifying target expands to one entry per platform it
  /// supports, the same expansion `coverageEntries` applies to a shared scheme's
  /// targets.
  static func autoSchemeEntries(
    project: XcodeProj, packageTargetNames: Set<String>
  ) throws -> [DeadcodeCoverageEntry] {
    var entries: [DeadcodeCoverageEntry] = []
    for target in project.pbxproj.nativeTargets {
      guard
        isCoverageTarget(
          productType: target.productType,
          name: target.name,
          packageTargetNames: packageTargetNames)
      else {
        continue
      }
      let targetPlatforms = resolvedPlatforms(for: target)
      guard !targetPlatforms.isEmpty else {
        throw EnumerationError.noKnownPlatform(scheme: target.name, target: target.name)
      }
      for platform in targetPlatforms {
        entries.append(DeadcodeCoverageEntry(scheme: target.name, platform: platform))
      }
    }
    return entries
  }

  /// The coverage entries one scheme contributes: every build-for-testing entry whose
  /// target resolves and qualifies (`isCoverageTarget`), expanded to one entry per
  /// platform the target supports.
  static func coverageEntries(
    scheme: XCScheme, project: XcodeProj, packageTargetNames: Set<String>
  ) throws -> [DeadcodeCoverageEntry] {
    let buildActionEntries = scheme.buildAction?.buildActionEntries ?? []
    var entries: [DeadcodeCoverageEntry] = []
    for entry in buildActionEntries where entry.buildFor.contains(.testing) {
      let targetName = entry.buildableReference.blueprintName
      guard let target = nativeTarget(named: targetName, in: project) else {
        continue
      }
      guard
        isCoverageTarget(
          productType: target.productType,
          name: target.name,
          packageTargetNames: packageTargetNames)
      else {
        continue
      }
      let targetPlatforms = resolvedPlatforms(for: target)
      guard !targetPlatforms.isEmpty else {
        throw EnumerationError.noKnownPlatform(scheme: scheme.name, target: target.name)
      }
      for platform in targetPlatforms {
        entries.append(DeadcodeCoverageEntry(scheme: scheme.name, platform: platform))
      }
    }
    return entries
  }

  /// The `PBXNativeTarget` named `name`, matched by name rather than by
  /// `blueprintIdentifier`/UUID: `pbxproj.objects` is internal, but `name` is public
  /// and stable across a project reload.
  static func nativeTarget(named name: String, in project: XcodeProj) -> PBXNativeTarget? {
    project.pbxproj.nativeTargets.first { $0.name == name }
  }

  /// The platforms a target's build settings name, unioned across every build
  /// configuration: a target whose configurations disagree (a Debug-only platform
  /// addition, for example) must still cover the union, since the coverage build
  /// always runs one fixed configuration and needs every platform any configuration
  /// declares.
  static func resolvedPlatforms(for target: PBXNativeTarget) -> Set<CoveragePlatform> {
    var result: Set<CoveragePlatform> = []
    let configurations = target.buildConfigurationList?.buildConfigurations ?? []
    for configuration in configurations {
      let settings = configuration.buildSettings
      result.formUnion(
        platforms(
          supportedPlatforms: settings["SUPPORTED_PLATFORMS"]?.stringValue,
          supportsMacCatalyst: settings["SUPPORTS_MACCATALYST"]?.boolValue ?? false))
    }
    return result
  }

  // MARK: Pure decision helpers

  /// Parse `SUPPORTED_PLATFORMS` (comma and/or space separated tokens, for example
  /// `"macosx iphoneos iphonesimulator"`) into the matching `CoveragePlatform` set,
  /// dropping any token that names no known platform, and add `.maccatalyst` when
  /// `supportsMacCatalyst` is true. `SUPPORTS_MACCATALYST` is a separate build setting,
  /// not a `SUPPORTED_PLATFORMS` token, so it is checked independently rather than
  /// folded into the token parse.
  static func platforms(
    supportedPlatforms: String?, supportsMacCatalyst: Bool
  ) -> Set<CoveragePlatform> {
    var result: Set<CoveragePlatform> = []
    let raw = supportedPlatforms ?? ""
    for token in raw.split(whereSeparator: { $0 == "," || $0 == " " }) {
      if let platform = CoveragePlatform(rawValue: String(token)) {
        result.insert(platform)
      }
    }
    if supportsMacCatalyst {
      result.insert(.maccatalyst)
    }
    return result
  }

  /// True when the target's compiled Swift belongs in the dead-code coverage build. A
  /// test bundle is already covered by the scheme's test action, not build-for-testing
  /// coverage; a command-line tool builds no app/framework the coverage matrix targets;
  /// and a SwiftPM package target named in `packageTargetNames` is already covered by
  /// periphery's package scan. Excluding all three avoids double coverage. A `nil`
  /// product type means the target's kind could not be resolved from the project, and
  /// there is no safe basis to build such a target for testing, so this returns false
  /// rather than guessing it belongs.
  static func isCoverageTarget(
    productType: PBXProductType?, name: String, packageTargetNames: Set<String>
  ) -> Bool {
    guard let productType else {
      return false
    }
    switch productType {
    case .unitTestBundle, .uiTestBundle, .ocUnitTestBundle, .commandLineTool:
      return false
    default:
      return !packageTargetNames.contains(name)
    }
  }
}
