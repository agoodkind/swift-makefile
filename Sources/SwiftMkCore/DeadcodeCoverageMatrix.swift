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

/// The Xcode SDK platforms the dead-code coverage build can target. A later mapper
/// turns each case into a `build-for-testing` destination. iOS always builds on the
/// simulator, so device and simulator both resolve to `.iphonesimulator`.
public enum CoveragePlatform: String, Sendable, CaseIterable {
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
/// Two authoritative sources drive the matrix, and neither guesses from static build
/// settings. The scheme set comes from the project's schemes, filtered to the schemes
/// `xcodebuild -list` reports and to targets that carry indexable app or framework code.
/// The platform set for each scheme comes from `xcodebuild -showdestinations`, which
/// resolves through the consumer's xcconfigs the same way a real build does, so a
/// dynamically resolved `SUPPORTED_PLATFORMS` or a Mac Catalyst opt-in is read correctly
/// rather than reconstructed from the raw project file.
public enum DeadcodeCoverageMatrix {
  /// Thrown when a scheme the matrix must build reports no destination this enumerator
  /// maps to a coverage platform. Failing loud is required: silently dropping the scheme
  /// would leave its sources unindexed and turn real references into false unused
  /// findings.
  enum EnumerationError: Error, CustomStringConvertible {
    case noKnownPlatform(scheme: String)

    var description: String {
      switch self {
      case let .noKnownPlatform(scheme):
        return
          "deadcode coverage: scheme \"\(scheme)\" reports no macOS, Mac Catalyst, or iOS "
          + "destination from xcodebuild -showdestinations; cannot compute a "
          + "build-for-testing destination"
      }
    }
  }

  // MARK: Platform expansion

  /// Expand each scheme across the platforms `platformsForScheme` reports, deduplicated
  /// and sorted by scheme then platform so the output is deterministic. A scheme that
  /// reports no coverage platform is a hard failure, not a silent drop.
  static func expandPlatforms(
    schemeNames: Set<String>,
    platformsForScheme: (String) throws -> Set<CoveragePlatform>
  ) throws -> [DeadcodeCoverageEntry] {
    var seenKeys: Set<String> = []
    var result: [DeadcodeCoverageEntry] = []
    for scheme in schemeNames.sorted() {
      let platforms = try platformsForScheme(scheme)
      guard !platforms.isEmpty else {
        throw EnumerationError.noKnownPlatform(scheme: scheme)
      }
      for platform in platforms.sorted(by: { $0.rawValue < $1.rawValue }) {
        let key = "\(scheme)|\(platform.rawValue)"
        if seenKeys.insert(key).inserted {
          result.append(DeadcodeCoverageEntry(scheme: scheme, platform: platform))
        }
      }
    }
    return result
  }

  // MARK: Scheme selection

  /// The schemes the coverage build must build: every scheme whose build-for-testing
  /// targets include an indexable app or framework, filtered to the schemes
  /// `xcodebuild -list` reports so a workspace's dependency-project schemes drop out.
  static func coverageSchemeNames(
    containerPath: String,
    isWorkspace: Bool,
    packageTargetNames: Set<String>,
    buildableSchemeNames: Set<String>
  ) throws -> Set<String> {
    Output.debug("deadcode: selecting coverage schemes from \(containerPath)")
    let projectPaths =
      isWorkspace
      ? try IndexCompleteness.xcodeProjectPaths(inWorkspace: containerPath)
      : [containerPath]
    var names: Set<String> = []
    for projectFile in projectPaths {
      let project = try XcodeProj(path: Path(projectFile))
      let schemes = sharedSchemes(for: project, projectFile: projectFile)
      if schemes.isEmpty {
        // A project with no shared schemes (xcodegen writes none by default) builds
        // through Xcode's auto-created per-target schemes, which `xcodebuild -list`
        // reports and `xcodebuild -scheme <target>` resolves on demand. Use one
        // auto-scheme per indexable native target.
        for target in project.pbxproj.nativeTargets
        where isCoverageTarget(
          productType: target.productType,
          name: target.name,
          packageTargetNames: packageTargetNames)
        {
          names.insert(target.name)
        }
      } else {
        for scheme in schemes
        where schemeHasCoverageTarget(
          scheme, project: project, packageTargetNames: packageTargetNames)
        {
          names.insert(scheme.name)
        }
      }
    }
    if buildableSchemeNames.isEmpty {
      return names
    }
    return names.intersection(buildableSchemeNames)
  }

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
      // project with no shared schemes, not a failure this enumerator should report.
      return []
    }
  }

  /// True when a shared scheme builds at least one indexable app or framework for
  /// testing, so the scheme belongs in the coverage build.
  static func schemeHasCoverageTarget(
    _ scheme: XCScheme, project: XcodeProj, packageTargetNames: Set<String>
  ) -> Bool {
    let buildActionEntries = scheme.buildAction?.buildActionEntries ?? []
    for entry in buildActionEntries where entry.buildFor.contains(.testing) {
      let targetName = entry.buildableReference.blueprintName
      guard let target = nativeTarget(named: targetName, in: project) else {
        continue
      }
      if isCoverageTarget(
        productType: target.productType,
        name: target.name,
        packageTargetNames: packageTargetNames)
      {
        return true
      }
    }
    return false
  }

  /// The `PBXNativeTarget` named `name`, matched by name rather than by
  /// `blueprintIdentifier`/UUID: `pbxproj.objects` is internal, but `name` is public
  /// and stable across a project reload.
  static func nativeTarget(named name: String, in project: XcodeProj) -> PBXNativeTarget? {
    project.pbxproj.nativeTargets.first { $0.name == name }
  }

  /// True when the target's compiled Swift belongs in the dead-code coverage build. A
  /// test bundle is already covered by the scheme's test action; a command-line tool
  /// builds no app or framework the coverage matrix targets; and a SwiftPM package
  /// target named in `packageTargetNames` is already covered by periphery's package
  /// scan. A `nil` product type is unresolved, so this returns false rather than guess.
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

  // MARK: Destination parsing

  /// The coverage platforms named by an `xcodebuild -showdestinations` transcript. Only
  /// the "Available destinations" section counts, so an ineligible destination never
  /// enters the matrix. iOS device and iOS Simulator both map to `.iphonesimulator`,
  /// since the coverage build compiles iOS on the simulator to avoid device signing.
  static func coveragePlatforms(showDestinationsOutput output: String) -> Set<CoveragePlatform> {
    var result: Set<CoveragePlatform> = []
    var inAvailableSection = false
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("Available destinations") {
        inAvailableSection = true
        continue
      }
      if line.hasPrefix("Ineligible destinations") {
        inAvailableSection = false
        continue
      }
      guard inAvailableSection, line.hasPrefix("{") else {
        continue
      }
      guard let platform = destinationField("platform", in: line) else {
        continue
      }
      let variant = destinationField("variant", in: line)
      if let coverage = coveragePlatform(platform: platform, variant: variant) {
        result.insert(coverage)
      }
    }
    return result
  }

  /// The value of a `key:value` field in an `xcodebuild -showdestinations` line such as
  /// `{ platform:iOS Simulator, arch:arm64, variant:Mac Catalyst, id:… }`. Values may
  /// contain spaces (`iOS Simulator`, `Mac Catalyst`), so fields split on commas and
  /// each field splits on its first colon.
  static func destinationField(_ key: String, in line: String) -> String? {
    let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "{} \t"))
    for part in inner.split(separator: ",") {
      let field = part.trimmingCharacters(in: .whitespaces)
      let prefix = key + ":"
      if field.hasPrefix(prefix) {
        return String(field.dropFirst(prefix.count))
      }
    }
    return nil
  }

  /// The coverage platform a destination's `platform` (and `variant`) names, or nil for
  /// a platform the coverage build does not target (watchOS, tvOS, DriverKit).
  static func coveragePlatform(platform: String, variant: String?) -> CoveragePlatform? {
    switch platform {
    case "macOS":
      return variant == "Mac Catalyst" ? .maccatalyst : .macosx
    case "iOS", "iOS Simulator":
      return .iphonesimulator
    default:
      return nil
    }
  }
}
