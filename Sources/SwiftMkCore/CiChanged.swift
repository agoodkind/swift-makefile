//
//  CiChanged.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - CiChanged

/// Decides which CI gate families a push or pull request changed, so CI can skip
/// build, test, and lint work independently while every required check still reports
/// green. Relevance comes from the fresh build graph read at head (see `readGraph`),
/// not from a restored index: a changed source file feeds the build family only when
/// the graph compiles it. Lint relevance comes from the lint source set. A build
/// system whose project is generated rather than committed cannot be read cheaply, so
/// it falls back to path rules where any non-documentation change runs every family.
/// Every uncertainty runs the full CI.
public enum CiChanged {
  public enum GateFamily: Sendable {
    case build
    case lint
  }

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
}

// MARK: - CiChanged

extension CiChanged {
  private static let documentationExtensions: Set<String> = [
    ".adoc", ".markdown", ".md", ".rst", ".txt",
  ]
  private static let buildConfigBasenames: Set<String> = [
    "Info.plist", "Makefile", "Package.resolved", "Package.swift", "Project.swift",
    "Tuist.swift", "Workspace.swift", "project.yml",
  ]
  private static let lintConfigBasenames: Set<String> = [
    ".swift-format", ".swiftlint.yml",
  ]
  private static let buildConfigExtensions: Set<String> = [
    ".entitlements", ".mk", ".xcconfig",
  ]
  private static let buildGateFamilies: Set<GateFamily> = [.build]
  private static let lintGateFamilies: Set<GateFamily> = [.lint]
  private static let allGateFamilies: Set<GateFamily> = [.build, .lint]
  private static let githubWorkflowComponentCount = 2
  private static let shaCharacterCount = 40
  private static let nameStatusMinimumFields = 2

  private typealias FamilyReason = (families: Set<GateFamily>, reason: String)

  private struct ClassificationContext {
    let consumerDirs: [String]
    let resourceDirs: [String]
    let graph: Graph?
    let deletedPaths: Set<String>
    let lintSources: Set<String>
  }

  /// Classify the changed paths against the deterministic in-scope sets. Each changed
  /// path contributes the gate families it feeds, and the classifier returns the union.
  /// A build configuration feeds both families unless it is lint-only config. A consumer
  /// `extra-dirs` entry, a declared resource prefix, or a compiled source feeds build.
  /// A lint source feeds lint independently, so a compiled `.swift` source feeds both.
  /// Deleted non-documentation paths and path fallback non-documentation paths feed both
  /// families, preserving the conservative full-run behavior when the graph cannot
  /// prove a narrower answer.
  public static func classify(
    changedPaths: [String],
    graph: Graph?,
    extraDirs: [String],
    deletedPaths: Set<String> = [],
    lintSources: Set<String> = []
  ) -> (families: Set<GateFamily>, reason: String) {
    let context = ClassificationContext(
      consumerDirs: extraDirs.map(stripTrailingSlashes).filter { !$0.isEmpty },
      resourceDirs: (graph?.resourcePrefixes ?? []).map(stripTrailingSlashes)
        .filter { !$0.isEmpty },
      graph: graph,
      deletedPaths: deletedPaths,
      lintSources: lintSources
    )
    var families: Set<GateFamily> = []
    var reasons: [String] = []

    for path in changedPaths {
      for familyReason in pathFamilyReasons(path: path, context: context) {
        recordFamilyReason(
          familyReason,
          families: &families,
          reasons: &reasons
        )
        if families.isSuperset(of: allGateFamilies) {
          return (families, reasons.joined(separator: "; "))
        }
      }
    }

    if reasons.isEmpty {
      return (families, "no gate-relevant changes")
    }
    return (families, reasons.joined(separator: "; "))
  }

  private static func pathFamilyReasons(
    path: String,
    context: ClassificationContext
  ) -> [FamilyReason] {
    if isBuildConfig(path) {
      return [(allGateFamilies, "build config: \(path)")]
    }
    if isLintConfig(path) {
      return [(lintGateFamilies, "lint config: \(path)")]
    }

    var familyReasons: [FamilyReason] = []
    if let directory = context.consumerDirs.first(where: { isPath(path, under: $0) }) {
      familyReasons.append((buildGateFamilies, "extra dir: \(directory)"))
    }
    if let resource = context.resourceDirs.first(where: { isPath(path, under: $0) }) {
      familyReasons.append((buildGateFamilies, "declared resource: \(resource)"))
    }

    if context.deletedPaths.contains(path) {
      if !isDocumentation(path) {
        familyReasons.append((allGateFamilies, "deleted input: \(path)"))
      }
      return familyReasons
    }

    if context.lintSources.contains(path) {
      familyReasons.append((lintGateFamilies, "lint source: \(path)"))
    }
    if let graph = context.graph {
      if graph.sources.contains(path) {
        familyReasons.append((buildGateFamilies, "build input: \(path)"))
      }
    } else if !isDocumentation(path) {
      familyReasons.append((allGateFamilies, "path fallback: \(path)"))
    }
    return familyReasons
  }

  private static func recordFamilyReason(
    _ familyReason: FamilyReason,
    families: inout Set<GateFamily>,
    reasons: inout [String]
  ) {
    let missingFamilies = familyReason.families.subtracting(families)
    if missingFamilies.isEmpty {
      return
    }
    families.formUnion(familyReason.families)
    reasons.append(familyReason.reason)
  }

  public static func run() -> Int32 {
    let decision = decide()
    emitOutputs(families: decision.families, reason: decision.reason)
    return 0
  }

  private struct Decision {
    let families: Set<GateFamily>
    let reason: String
  }

  private enum DiffBase {
    case base(String)
    case decision(Decision)
  }

  private static func resolveDiffBase(
    defaultBranch: String,
    head: String,
    isPullRequest: Bool
  ) -> DiffBase {
    if Env.get("SWIFT_MK_REF_NAME") == defaultBranch {
      let diffBase = Env.get("SWIFT_MK_DIFF_BASE")
      if diffBase.isEmpty || isAllZeroSHA(diffBase) {
        return .decision(fullRunDecision(reason: "missing diff base on default branch"))
      }
      guard isAncestor(base: diffBase, head: head) else {
        return .decision(fullRunDecision(reason: "diff base is not an ancestor of head"))
      }
      return .base(diffBase)
    }
    let mergeBase = featureBranchMergeBase(
      defaultBranch: defaultBranch, head: head, isPullRequest: isPullRequest)
    guard let mergeBase else {
      return .decision(fullRunDecision(reason: "could not compute feature branch merge-base"))
    }
    return .base(mergeBase)
  }

  private static let pushEventName = "push"
  private static let pullRequestEventName = "pull_request"

  /// The events the detector classifies. A push carries the pushed range, and a pull
  /// request carries its own branch head, so both give a well-defined diff. Any other
  /// event has no reliable base, so the detector fails safe to a full run.
  static func isSupportedEvent(_ eventName: String) -> Bool {
    eventName == pushEventName || eventName == pullRequestEventName
  }

  private static func decide() -> Decision {
    let eventName = Env.get("SWIFT_MK_EVENT_NAME")
    let head = Env.get("SWIFT_MK_DIFF_HEAD", "HEAD")
    // The detector logs each phase unconditionally, not behind SWIFT_MK_LOG_LEVEL. In
    // CI these lines are the only record of where the detector spent its time, so a
    // stall (a slow git command or dependency resolve) shows exactly which phase is in
    // flight rather than a silent step. There is no interactive output to keep quiet.
    Output.info("ci-changed: event=\(eventName.isEmpty ? "(unset)" : eventName) head=\(head)")
    guard isSupportedEvent(eventName) else {
      let event = eventName.isEmpty ? "(unset)" : eventName
      return fullRunDecision(reason: "unsupported event: \(event)")
    }

    let defaultBranch = Env.get("SWIFT_MK_DEFAULT_BRANCH")
    if defaultBranch.isEmpty {
      return fullRunDecision(reason: "missing default branch")
    }

    let base: String
    let isPullRequest = eventName == pullRequestEventName
    Output.info("ci-changed: resolving the diff base against \(defaultBranch)")
    switch resolveDiffBase(defaultBranch: defaultBranch, head: head, isPullRequest: isPullRequest) {
    case .base(let value):
      base = value
    case .decision(let decision):
      return decision
    }
    Output.info("ci-changed: diff base=\(base)")

    guard let repoRoot = gitOutput(["rev-parse", "--show-toplevel"]) else {
      return fullRunDecision(reason: "could not resolve git toplevel")
    }
    // Operate from the repository root so the graph read, which resolves the project
    // relative to the working directory, shares the repo-root base with the git diff and
    // the lint set. This keeps the detector correct when it is invoked from a subdirectory.
    // A failed chdir leaves the reads on an unknown base, so it fails safe to a full run.
    guard FileManager.default.changeCurrentDirectoryPath(repoRoot) else {
      return fullRunDecision(reason: "could not change to repo root")
    }
    Output.info("ci-changed: diffing \(base)..\(head)")
    guard let changedFiles = changedFiles(base: base, head: head) else {
      return fullRunDecision(reason: "git diff failed")
    }
    if changedFiles.isEmpty {
      return Decision(families: [], reason: "no changed files")
    }
    Output.info("ci-changed: \(changedFiles.count) changed path(s)")

    let changedPaths = changedFiles.map { standardizePath($0.path, root: repoRoot) }
    let deletedPaths = Set(
      changedFiles.filter(\.deleted).map { standardizePath($0.path, root: repoRoot) })
    let extraDirs = Env.words(Env.get("SWIFT_MK_CI_EXTRA_DIRS")).map { directory in
      standardizePath(directory, root: repoRoot)
    }
    // The lint gate lints exactly this set (every tracked and untracked-not-ignored
    // `.swift`), anchored to the same repo root as the changed paths, so a linted source
    // is never pruned by the build graph.
    Output.info("ci-changed: resolving the lint source set")
    let lintContext = PathContext(pwd: repoRoot + "/", cwd: repoRoot + "/")
    let lintSources = Set(
      LintSourceSet.resolve(context: lintContext).map { standardizePath($0, root: repoRoot) })

    let resolved = readGraph(root: repoRoot)
    if resolved.failed {
      return fullRunDecision(reason: "could not read the build graph")
    }
    Output.info("ci-changed: classifying changed paths against the build graph")
    let result = classify(
      changedPaths: changedPaths,
      graph: resolved.graph,
      extraDirs: extraDirs,
      deletedPaths: deletedPaths,
      lintSources: lintSources)
    return Decision(families: result.families, reason: result.reason)
  }

  private static func fullRunDecision(reason: String) -> Decision {
    Decision(families: allGateFamilies, reason: reason)
  }

  // MARK: Git

  /// Run a git subcommand, logging the invocation on the diagnostic boundary. Every
  /// git call in this type routes through here, so the process boundary has one
  /// explicit, auditable place to report. `run()` forces debug output for the detector,
  /// so in CI this line prints for every git call and shows which command is running
  /// when the detector stalls.
  private static func runGit(_ arguments: [String]) -> Shell.Result {
    Output.debug("ci-changed: git \(arguments.joined(separator: " "))")
    return Shell.run("git", arguments)
  }

  static func featureBranchMergeBase(
    defaultBranch: String,
    head: String,
    isPullRequest: Bool
  ) -> String? {
    if let base = gitOutput(["merge-base", "origin/\(defaultBranch)", head]) {
      return base
    }
    // GitHub checks out `refs/pull/N/merge`, a merge of the base branch (HEAD^1) and
    // the pull-request head (HEAD^2). Both parents are already in the checkout, so
    // their merge-base is the branch point, computable with no network fetch and no
    // credentials. This is why a PR that never fetched `origin/<default>` still
    // classifies instead of running every gate. This holds only for pull-request
    // events: on a push, HEAD is a real commit whose parents (if it is a merge) are
    // unrelated to the default branch, so the fast path is restricted to pull requests.
    if isPullRequest, let base = gitOutput(["merge-base", "HEAD^1", "HEAD^2"]) {
      return base
    }
    // Fallback for a checkout that is not a merge ref: `origin/<default>` is absent
    // and a plain `git fetch origin <default>` updates only FETCH_HEAD, so fetch into
    // the remote-tracking ref explicitly and retry.
    let fetch = runGit([
      "fetch", "--no-tags", "origin",
      "+refs/heads/\(defaultBranch):refs/remotes/origin/\(defaultBranch)",
    ])
    if fetch.status != 0 {
      Output.error(
        "ci-changed: fetch of \(defaultBranch) for merge-base failed (status \(fetch.status)): "
          + fetch.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
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

  private static func emitOutputs(families: Set<GateFamily>, reason: String) {
    let runBuild = families.contains(.build)
    let runLint = families.contains(.lint)
    let changed = runBuild || runLint
    let output =
      [
        "run_build=\(runBuild)",
        "run_lint=\(runLint)",
        "run=\(changed)",
        "changed=\(changed)",
      ].joined(separator: "\n") + "\n"
    let outputPath = Env.get("GITHUB_OUTPUT")
    if !outputPath.isEmpty {
      do {
        try CacheService.appendToFile(path: outputPath, text: output)
      } catch {
        Output.error("ci-changed: could not write \(outputPath): \(error)")
      }
    }
    Output.log(
      "ci-changed: run_build=\(runBuild) run_lint=\(runLint) run=\(changed) (\(reason))")
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

  private static func isLintConfig(_ path: String) -> Bool {
    let basename = (path as NSString).lastPathComponent
    return lintConfigBasenames.contains(basename)
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
