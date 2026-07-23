//
//  Lint+Run.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Lint Run

extension Lint {
  // MARK: tools

  @discardableResult
  public static func runTools(context _: PathContext) -> Bool {
    Output.info("lint-tools: resolving formatter and analyzers")
    Capture.ensureMakeDir()
    let version = Shell.run(
      Env.get("SWIFT_FORMAT", "xcrun swift-format").components(separatedBy: " ")[0],
      ["swift-format", "--version"])
    if version.status != 0 {
      // Fall back to direct invocation form when SWIFT_FORMAT is a single token.
      let direct = Shell.run("xcrun", ["swift-format", "--version"])
      if direct.status != 0 {
        Output.log(direct.combined)
        return false
      }
    }
    for tool in ["swiftlint", "periphery", "osv-scanner"]
    where Shell.sh("command -v \(tool)").status != 0 {
      Shell.run("brew", ["install", tool])
    }
    return Swiftcheck.resolveBin()
  }

  // MARK: fmt

  @discardableResult
  public static func runFmt(context _: PathContext) -> Bool {
    Output.info("fmt: formatting sources in place")
    let formatCommand = Env.words(Env.get("SWIFT_FORMAT", "xcrun swift-format"))
    let config = Env.get("SWIFT_MK_SWIFT_FORMAT_CONFIG", ".make/swift-format.json")
    let targets = Env.words(Env.get("SWIFT_FORMAT_TARGETS", "Sources Tests Package.swift"))
    let arguments =
      Array(formatCommand.dropFirst())
      + ["format", "--in-place", "--recursive", "--configuration", config] + targets
    let result = Shell.run(formatCommand[0], arguments)
    Output.emitStandardOutput(result.combined)
    return result.status == 0
  }

  @discardableResult
  public static func runFormat(context _: PathContext) -> Bool {
    Output.info("lint-format: checking formatting")
    Capture.ensureMakeDir()
    let output = ".make/lint-format.out"
    let formatCommand = Env.words(Env.get("SWIFT_FORMAT", "xcrun swift-format"))
    let config = Env.get("SWIFT_MK_SWIFT_FORMAT_CONFIG", ".make/swift-format.json")
    let lintFiles = Env.get("LINT_FILES")
    let targets =
      lintFiles.isEmpty
      ? Env.words(Env.get("SWIFT_FORMAT_TARGETS", "Sources Tests Package.swift"))
      : Env.words(lintFiles)
    let arguments =
      Array(formatCommand.dropFirst())
      + ["lint", "--strict", "--recursive", "--configuration", config] + targets
    let result = Shell.run(formatCommand[0], arguments, environment: lintEnvironment())
    Capture.write(result.combined, to: output)
    if !result.combined.isEmpty {
      Output.log("lint-format: FAILED")
      Output.log(result.combined)
      Baseline.recordFailedGate("lint-format")
      return false
    }
    if result.status != 0 {
      Output.log("lint-format: FAILED")
      Output.log("  Exit status: \(result.status)")
      Baseline.recordFailedGate("lint-format")
      return false
    }
    return true
  }

  // MARK: preflight

  static func preflightRequirements() -> [Preflight.Requirement] {
    []
  }

  // MARK: generate

  /// Run the consumer's `SWIFT_GENERATE_CMD` once before a compile-based gate, the
  /// same hook `build` runs before `SWIFT_BUILD_CMD`, so a fresh checkout or worktree
  /// has its generated sources (a rendered config, an Xcode project) before deadcode,
  /// log-audit, or test compile the package. Generation is a framework
  /// responsibility, not something each consumer threads into each gate. Guarded by
  /// `SWIFT_MK_GENERATED` so it runs at most once per `make lint`: the flag is set
  /// after a successful run and inherited by the gate sub-makes. On failure the
  /// command's own output is surfaced, so the real cause shows rather than being
  /// masked as a later compile or index-incomplete error. A repo with no
  /// `SWIFT_GENERATE_CMD` is unaffected.
  @discardableResult
  public static func ensureGenerated() -> Bool {
    guard SigningBuildConfig.checkSigningPreflight() else {
      return false
    }
    if Env.get("SWIFT_MK_GENERATED") == "1" {
      return true
    }
    let command = Env.get("SWIFT_GENERATE_CMD")
    guard !command.isEmpty else {
      return true
    }
    Output.info("generate: running SWIFT_GENERATE_CMD before compile-based gate")
    // A dev-tool generate bootstraps the tool's SwiftPM `.build`, so serialize it with
    // every other build in this worktree. Re-entrant, so a nested build is safe.
    let status = BuildLock.withLock {
      Shell.runForwardingOutput("/bin/sh", ["-c", command])
    }
    if status != 0 {
      Output.error("generate: SWIFT_GENERATE_CMD failed status=\(status)")
      return false
    }
    setenv("SWIFT_MK_GENERATED", "1", 1)
    return true
  }

  // MARK: test, audit

  @discardableResult
  public static func runTest(context _: PathContext) -> Bool {
    // Mark the gated invocation so the test compile (and any `toolchain build`
    // it runs) carries the gate proof. `make test` does not route through
    // `build`, so it marks here.
    GateProof.mark()
    guard ensureGenerated() else {
      Output.emitStandardError("test: SWIFT_GENERATE_CMD failed; not compiling\n")
      return false
    }
    let command = Env.get("SWIFT_TEST_CMD")
    guard !command.isEmpty else {
      Output.emitStandardError("test: SWIFT_TEST_CMD is not set\n")
      return false
    }
    let status = BuildLock.withLock {
      Shell.runForwardingOutput("/bin/sh", ["-c", command])
    }
    return status == 0
  }

  @discardableResult
  public static func runLogAudit(context _: PathContext) -> Bool {
    let command = Env.get("SWIFT_LOG_AUDIT_CMD")
    guard !command.isEmpty else { return true }
    guard ensureGenerated() else {
      Output.emitStandardError("log-audit: SWIFT_GENERATE_CMD failed; not compiling\n")
      return false
    }
    let status = BuildLock.withLock {
      Shell.runForwardingOutput("/bin/sh", ["-c", command])
    }
    return status == 0
  }

  @discardableResult
  public static func runAudit(context _: PathContext) -> Bool {
    Output.info("audit: scanning dependencies")
    let scanner = Env.get("OSV_SCANNER", "osv-scanner")
    let root = Env.get("SWIFT_AUDIT_ROOT", ".")
    let configured = Env.words(
      Env.get("OSV_SCANNER_ARGS", "--allow-no-lockfiles"))
    let lockfiles = AuditLockfiles.discover(root: root)
    let args = AuditLockfiles.scannerArguments(configured: configured, lockfiles: lockfiles)
    Output.debug("audit: scanning \(lockfiles.count) git-visible lockfile(s)")
    let result = Shell.run(scanner, args)
    Output.emitStandardOutput(result.combined)
    var ok = result.status == 0
    let extra = Env.get("SWIFT_AUDIT_EXTRA_CMD")
    if !extra.isEmpty {
      let extraResult = Shell.sh(extra)
      Output.emitStandardOutput(extraResult.combined)
      ok = ok && extraResult.status == 0
    }
    return ok
  }

  // MARK: build-tooling audit

  /// Make-side half of the build-tooling ban: fail when the consumer's entry
  /// Makefile invokes `tuist`/`xcodegen`/`xcodebuild` directly instead of routing
  /// through `$(SWIFT_MK_BIN) toolchain`. The swiftcheck `unrouted_build_tooling`
  /// rule stops a Swift dev tool from doing the same; this closes the make side.
  /// Framework-owned and run unconditionally in `lint`, so a consumer cannot drop
  /// it through `LINT_GATES`. Scans the entry Makefile (`SWIFT_MK_ENTRY_MAKEFILE`,
  /// default `Makefile`); a missing file contributes nothing.
  @discardableResult
  public static func runBuildToolingAudit(context _: PathContext) -> Bool {
    let makefile = Env.get("SWIFT_MK_ENTRY_MAKEFILE", "Makefile")
    var findings = BuildToolingAudit.scan(paths: [makefile])
    findings += BuildToolingAudit.scanCodesign(
      paths: BuildToolingAudit.codesignScanPaths(makefile: makefile))
    if findings.isEmpty {
      Output.log("build-tooling-audit: OK")
      return true
    }
    Output.log("build-tooling-audit: FAILED")
    for finding in findings {
      Output.logError(finding.rendered)
    }
    Baseline.recordFailedGate("build-tooling-audit")
    return false
  }

  // MARK: shared quality guard

  /// Shared preflight and build-tooling checks that every required quality job
  /// should run before its gate-specific target. This preserves the old
  /// `build-check` workflow's preflight, generation, and tooling-audit behavior
  /// without collapsing the visible gate list back into one combined job.
  @discardableResult
  public static func runQualityGuard(context: PathContext) -> Bool {
    GateProof.mark(context: context)
    guard SigningBuildConfig.checkSigningPreflight() else {
      Output.log("\n1 check failed: preflight")
      return false
    }
    let preflightResult = Preflight.checkFiles(preflightRequirements())
    guard preflightResult.ok else {
      Output.log("\n1 check failed: preflight")
      return false
    }
    guard Preflight.trustMise(in: ".") else {
      Output.log("\n1 check failed: preflight")
      return false
    }
    guard Preflight.ensureConsumerRequirement() else {
      Output.log("\n1 check failed: preflight")
      return false
    }
    guard ensureGenerated() else {
      Output.log("\n1 check failed: generate")
      return false
    }
    return runBuildToolingAudit(context: context)
  }

  // MARK: gate chain

  @discardableResult
  public static func runLint(context: PathContext) -> Bool {
    Output.info("lint: running gate chain")
    guard runQualityGuard(context: context) else { return false }
    let gates = Env.words(
      Env.get(
        "LINT_GATES",
        "lint-swiftlint lint-format lint-complexity lint-deadcode swiftcheck-extra"))
    let items = gates.map { gate in
      GateItem(name: gate) {
        runGate(named: gate, context: context)
      }
    }
    let failed = GateDisplay.runGates(title: "Lint gates", items: items)
    if failed.isEmpty { return true }

    if bypassActive() {
      Output.log("LINT FINDINGS NON-BLOCKING via BYPASS_LINT")
      return true
    }
    return false
  }

  /// Run one named gate in-process, mapping each canonical gate name to its
  /// in-process function so the whole chain runs in a single process with no
  /// recursive make and no env hand-off, the way go-mk's build-check runs its
  /// gates. A name outside the canonical set falls back to a recursive make
  /// target, so a consumer can still register a custom gate through LINT_GATES.
  static func runGate(named gate: String, context: PathContext) -> Bool {
    Output.debug("lint: running gate \(gate)")
    switch gate {
    case "lint-swiftlint":
      return runSwiftlint(context: context)
    case "lint-format":
      return runFormat(context: context)
    case "lint-complexity":
      return runComplexity(context: context)
    case "lint-deadcode":
      return runDeadcode(context: context)
    case "swiftcheck-extra":
      return Swiftcheck.runGate(context: context)
    default:
      let make = Env.get("SWIFT_MK_RECURSIVE_MAKE", Env.get("MAKE", "make"))
      let makeArgs = Env.words(Env.get("SWIFT_MK_RECURSIVE_MAKE_ARGS"))
      let result = Shell.run(
        make, makeArgs + [gate], environment: ["SWIFT_MK_SKIP_FETCH": "1"])
      Output.emitStandardOutput(result.combined)
      return result.status == 0
    }
  }

  /// Whether the lint bypass is active: BYPASS_LINT holds today's token and
  /// BYPASS_CONFIRM is affirmative. Prints nothing, so the lint chain and the
  /// build-check orchestrator can both consult it. BYPASS_TOKEN_CMD overrides
  /// the native token fetch when set.
  public static func bypassActive() -> Bool {
    TokenGate.passesNative(
      confirmValue: Env.get("BYPASS_CONFIRM"),
      tokenValue: Env.get("BYPASS_LINT"),
      tokenCommandOverride: Env.get("BYPASS_TOKEN_CMD")
    )
  }

  /// Run the full non-test quality gate: the lint chain, then the dependency
  /// audit, then the log audit when SWIFT_LOG_AUDIT_CMD is set. Every step runs
  /// and prints. A valid bypass does not skip any step; it only makes a failed
  /// run non-blocking by returning success at the end. Returns true when every
  /// step passed, or when a valid bypass is active.
  @discardableResult
  public static func runBuildCheck(context: PathContext) -> Bool {
    var passed = runLint(context: context)
    passed = runAudit(context: context) && passed
    if !Env.get("SWIFT_LOG_AUDIT_CMD").isEmpty {
      passed = runLogAudit(context: context) && passed
    }
    if !passed, bypassActive() {
      return true
    }
    return passed
  }

  // MARK: scoped iteration

  /// Serialize diff ranges into the tab-separated form `parseRangesFile` reads.
  static func serializeRanges(_ ranges: [LineRange]) -> [String] {
    ranges.map { "\($0.file)\t\($0.start)\t\($0.end)" }
  }

  @discardableResult
  public static func runLintFiles(context: PathContext) -> Bool {
    var ok = runSwiftlint(context: context)
    ok = runFormat(context: context) && ok
    ok = runComplexity(context: context) && ok
    ok = Swiftcheck.runGate(context: context) && ok
    return ok
  }

  @discardableResult
  public static func runLintDiff(context: PathContext) -> Bool {
    let staged = Shell.sh("git diff --cached --name-only --diff-filter=ACMR -- '*.swift'")
      .stdout
    let files = staged.split(separator: "\n").map(String.init)
    if files.isEmpty { return true }
    Capture.ensureMakeDir()
    let diff = Shell.sh("git diff --cached --unified=0 -- '*.swift'").stdout
    let ranges = Capture.diffRanges(diff)
    let rangesPath = ".make/lint-diff.ranges"
    do {
      try Text.writeLines(serializeRanges(ranges), to: rangesPath)
    } catch {
      Output.error("lint-diff: could not write ranges to \(rangesPath): \(error)")
    }
    setenv("LINT_FILES", files.joined(separator: " "), 1)
    setenv("LINT_LINE_RANGES", rangesPath, 1)
    return runLintFiles(context: context)
  }
}
