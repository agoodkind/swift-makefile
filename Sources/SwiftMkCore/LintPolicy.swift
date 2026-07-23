//
//  LintPolicy.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - LintSourceSet

/// The owned Swift source set the hard build gate lints, discovered from the
/// working tree rather than from caller-supplied targets.
///
/// The make path lints `SWIFTLINT_TARGETS` (default `Sources Tests Package.swift`),
/// which a consumer can narrow or redirect. The hard gate must not be narrowable, so
/// it discovers every tracked and untracked-but-not-ignored `.swift` file plus the
/// project manifests directly from git, with a filesystem walk as the fallback when
/// git is absent, then drops anything git ignores. It takes no roots, excludes, or
/// file lists, so a consumer cannot shrink what the gate sees.
public enum LintSourceSet {
  /// Project manifests linted alongside `.swift` sources.
  static let manifestNames: [String] = [
    "Package.swift", "Project.swift", "Workspace.swift", "project.yml",
  ]

  /// Directory names skipped by the filesystem-walk fallback: build output, caches,
  /// vcs metadata, and vendored package checkouts, matching the gate-proof digest's
  /// exclusions.
  static let excludedDirectories: Set<String> = [
    ".git", ".build", ".make", "DerivedData", "Derived", "Products",
    "SourcePackages", "node_modules", ".swiftpm", "build", ".tuist", "Pods",
  ]

  /// Resolve the owned source set. Discovery runs against the current working
  /// directory, the same base every other gate uses, so the returned paths are
  /// working-directory-relative and feed swiftlint, swift-format, and swiftcheck
  /// directly. Git ignore is applied last so a tracked file is never silently
  /// dropped by a path pattern.
  public static func resolve(context: PathContext = .current()) -> [String] {
    let root = rootPath(context)
    let discovered = gitTrackedAndUntracked(root: root) ?? filesystemWalk(root: root)
    let unique = Array(Set(discovered)).sorted()
    return Lint.dropGitIgnored(unique)
  }

  /// The discovery root, the context's working directory with its trailing slash
  /// trimmed. The gate runs with this as the process working directory, so the git
  /// commands and the returned relative paths share one base.
  static func rootPath(_ context: PathContext) -> String {
    context.cwd.hasSuffix("/") ? String(context.cwd.dropLast()) : context.cwd
  }

  // MARK: Git discovery

  /// The `.swift` files and manifests git knows about under `root`, both tracked
  /// (`--cached`) and untracked-but-not-ignored (`--others --exclude-standard`), or
  /// nil when this is not a git work tree so the caller falls back to a filesystem
  /// walk. NUL-delimited so paths with spaces survive.
  static func gitTrackedAndUntracked(root: String) -> [String]? {
    Output.debug("lint: discovering owned source set via git ls-files in \(root)")
    let result = Shell.run(
      "git",
      [
        "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z",
        "--", "*.swift",
      ] + manifestNames)
    guard result.status == 0 else {
      return nil
    }
    let paths =
      result.stdout
      .split(separator: "\u{0}", omittingEmptySubsequences: true)
      .map(String.init)
    return paths.filter { isSwiftOrManifest($0) }
  }

  // MARK: Filesystem fallback

  /// Walk `root` for `.swift` files and manifests when git is unavailable, skipping
  /// build output and vendored checkouts.
  static func filesystemWalk(root rootDirectory: String) -> [String] {
    let manager = FileManager.default
    let root = URL(fileURLWithPath: rootDirectory, isDirectory: true)
    let rootPath = root.standardizedFileURL.path
    guard
      let enumerator = manager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [])
    else {
      return []
    }
    var paths: [String] = []
    for case let item as URL in enumerator {
      let isDirectory: Bool
      do {
        isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
      } catch {
        Output.warning("lint: could not stat \(item.path): \(error)")
        isDirectory = false
      }
      if isDirectory {
        if excludedDirectories.contains(item.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }
      guard isSwiftOrManifest(item.lastPathComponent) else {
        continue
      }
      let absolute = item.standardizedFileURL.path
      if absolute.hasPrefix(rootPath + "/") {
        paths.append(String(absolute.dropFirst(rootPath.count + 1)))
      } else {
        paths.append(absolute)
      }
    }
    return paths
  }

  /// Whether a path names a `.swift` source or one of the project manifests.
  static func isSwiftOrManifest(_ path: String) -> Bool {
    if path.hasSuffix(".swift") {
      return true
    }
    let name = (path as NSString).lastPathComponent
    return manifestNames.contains(name)
  }
}

// MARK: - LintPolicy

/// The hard gate's tool runners. Each computes its findings against the owned
/// source set, evaluates them against the JSONL baseline, and reports only the
/// violations that must be fixed. The output never names the baseline, never prints
/// a baseline-framed count, and never hints at a bypass, so the agent that runs the
/// gate cannot learn a grandfathering or skip path exists.
enum LintPolicy {
  /// The single remediation line the hard gate prints. Neutral on purpose: it tells
  /// the agent to fix the violations and nothing about how the gate decides them.
  static let remediation = "Fix these violations before this gate will pass."

  // MARK: Shared baseline evaluation

  /// Evaluate `findings` against the JSONL baseline and report the result without
  /// revealing the baseline. The baseline still grandfathers known findings (a
  /// preserved gate invariant), but the agent sees only the new violations and a
  /// neutral remediation, never a count framed against a baseline or its path.
  static func gate(name: String, findings: [Finding], baselinePath: String) -> Bool {
    let baseline = BaselineStore.read(baselinePath)
    let result = CountAwareGate.evaluate(current: findings, baseline: baseline)
    if result.passed {
      Output.log("\(name): OK")
      return true
    }
    Output.log("\(name): FAILED")
    Output.log("Violations:")
    for finding in result.newFindings {
      Output.log("  \(finding.file):\(finding.line):\(finding.column)\n    \(finding.message)")
    }
    Output.log("\n  \(remediation)")
    return false
  }

  /// Drop findings whose file git ignores, a backstop in case a tool reports a
  /// generated or untracked file the source set already excluded.
  static func dropGitIgnored(_ findings: [Finding]) -> [Finding] {
    let files = Set(findings.map(\.file).filter { !$0.isEmpty })
    guard !files.isEmpty else {
      return findings
    }
    let kept = Set(Lint.dropGitIgnored(Array(files)))
    return findings.filter { $0.file.isEmpty || kept.contains($0.file) }
  }

  // MARK: swiftlint and complexity

  /// Run swiftlint over the owned source set, gating its findings. `onlyRules`
  /// selects the complexity-metric run; empty runs the full rule set. Ignores
  /// `LINT_FILES`/`SWIFTLINT_TARGETS`/`LINT_LINE_RANGES`, reading only the
  /// engine-owned config path.
  static func swiftlint(
    name: String,
    sources: [String],
    onlyRules: [String],
    baselinePath: String,
    context: PathContext
  ) -> Bool {
    Output.debug("\(name): running over \(sources.count) owned source(s)")
    let executable = Env.get("SWIFTLINT", "swiftlint")
    let config = Env.get("SWIFT_MK_SWIFTLINT_CONFIG", ".make/swiftlint.yml")
    let onlyArgs = onlyRules.flatMap { ["--only-rule", $0] }
    let arguments = ["lint", "--strict", "--config", config] + onlyArgs + sources
    let result = Shell.run(
      executable, arguments + ["--reporter", "json"], environment: Lint.lintEnvironment())
    let findings: [Finding]
    do {
      findings = try FindingsSource.decodeSwiftlintJSON(result.stdout)
    } catch {
      Output.log("\(name): FAILED")
      Output.logError("  swiftlint output could not be decoded: \(error)")
      return false
    }
    if result.status != 0, findings.isEmpty {
      Output.log("\(name): FAILED")
      Output.log("  swiftlint exited \(result.status) with no findings")
      Output.log(result.combined)
      return false
    }
    let normalized = findings.map { LintPolicy.normalize($0, context: context) }
    return gate(name: name, findings: dropGitIgnored(normalized), baselinePath: baselinePath)
  }

  /// Normalize a finding's path through the shared `Findings.normalizePath`, so the
  /// hard gate's keys match the baseline's keys.
  static func normalize(_ finding: Finding, context: PathContext) -> Finding {
    Finding(
      tool: finding.tool,
      ruleId: finding.ruleId,
      file: Findings.normalizePath(finding.file, context),
      line: finding.line,
      column: finding.column,
      severity: finding.severity,
      message: finding.message,
      usr: finding.usr,
      symbol: finding.symbol,
      hints: finding.hints)
  }

  // MARK: format

  /// Run swift-format's lint over the owned source set. Any diagnostic output or a
  /// nonzero status fails the gate; formatting has no baseline.
  static func format(sources: [String]) -> Bool {
    Output.debug("lint-format: checking \(sources.count) owned source(s)")
    let formatCommand = Env.words(Env.get("SWIFT_FORMAT", "xcrun swift-format"))
    guard let executable = formatCommand.first else {
      Output.log("lint-format: FAILED")
      Output.log("  SWIFT_FORMAT is empty")
      return false
    }
    let config = Env.get("SWIFT_MK_SWIFT_FORMAT_CONFIG", ".make/swift-format.json")
    let arguments =
      Array(formatCommand.dropFirst())
      + ["lint", "--strict", "--configuration", config] + sources
    let result = Shell.run(executable, arguments, environment: Lint.lintEnvironment())
    if !result.combined.isEmpty || result.status != 0 {
      Output.log("lint-format: FAILED")
      Output.log("Violations:")
      Output.log(result.combined)
      Output.log("\n  \(remediation)")
      return false
    }
    Output.log("lint-format: OK")
    return true
  }

  // MARK: swiftcheck-extra

  /// Run the swiftcheck-extra analyzer over the owned source set, gating its
  /// findings. Ignores `SWIFTCHECK_EXTRA_TARGETS`.
  static func swiftcheck(sources: [String], context: PathContext) -> Bool {
    Output.debug("swiftcheck-extra: analyzing \(sources.count) owned source(s)")
    guard let binary = Swiftcheck.preparedBin() else {
      Output.log("swiftcheck-extra: FAILED")
      Output.log("  analyzer binary unavailable")
      return false
    }
    Capture.ensureMakeDir()
    let raw = ".make/swiftcheck-extra.raw.out"
    let flags = Env.words(Env.get("SWIFTCHECK_EXTRA_FLAGS"))
    let result = Shell.run(binary, flags + sources)
    Capture.write(result.combined, to: raw)
    let exclude = Text.excludePattern(
      Env.get("SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS"),
      Env.get("SWIFTCHECK_EXTRA_EXCLUDE_PATHS"))
    let parsedAll = Swiftcheck.parseFindings(rawPath: raw, context: context)
    let findings = Swiftcheck.structuredFindings(rawPath: raw, exclude: exclude, context: context)
    if Swiftcheck.isToolFailure(status: result.status, parsedAll: parsedAll) {
      Output.log("swiftcheck-extra: FAILED")
      Output.log("  analyzer exited \(result.status) with no findings")
      Output.log(result.combined)
      return false
    }
    return gate(
      name: "swiftcheck-extra",
      findings: findings,
      baselinePath: Env.get("SWIFTCHECK_EXTRA_BASELINE", ".swiftcheck-extra-baseline.jsonl"))
  }

  // MARK: deadcode

  /// Run the periphery dead-code scan and, for an Xcode consumer, the in-process
  /// coverage scan, gating the findings. Reuses the deadcode-config env (the
  /// periphery config and args) but ignores the lint narrowers: it never applies
  /// `LINT_LINE_RANGES`. A compile error in the coverage build, or a periphery hard
  /// failure, fails the gate loud before any baseline comparison, the same as the
  /// make path.
  static func deadcode(context: PathContext) -> Bool {
    Output.debug("lint-deadcode: running periphery scan")
    Capture.ensureMakeDir()
    let raw = ".make/periphery.raw.out"
    let findingsPath = ".make/periphery.out"
    let config = Env.get("SWIFT_MK_PERIPHERY_CONFIG", ".make/periphery.yml")
    let args = Env.words(
      Env.get("PERIPHERY_ARGS", "scan --config \(config) --strict"))
    Output.log(DeadcodeScan.packageScanLabel)
    let result = Shell.run(
      Env.get("PERIPHERY", "periphery"), args, environment: Lint.lintEnvironment())
    GateStatus.last = result.status
    Capture.write(DeadcodeScan.packageScanLabel + "\n" + result.combined, to: raw)
    Output.log(result.combined.trimmingCharacters(in: .newlines))
    let indexStore = DeadcodeScan.appendXcodeFindings(rawPath: raw)
    Capture.extractFindings(
      rawPath: raw,
      findingsPath: findingsPath,
      excludePattern: Lint.peripheryExclude(),
      context: context)
    let status = GateStatus.last
    // Shared with the make path: classify the compile error and the index/build
    // failures, print the verdict line, and fail on the real cause before any
    // baseline comparison.
    if Lint.reportDeadcodeBuildFailure(rawPath: raw, status: status) {
      return false
    }
    // Unbypassable coverage check, shared with the make path: every owned Swift source
    // must be covered by the package scan or the Xcode index, so own code in an Xcode
    // target with no Xcode scan is not silently unscanned.
    if case .incomplete(let message) = DeadcodeCoverageCompleteness.assert(
      xcodeIndexStorePath: indexStore, context: context)
    {
      Output.log("lint-deadcode: FAILED")
      Output.log(message)
      return false
    }
    let parsed = Lint.parseDeadcodeFindings(findingsPath: findingsPath, context: context)
    return gate(
      name: "lint-deadcode",
      findings: parsed,
      baselinePath: Env.get("PERIPHERY_BASELINE", ".periphery-baseline.jsonl"))
  }

  // MARK: audit

  /// Run the dependency audit over lockfiles that git's effective ignore treats as
  /// visible. osv-scanner's own recursive walk only honors the repo `.gitignore`
  /// tree and misses `core.excludesFile`, so discovery runs through
  /// `AuditLockfiles` and passes explicit `-L` paths instead. Honors
  /// `OSV_SCANNER_ARGS` (with `--recursive` stripped) for the config and other
  /// scanner flags.
  static func audit() -> Bool {
    Output.info("audit: scanning dependencies")
    let scanner = Env.get("OSV_SCANNER", "osv-scanner")
    let root = Env.get("SWIFT_AUDIT_ROOT", ".")
    let configured = Env.get("OSV_SCANNER_ARGS")
    let configuredWords: [String]
    if configured.isEmpty {
      var defaults = ["--allow-no-lockfiles"]
      let config = ".make/osv-scanner.toml"
      if FileManager.default.fileExists(atPath: config) {
        defaults += ["--config", config]
      }
      configuredWords = defaults
    } else {
      configuredWords = Env.words(configured)
    }
    let lockfiles = AuditLockfiles.discover(root: root)
    let args = AuditLockfiles.scannerArguments(
      configured: configuredWords, lockfiles: lockfiles)
    Output.debug("audit: scanning \(lockfiles.count) git-visible lockfile(s)")
    let result = Shell.run(scanner, args)
    Output.emitStandardOutput(result.combined)
    if result.status != 0 {
      Output.log("audit: FAILED")
      return false
    }
    return true
  }
}

// MARK: - Lint hard build check

extension Lint {
  /// The single fixed hard gate the decoupled API runs: the canonical gate list
  /// (swiftlint, format, complexity, deadcode, swiftcheck-extra), then the
  /// dependency audit, then the log audit when the consumer supplies one. It runs
  /// the generation hook first so generated sources exist before discovery, then
  /// discovers the owned source set once and shares it across the file-based gates.
  ///
  /// It never reads `LINT_GATES`, never honors `LINT_FILES`/`LINT_LINE_RANGES`/
  /// `SWIFTLINT_TARGETS`/`SWIFT_FORMAT_TARGETS`/`SWIFTCHECK_EXTRA_TARGETS`/
  /// `BYPASS_LINT`, and never falls back to a recursive make target for an unknown
  /// gate name. It keeps the deadcode-configuration env (the periphery config, the
  /// derived-data path, the index-settle and concurrency knobs) since those shape
  /// how the gate runs rather than what it covers.
  @discardableResult
  public static func runHardBuildCheck(
    context: PathContext, hooks: GatedBuild.Hooks
  ) -> Bool {
    Capture.ensureMakeDir()
    if let generate = hooks.generate, !generate() {
      Output.log("generate: FAILED")
      Output.log("\n1 check failed: generate")
      return false
    }
    let failed = runHardGates(context: context, hooks: hooks)
    if failed.isEmpty {
      return true
    }
    return false
  }

  /// Run every fixed gate against the owned source set and return the names of the
  /// gates that failed. Discovery runs once and is shared across the file-based
  /// gates so the same source set drives swiftlint, format, complexity, and
  /// swiftcheck.
  private static func runHardGates(
    context: PathContext, hooks: GatedBuild.Hooks
  ) -> [String] {
    let sources = LintSourceSet.resolve(context: context)
    var items = [
      GateItem(name: "lint-swiftlint") {
        LintPolicy.swiftlint(
          name: "lint-swiftlint",
          sources: sources,
          onlyRules: [],
          baselinePath: Env.get("SWIFTLINT_BASELINE", ".swiftlint-baseline.jsonl"),
          context: context)
      },
      GateItem(name: "lint-format") {
        LintPolicy.format(sources: sources)
      },
      GateItem(name: "lint-complexity") {
        LintPolicy.swiftlint(
          name: "lint-complexity",
          sources: sources,
          onlyRules: complexityRules(),
          baselinePath: Env.get(
            "SWIFTLINT_COMPLEXITY_BASELINE", ".swiftlint-complexity-baseline.jsonl"),
          context: context)
      },
      GateItem(name: "lint-deadcode") {
        LintPolicy.deadcode(context: context)
      },
      GateItem(name: "swiftcheck-extra") {
        LintPolicy.swiftcheck(sources: sources, context: context)
      },
      GateItem(name: "audit") {
        LintPolicy.audit()
      },
    ]
    if let logAudit = hooks.logAudit {
      items.append(
        GateItem(name: "log-audit") {
          logAudit()
        })
    }
    return GateDisplay.runGates(title: "Build check gates", items: items)
  }
}
