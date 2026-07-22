//
//  CiChanged+Graph.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import PathKit
import XcodeProj

// MARK: - CiChanged build graph

extension CiChanged {
  /// Bound the change-detection build-graph read. `swift package describe` resolves the
  /// dependency graph, which clones dependencies over the network when the SwiftPM cache
  /// is cold. Without a bound a stalled resolve hangs the detector to the job timeout, so
  /// cap it and fail safe to a full run. A cold resolve on a healthy network finishes well
  /// under this; a timeout means run everything this once, which is safe and self-corrects
  /// once the cache warms.
  private static let describeTimeoutSeconds: Double = 120

  /// Read the fresh build graph at head for the working directory's build system, so a
  /// changed file's relevance comes from what the build actually compiles rather than a
  /// stale index. The return value is the graph and whether the read failed. A nil graph
  /// with `failed` false is the path-fallback for a generated project. A SwiftPM package
  /// reads the graph from `swift package describe`. A committed Xcode project reads it
  /// with XcodeProj. A manifest whose project is generated and not committed (Tuist or
  /// XcodeGen) is not generated here, since generating resolves the whole dependency graph
  /// and is nearly as costly as a build; it falls back to path rules plus `extra-dirs`. A
  /// read that fails runs the full CI.
  static func readGraph(root: String) -> (graph: Graph?, failed: Bool) {
    switch DeadcodeScan.projectShape() {
    case .swiftPMOnly:
      Output.report("ci-changed: reading the SwiftPM build graph via swift package describe")
      let start = Date()
      guard let json = SwiftPM.describePackageJSON(timeoutSeconds: describeTimeoutSeconds) else {
        Output.error("ci-changed: swift package describe failed or timed out")
        return (nil, true)
      }
      guard let graph = parseDescribe(json, root: root) else {
        return (nil, true)
      }
      Output.report(
        "ci-changed: build graph has \(graph.sources.count) source(s) and "
          + "\(graph.resourcePrefixes.count) resource prefix(es), describe took "
          + String(format: "%.1fs", Date().timeIntervalSince(start)))
      return (graph, false)
    case .project(let project):
      Output.report(
        "ci-changed: reading the Xcode build graph from "
          + ((project.path as NSString).lastPathComponent))
      do {
        let graph = try xcodeGraph(projectPath: project.path, isWorkspace: project.isWorkspace)
        Output.report(
          "ci-changed: build graph has \(graph.sources.count) source(s) and "
            + "\(graph.resourcePrefixes.count) resource prefix(es)")
        return (graph, false)
      } catch {
        Output.error("ci-changed: could not read xcode project: \(error)")
        return (nil, true)
      }
    case .manifestWithoutProject:
      Output.report(
        "ci-changed: generated project without a committed graph; using path rules")
      return (nil, false)
    }
  }

  private static func parseDescribe(_ json: String, root: String) -> Graph? {
    do {
      let described = try JSONDecoder().decode(
        DescribedPackage.self, from: DeadcodeScan.jsonData(json))
      // Resolve target paths against the package root describe reports, not the git root,
      // so the paths are correct when the package is not at the repository root.
      let packageRoot = described.path ?? root
      var sources: Set<String> = []
      var resources: [String] = []
      for target in described.targets {
        // A target kind without a path or sources (binary, plugin, system) contributes no
        // source paths, so skip it rather than fail decoding and force a full run.
        guard let targetPath = target.path else {
          continue
        }
        let targetRoot = absolute(targetPath, root: packageRoot)
        for source in target.sources ?? [] {
          sources.insert(standardizePath(source, root: targetRoot))
        }
        for resource in target.resources ?? [] {
          resources.append(standardizePath(resource.path, root: targetRoot))
        }
      }
      return Graph(sources: sources, resourcePrefixes: resources)
    } catch {
      Output.error("ci-changed: could not parse swift package describe json: \(error)")
      return nil
    }
  }

  /// The build-input set of an Xcode project or workspace: every native target's source
  /// and resource build-phase files, test targets included, resolved to absolute
  /// standardized paths. It reuses the XcodeProj enumeration the index-completeness check
  /// uses for sources, extended to the resource build phase and not limited to `.swift`.
  private static func xcodeGraph(projectPath: String, isWorkspace: Bool) throws -> Graph {
    let projectPaths =
      isWorkspace
      ? try IndexCompleteness.xcodeProjectPaths(inWorkspace: projectPath)
      : [projectPath]
    var sources: Set<String> = []
    var resources: [String] = []
    for projectFile in projectPaths {
      let project = try XcodeProj(path: Path(projectFile))
      let sourceRoot = (projectFile as NSString).deletingLastPathComponent
      // A test source change must run the test gate, so test targets are build inputs
      // here and are not pruned, matching parseDescribe which keeps every described
      // target. This intentionally differs from the dead-code index, which drops tests.
      for target in project.pbxproj.nativeTargets {
        if let phase = try target.sourcesBuildPhase() {
          for path in resolvedPaths(phase.files, sourceRoot: sourceRoot) {
            sources.insert(path)
          }
        }
        if let phase = try target.resourcesBuildPhase() {
          resources.append(contentsOf: resolvedPaths(phase.files, sourceRoot: sourceRoot))
        }
      }
    }
    return Graph(sources: sources, resourcePrefixes: resources)
  }

  private static func resolvedPaths(_ files: [PBXBuildFile]?, sourceRoot: String) -> [String] {
    guard let files else {
      return []
    }
    var paths: [String] = []
    for buildFile in files {
      guard let element = buildFile.file else {
        continue
      }
      let fullPath: String
      do {
        guard let candidate = try element.fullPath(sourceRoot: sourceRoot) else {
          continue
        }
        fullPath = candidate
      } catch {
        Output.debug("ci-changed: could not resolve build file path: \(error)")
        continue
      }
      guard !IndexCompleteness.isVendoredDependencySource(fullPath) else {
        continue
      }
      let resolved = IndexCompleteness.standardize(fullPath)
      if IndexCompleteness.isUnresolvedSourceReference(resolved) {
        continue
      }
      paths.append(resolved)
    }
    return paths
  }

  private struct DescribedPackage: Decodable {
    struct Target: Decodable {
      let path: String?
      let sources: [String]?
      let resources: [Resource]?
    }
    struct Resource: Decodable {
      let path: String
    }

    let path: String?
    let targets: [Target]
  }
}
