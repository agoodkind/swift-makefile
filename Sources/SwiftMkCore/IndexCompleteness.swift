//
//  IndexCompleteness.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import IndexStore
import PathKit
import XcodeProj

// MARK: - IndexCompleteness

/// Verifies that the Xcode index store recorded every source file in the scanned
/// targets, before periphery scans it.
///
/// A build can exit 0 yet leave a partial index under contention. periphery learns
/// which files to scan from the index alone, so an unindexed file is invisible to
/// it, and a real symbol looks unused when the file that references it is missing.
/// This compares the source files the project's targets contain against the source
/// files the index recorded, and returns the exact difference.
public enum IndexCompleteness {
  /// The result of the check, with the gate's message already built. `complete`
  /// carries a status line to log. `incomplete` carries the failure line, which
  /// also covers an evaluation error, since both mean the scan must not run.
  public enum Outcome {
    case complete(String)
    case incomplete(String)
  }

  /// Compare the indexed source files to the expected target sources. On a partial
  /// index, write the exact missing list to a trace-scoped log and return the
  /// failure message naming the count and the log path.
  public static func verify(
    indexStorePath: String,
    projectPath: String,
    isWorkspace: Bool,
    excludeTargets: Set<String>
  ) -> Outcome {
    let missing: [String]
    let expectedCount: Int
    do {
      let indexed = try indexedSwiftFiles(indexStorePath: indexStorePath)
      let expected = try expectedSwiftFiles(
        projectPath: projectPath,
        isWorkspace: isWorkspace,
        excludeTargets: excludeTargets)
      missing = expected.subtracting(indexed).sorted()
      expectedCount = expected.count
    } catch {
      return .incomplete("lint-deadcode: could not verify index completeness: \(error)")
    }
    if missing.isEmpty {
      return .complete("deadcode: index complete, \(expectedCount) target sources indexed")
    }
    let logPath = BuildFailureLog.write(
      output: missing.joined(separator: "\n"),
      logDirectory: Logging.logDirectory,
      traceID: Logging.correlation.traceID,
      name: "deadcode-index-incomplete")
    return .incomplete(
      "lint-deadcode: index incomplete, \(missing.count) of \(expectedCount) "
        + "target sources not indexed, not scanning; missing list at "
        + (logPath ?? "(log unavailable)"))
  }

  /// The absolute `.swift` paths the index store recorded, from the units the
  /// build wrote. Mirrors periphery's `SourceFileCollector`: non-system units with
  /// a non-empty main file.
  public static func indexedSwiftFiles(indexStorePath: String) throws -> Set<String> {
    let store = try IndexStore(path: indexStorePath)
    var files: Set<String> = []
    for unit in store.units where !unit.isSystem {
      let mainFile = unit.mainFile
      if mainFile.hasSuffix(".swift") {
        files.insert(standardize(mainFile))
      }
    }
    return files
  }

  /// The absolute `.swift` paths that the project's non-test, non-excluded targets
  /// contain, read from each target's source build phase through `XcodeProj`.
  public static func expectedSwiftFiles(
    projectPath: String,
    isWorkspace: Bool,
    excludeTargets: Set<String>
  ) throws -> Set<String> {
    let projectPaths =
      isWorkspace
      ? try xcodeProjectPaths(inWorkspace: projectPath)
      : [projectPath]
    var files: Set<String> = []
    for projectFile in projectPaths {
      let project = try XcodeProj(path: Path(projectFile))
      let sourceRoot = (projectFile as NSString).deletingLastPathComponent
      for target in project.pbxproj.nativeTargets {
        if isTestTarget(target) || excludeTargets.contains(target.name) {
          continue
        }
        guard let phase = try target.sourcesBuildPhase(),
          let buildFiles = phase.files
        else {
          continue
        }
        for buildFile in buildFiles {
          guard let element = buildFile.file,
            let fullPath = try element.fullPath(sourceRoot: sourceRoot),
            fullPath.hasSuffix(".swift"),
            !isVendoredDependencySource(fullPath)
          else {
            continue
          }
          let resolved = standardize(fullPath)
          if isUnresolvedSourceReference(resolved) {
            continue
          }
          files.insert(resolved)
        }
      }
    }
    return files
  }

  /// True when a target source path is a vendored SPM dependency, not the project's
  /// own code. A tuist workspace that generates its dependencies as source projects
  /// (rather than binary-cached frameworks) lists their checkout sources in target
  /// build phases. periphery already excludes these from its scan, and the coverage
  /// build need not compile them, so the completeness check must not expect them to
  /// be indexed; otherwise the index reads as incomplete on every run.
  static func isVendoredDependencySource(_ path: String) -> Bool {
    path.contains("/.build/") || path.contains("/SourcePackages/")
  }

  /// True when a target lists a `.swift` reference that does not resolve to a real
  /// source on disk, so the index can never be expected to hold it. An Xcode file
  /// reference can carry a build-variable source tree such as `${DERIVED_FILE_DIR}`
  /// or `$(SRCROOT)` for a source generated into the build directory; XcodeProj
  /// returns that path literally, so it names no file on disk and matches no indexed
  /// unit. A reference left behind for a deleted file fails the same way. Requiring
  /// either reads the index as incomplete on every run and masks the real partial
  /// index, so both are dropped. A genuine project source always exists on disk and
  /// is kept, so a source the build compiled but failed to index is still caught.
  static func isUnresolvedSourceReference(_ path: String) -> Bool {
    if path.contains("$(") || path.contains("${") {
      return true
    }
    return !FileManager.default.fileExists(atPath: path)
  }

  static func isTestTarget(_ target: PBXNativeTarget) -> Bool {
    switch target.productType {
    case .unitTestBundle, .uiTestBundle, .ocUnitTestBundle:
      return true
    default:
      return false
    }
  }

  /// The `.xcodeproj` paths a workspace references, resolved to absolute paths.
  static func xcodeProjectPaths(inWorkspace workspacePath: String) throws -> [String] {
    let workspace = try XCWorkspace(path: Path(workspacePath))
    let parent = (workspacePath as NSString).deletingLastPathComponent
    var paths: [String] = []
    collectFileRefs(workspace.data.children, parent: parent, into: &paths)
    return paths.filter { $0.hasSuffix(".xcodeproj") }
  }

  private static func collectFileRefs(
    _ elements: [XCWorkspaceDataElement],
    parent: String,
    into paths: inout [String]
  ) {
    for element in elements {
      switch element {
      case .file(let ref):
        paths.append(resolve(ref.location, parent: parent))
      case .group(let group):
        collectFileRefs(group.children, parent: parent, into: &paths)
      }
    }
  }

  private static func resolve(
    _ location: XCWorkspaceDataElementLocationType,
    parent: String
  ) -> String {
    switch location {
    case .absolute(let path):
      return path
    default:
      return (parent as NSString).appendingPathComponent(location.path)
    }
  }

  /// Resolve a path to an absolute, symlink-resolved form so the indexed set and
  /// the expected set compare cleanly.
  static func standardize(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }
}
