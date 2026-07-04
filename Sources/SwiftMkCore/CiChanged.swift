//
//  CiChanged.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - CiChanged

/// Decides whether a push changed anything the build depends on, so CI can skip the
/// build, test, and lint work on a push that changes nothing build-relevant while every
/// required check still reports green. Relevance comes from the fresh build graph read at
/// head (see `readGraph`), not from a restored index: a changed source file is relevant
/// only when the graph compiles it, so a source-shaped file the build does not compile is
/// skippable. A build system whose project is generated rather than committed cannot be
/// read cheaply, so it falls back to path rules where any source-shaped change runs. Every
/// uncertainty runs the full CI.
public enum CiChanged {
  /// The build graph resolved at head: the compiled source files (exact paths) and the
  /// declared resource paths (matched as prefixes, so a directory resource catches a
  /// change to a file inside it).
  public struct Graph: Sendable {
    public let sources: Set<String>
    public let resourcePrefixes: [String]

    public init(sources: Set<String>, resourcePrefixes: [String]) {
      self.sources = sources
      self.resourcePrefixes = resourcePrefixes
    }
  }

  private static let documentationExtensions: Set<String> = [
    ".adoc", ".markdown", ".md", ".rst", ".txt",
  ]
  private static let buildConfigBasenames: Set<String> = [
    ".swift-format", ".swiftlint.yml", "Info.plist", "Makefile", "Package.resolved",
    "Package.swift", "Project.swift", "Tuist.swift", "Workspace.swift", "project.yml",
  ]
  private static let buildConfigExtensions: Set<String> = [
    ".entitlements", ".mk", ".xcconfig",
  ]
  private static let githubWorkflowComponentCount = 2
  private static let shaCharacterCount = 40
  private static let nameStatusMinimumFields = 2

  /// Classify the changed paths against the deterministic in-scope sets. First match wins
  /// and marks the push relevant. A changed path runs when it is a build configuration, is
  /// under a consumer `extra-dirs` entry, is a declared resource (`graph.resourcePrefixes`,
  /// matched as a prefix), is a compiled source (`graph.sources`), or is a linted source
  /// (`lintSources`, the exact set the lint gate scans). Both sets are authoritative: the
  /// build graph is what the build compiles, and `lintSources` is what the lint gate lints,
  /// so a source that one gate covers is never pruned because another gate skips it. A path
  /// in `deletedPaths` is absent from both sets, so a deletion that is not plainly
  /// documentation runs, which keeps a removed source, resource, or config from being
  /// pruned into a false skip. In path-fallback mode
  /// (`graph` nil, a generated project that was not read) any change that is not plainly
  /// documentation is relevant, since a resource or data file can be a build input the path
  /// rules cannot see. A path matching none is skippable, and when every changed path is skippable
  /// the push skips.
  public static func classify(
    changedPaths: [String],
    graph: Graph?,
    extraDirs: [String],
    deletedPaths: Set<String> = [],
    lintSources: Set<String> = []
  ) -> (changed: Bool, reason: String) {
    let consumerDirs = extraDirs.map(stripTrailingSlashes).filter { !$0.isEmpty }
    let resourceDirs = (graph?.resourcePrefixes ?? []).map(stripTrailingSlashes)
      .filter { !$0.isEmpty }
    for path in changedPaths {
      if isBuildConfig(path) {
        return (true, "build config: \(path)")
      }
      for directory in consumerDirs where isPath(path, under: directory) {
        return (true, "extra dir: \(directory)")
      }
      for resource in resourceDirs where isPath(path, under: resource) {
        return (true, "declared resource: \(resource)")
      }
      if deletedPaths.contains(path) {
        // A deleted file is absent from the head sets, so run on any deletion that is not
        // plainly documentation, since a removed source, resource, or config changes what
        // the build produces.
        if !isDocumentation(path) {
          return (true, "deleted input: \(path)")
        }
      } else if lintSources.contains(path) {
        return (true, "lint source: \(path)")
      } else if let graph {
        if graph.sources.contains(path) {
          return (true, "build input: \(path)")
        }
      } else if !isDocumentation(path) {
        // Path-fallback (graph nil): a generated project's graph was not read, so run on
        // any change that is not plainly documentation, since a resource or data file can
        // be a build input the path rules cannot see.
        return (true, "path fallback: \(path)")
      }
    }
    return (false, "no build-relevant changes")
  }

  public static func run() -> Int32 {
    let decision = decide()
    emitOutputs(changed: decision.changed, reason: decision.reason)
    return 0
  }

  private struct Decision {
    let changed: Bool
    let reason: String
  }

  private enum DiffBase {
    case base(String)
    case decision(Decision)
  }

  private static func resolveDiffBase(defaultBranch: String, head: String) -> DiffBase {
    if Env.get("SWIFT_MK_REF_NAME") == defaultBranch {
      let diffBase = Env.get("SWIFT_MK_DIFF_BASE")
      if diffBase.isEmpty || isAllZeroSHA(diffBase) {
        return .decision(Decision(changed: true, reason: "missing diff base on default branch"))
      }
      guard isAncestor(base: diffBase, head: head) else {
        return .decision(Decision(changed: true, reason: "diff base is not an ancestor of head"))
      }
      return .base(diffBase)
    }
    guard let mergeBase = featureBranchMergeBase(defaultBranch: defaultBranch, head: head) else {
      return .decision(
        Decision(changed: true, reason: "could not compute feature branch merge-base"))
    }
    return .base(mergeBase)
  }

  private static func decide() -> Decision {
    let eventName = Env.get("SWIFT_MK_EVENT_NAME")
    let head = Env.get("SWIFT_MK_DIFF_HEAD", "HEAD")
    guard eventName == "push" else {
      let event = eventName.isEmpty ? "(unset)" : eventName
      return Decision(changed: true, reason: "non-push event: \(event)")
    }

    let defaultBranch = Env.get("SWIFT_MK_DEFAULT_BRANCH")
    if defaultBranch.isEmpty {
      return Decision(changed: true, reason: "missing default branch")
    }

    let base: String
    switch resolveDiffBase(defaultBranch: defaultBranch, head: head) {
    case .base(let value):
      base = value
    case .decision(let decision):
      return decision
    }

    guard let repoRoot = gitOutput(["rev-parse", "--show-toplevel"]) else {
      return Decision(changed: true, reason: "could not resolve git toplevel")
    }
    // Operate from the repository root so the graph read, which resolves the project
    // relative to the working directory, shares the repo-root base with the git diff and
    // the lint set. This keeps the detector correct when it is invoked from a subdirectory.
    // A failed chdir leaves the reads on an unknown base, so it fails safe to a full run.
    guard FileManager.default.changeCurrentDirectoryPath(repoRoot) else {
      return Decision(changed: true, reason: "could not change to repo root")
    }
    guard let changedFiles = changedFiles(base: base, head: head) else {
      return Decision(changed: true, reason: "git diff failed")
    }
    if changedFiles.isEmpty {
      return Decision(changed: false, reason: "no changed files")
    }

    let changedPaths = changedFiles.map { standardizePath($0.path, root: repoRoot) }
    let deletedPaths = Set(
      changedFiles.filter(\.deleted).map { standardizePath($0.path, root: repoRoot) })
    let extraDirs = Env.words(Env.get("SWIFT_MK_CI_EXTRA_DIRS")).map { directory in
      standardizePath(directory, root: repoRoot)
    }
    // The lint gate lints exactly this set (every tracked and untracked-not-ignored
    // `.swift`), anchored to the same repo root as the changed paths, so a linted source
    // is never pruned by the build graph.
    let lintContext = PathContext(pwd: repoRoot + "/", cwd: repoRoot + "/")
    let lintSources = Set(
      LintSourceSet.resolve(context: lintContext).map { standardizePath($0, root: repoRoot) })

    let resolved = readGraph(root: repoRoot)
    if resolved.failed {
      return Decision(changed: true, reason: "could not read the build graph")
    }
    let result = classify(
      changedPaths: changedPaths,
      graph: resolved.graph,
      extraDirs: extraDirs,
      deletedPaths: deletedPaths,
      lintSources: lintSources)
    return Decision(changed: result.changed, reason: result.reason)
  }

  // MARK: Git

  /// Run a git subcommand, logging the invocation on the diagnostic boundary. Every
  /// git call in this type routes through here, so the process boundary has one
  /// explicit, auditable place to report.
  private static func runGit(_ arguments: [String]) -> Shell.Result {
    Output.debug("ci-changed: git \(arguments.joined(separator: " "))")
    return Shell.run("git", arguments)
  }

  private static func featureBranchMergeBase(defaultBranch: String, head: String) -> String? {
    if let base = gitOutput(["merge-base", "origin/\(defaultBranch)", head]) {
      return base
    }
    _ = runGit(["fetch", "--no-tags", "origin", defaultBranch])
    return gitOutput(["merge-base", "origin/\(defaultBranch)", head])
  }

  private struct ChangedFile {
    let path: String
    let deleted: Bool
  }

  private static func changedFiles(base: String, head: String) -> [ChangedFile]? {
    let result = runGit(["diff", "--name-status", "--diff-filter=ACMRTD", base, head])
    guard result.status == 0 else {
      return nil
    }
    var files: [ChangedFile] = []
    for line in result.stdout.split(whereSeparator: \.isNewline) {
      let fields = line.split(separator: "\t").map(String.init)
      guard let status = fields.first, fields.count >= nameStatusMinimumFields else {
        continue
      }
      if status.hasPrefix("R") {
        // A rename removes the old path and adds the new one, so the old path is a
        // deletion the head graph cannot see.
        files.append(ChangedFile(path: fields[1], deleted: true))
        if let newPath = fields.last, newPath != fields[1] {
          files.append(ChangedFile(path: newPath, deleted: false))
        }
      } else if status.hasPrefix("D") {
        files.append(ChangedFile(path: fields[1], deleted: true))
      } else {
        files.append(ChangedFile(path: fields.last ?? fields[1], deleted: false))
      }
    }
    return files
  }

  private static func gitOutput(_ arguments: [String]) -> String? {
    let result = runGit(arguments)
    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.status != 0 || trimmed.isEmpty {
      return nil
    }
    return trimmed
  }

  private static func isAncestor(base: String, head: String) -> Bool {
    runGit(["merge-base", "--is-ancestor", base, head]).status == 0
  }

  // MARK: Output

  private static func emitOutputs(changed: Bool, reason: String) {
    let output = "changed=\(changed)\nrun=\(changed)\n"
    let outputPath = Env.get("GITHUB_OUTPUT")
    if !outputPath.isEmpty {
      do {
        try CacheService.appendToFile(path: outputPath, text: output)
      } catch {
        Output.error("ci-changed: could not write \(outputPath): \(error)")
      }
    }
    Output.log("ci-changed: \(changed) (\(reason))")
  }

  // MARK: Path helpers

  static func absolute(_ path: String, root: String) -> String {
    if (path as NSString).isAbsolutePath {
      return path
    }
    return (root as NSString).appendingPathComponent(path)
  }

  static func standardizePath(_ path: String, root: String) -> String {
    IndexCompleteness.standardize(absolute(path, root: root))
  }

  private static func isDocumentation(_ path: String) -> Bool {
    let pathExtension = (path as NSString).pathExtension.lowercased()
    return documentationExtensions.contains(".\(pathExtension)")
  }

  private static func isBuildConfig(_ path: String) -> Bool {
    let basename = (path as NSString).lastPathComponent
    if buildConfigBasenames.contains(basename) {
      return true
    }
    if basename.lowercased().hasSuffix("-baseline.txt") {
      return true
    }
    let pathExtension = (path as NSString).pathExtension.lowercased()
    if buildConfigExtensions.contains(".\(pathExtension)") {
      return true
    }
    let components = (path as NSString).pathComponents
    if isGitHubWorkflowPath(components) {
      return true
    }
    for component in components
    where component.hasSuffix(".xcodeproj") || component.hasSuffix(".xcworkspace") {
      return true
    }
    return components.contains("Tuist")
  }

  private static func isGitHubWorkflowPath(_ components: [String]) -> Bool {
    guard components.count >= githubWorkflowComponentCount else {
      return false
    }
    for index in 0..<(components.count - 1) {
      if components[index] == ".github", components[index + 1] == "workflows" {
        return true
      }
    }
    return false
  }

  private static func isPath(_ path: String, under directory: String) -> Bool {
    let normalizedDirectory = stripTrailingSlashes(directory)
    return path == normalizedDirectory || path.hasPrefix(normalizedDirectory + "/")
  }

  private static func stripTrailingSlashes(_ path: String) -> String {
    var stripped = path
    while stripped != "/", stripped.hasSuffix("/") {
      stripped.removeLast()
    }
    return stripped
  }

  private static func isAllZeroSHA(_ value: String) -> Bool {
    value.count == shaCharacterCount && value.allSatisfy { $0 == "0" }
  }
}
