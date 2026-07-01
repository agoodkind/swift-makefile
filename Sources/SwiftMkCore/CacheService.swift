//
//  CacheService.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-24.
//  Copyright © 2026, all rights reserved.
//
//  The CLI-facing cache service: resolve the plan and paths from the environment,
//  emit the GitHub Actions cache plan, and manage the local caches. The pure key,
//  path, and output logic lives in CachePlan / CachePaths / CacheOutput; this layer
//  is the thin glue that probes versions, reads env, and touches the filesystem.
//

import Foundation

// MARK: - CacheOutput

/// Format a resolved plan and path set as a GitHub Actions step-output block. Pure,
/// so the exact `actions/cache` wire format is unit-tested. Multiline values use a
/// heredoc delimiter, the format `actions/cache` reads for list inputs.
public enum CacheOutput {
  public static func githubOutput(
    plan: CachePlan.Result, paths: CachePaths.Resolved
  ) -> String {
    // The compile-cache step passes these paths to `actions/cache`, which fails on an
    // empty path list. Both CAS stores can resolve to nil (both set to an off-token), so
    // report the compile cache enabled only when the policy allows it AND a path exists.
    let compileEnabled = plan.compileCacheEnabled && !paths.compile.isEmpty
    var lines: [String] = [
      "dependency-cache-enabled=\(plan.dependencyCacheEnabled)",
      "build-cache-enabled=\(plan.buildCacheEnabled)",
      "compile-cache-enabled=\(compileEnabled)",
      "dependency-key=\(plan.dependencyKey)",
    ]
    lines.append(
      contentsOf: heredoc("dependency-restore-keys", "CACHE_KEYS", plan.dependencyRestoreKeys))
    lines.append("build-key=\(plan.buildKey)")
    lines.append(contentsOf: heredoc("build-restore-keys", "CACHE_KEYS", plan.buildRestoreKeys))
    lines.append("compile-key=\(plan.compileKey)")
    lines.append(contentsOf: heredoc("compile-restore-keys", "CACHE_KEYS", plan.compileRestoreKeys))
    lines.append(contentsOf: heredoc("dependency-paths", "CACHE_PATHS", paths.dependency))
    lines.append(contentsOf: heredoc("build-paths", "CACHE_PATHS", paths.build))
    lines.append(contentsOf: heredoc("compile-paths", "CACHE_PATHS", paths.compile))
    return lines.joined(separator: "\n") + "\n"
  }

  private static func heredoc(_ name: String, _ base: String, _ values: [String]) -> [String] {
    // A GitHub heredoc block ends at the first line equal to the delimiter. A value
    // (notably a line from EXTRA_CACHE_PATHS) that equals the base delimiter would end
    // the block early and corrupt the parsed outputs, so extend the delimiter until no
    // value line matches it.
    var delimiter = base
    while values.contains(delimiter) {
      delimiter += "_EOF"
    }
    var out = ["\(name)<<\(delimiter)"]
    out.append(contentsOf: values)
    out.append(delimiter)
    return out
  }
}

// MARK: - CacheService

public enum CacheService {
  /// Exit code for a usage error (missing GITHUB_OUTPUT or unknown profile),
  /// matching the former cache-plan.sh exit-2 behavior.
  static let usageExitCode: Int32 = 2

  /// `cache plan`: resolve the plan from the environment and append it to
  /// `$GITHUB_OUTPUT`.
  public static func runPlan() -> Int32 {
    let outputPath = Env.get("GITHUB_OUTPUT")
    if outputPath.isEmpty {
      Output.error("cache plan: GITHUB_OUTPUT is not set")
      return usageExitCode
    }
    let plan: CachePlan.Result
    do {
      plan = try CachePlan.compute(planInputs())
    } catch {
      Output.error("cache plan: \(error)")
      return usageExitCode
    }
    let text = CacheOutput.githubOutput(plan: plan, paths: resolvedPaths())
    Output.info("cache plan: appending plan to \(outputPath)")
    do {
      try appendToFile(path: outputPath, text: text)
    } catch {
      Output.error("cache plan: could not write \(outputPath): \(error)")
      return usageExitCode
    }
    return 0
  }

  /// `cache paths`: print the resolved cacheable directories, grouped by bucket.
  public static func runPaths() -> Int32 {
    Output.info("cache paths: resolving cacheable directories")
    let paths = resolvedPaths()
    Output.log("dependency:")
    for path in paths.dependency {
      Output.log("  \(path)")
    }
    Output.log("build:")
    for path in paths.build {
      Output.log("  \(path)")
    }
    Output.log("compile:")
    for path in paths.compile {
      Output.log("  \(path)")
    }
    return 0
  }

  /// `cache info`: print each cache directory with whether it exists and its size.
  public static func runInfo() -> Int32 {
    Output.info("cache info: inspecting cache directories")
    let paths = resolvedPaths()
    for path in paths.dependency + paths.build + paths.compile {
      let absolute = absolutePath(path)
      if FileManager.default.fileExists(atPath: absolute) {
        Output.log("present  \(directorySize(absolute))\t\(path)")
      } else {
        Output.log("absent   \t\(path)")
      }
    }
    return 0
  }

  /// `cache clean`: remove the local cache directories. A path is removed only when
  /// it sits inside $HOME or the workspace, so a misconfigured `EXTRA_CACHE_PATHS`
  /// (an absolute path elsewhere, or `/`) cannot make clean delete arbitrary
  /// directories.
  public static func runClean() -> Int32 {
    Output.info("cache clean: removing local cache directories")
    let paths = resolvedPaths()
    var removed = 0
    for path in paths.dependency + paths.build + paths.compile {
      let absolute = absolutePath(path)
      guard isWithinSafeRoots(absolute) else {
        Output.error("cache clean: refusing to remove path outside HOME or the workspace: \(path)")
        continue
      }
      guard FileManager.default.fileExists(atPath: absolute) else {
        continue
      }
      do {
        try FileManager.default.removeItem(atPath: absolute)
        removed += 1
        Output.log("removed \(path)")
      } catch {
        Output.error("cache clean: could not remove \(path): \(error)")
      }
    }
    Output.log("cache clean: removed \(removed) director\(removed == 1 ? "y" : "ies")")
    return 0
  }

  /// The known cache directories `cache clean` is allowed to remove. An allowlist,
  /// not a broad "anything under $HOME or the workspace" check, so a misconfigured
  /// `EXTRA_CACHE_PATHS` (for example `.`, `..`, or a sibling repo) can never make
  /// clean delete the workspace root, $HOME, or an unrelated tree.
  static func cleanableRoots() -> [String] {
    let home = Env.get("HOME", FileManager.default.homeDirectoryForCurrentUser.path)
    let cwd = FileManager.default.currentDirectoryPath
    var roots = [
      "\(home)/Library/Caches/swift-mk",
      "\(home)/Library/Caches/org.swift.swiftpm",
      "\(home)/Library/Caches/ccache",
      "\(home)/Library/Caches/Mozilla.sccache",
      "\(home)/.cache/tuist",
      "\(home)/.cache/sccache",
      "\(home)/.local/share/mise",
      "\(cwd)/.build",
      "\(cwd)/.make",
      "\(cwd)/Tools/.build",
      "\(cwd)/swiftcheck/.build",
      "\(cwd)/Tuist/.build",
    ]
    // The DerivedData path is consumer-configurable (SWIFT_MK_DERIVED_DATA), so add it
    // only when it sits strictly under $HOME or the workspace. A custom path elsewhere
    // (or one normalizing via `..`) must not become cleanable and break the safety
    // boundary the allowlist exists to hold.
    if let derived = boundedDerivedDataRoot(
      Toolchain.resolvedDerivedDataPath(), home: home, cwd: cwd)
    {
      roots.append(derived)
    }
    return roots
  }

  /// The resolved DerivedData path, but only when it lies strictly under $HOME or the
  /// workspace; nil otherwise. Pure, so the boundary is unit-tested without mutating
  /// the environment.
  static func boundedDerivedDataRoot(_ derivedPath: String, home: String, cwd: String) -> String? {
    let derived = (derivedPath as NSString).standardizingPath
    for boundary in [home, cwd] where !boundary.isEmpty {
      let normalizedBoundary = (boundary as NSString).standardizingPath
      if derived.hasPrefix(normalizedBoundary + "/") {
        return derived
      }
    }
    return nil
  }

  /// Whether an absolute path is safe for `cache clean` to remove: it must equal or
  /// sit strictly inside one of the known cache roots, and never be the filesystem
  /// root, $HOME, or the workspace itself.
  static func isWithinSafeRoots(_ absolute: String) -> Bool {
    let normalized = (absolute as NSString).standardizingPath
    if normalized.isEmpty || normalized == "/" {
      return false
    }
    for root in cleanableRoots() where !root.isEmpty {
      let normalizedRoot = (root as NSString).standardizingPath
      if normalized == normalizedRoot || normalized.hasPrefix(normalizedRoot + "/") {
        return true
      }
    }
    return false
  }

  // MARK: - Resolution

  static func planInputs() -> CachePlan.Inputs {
    let writer = Env.get("SWIFT_MK_CI_GATE")
    return CachePlan.Inputs(
      profile: Env.get("CACHE_PROFILE", "safe"),
      version: Env.get("CACHE_VERSION", "v1"),
      dependencyHash: Env.get("DEPENDENCY_HASH"),
      buildHash: Env.get("BUILD_HASH"),
      runnerOS: Env.get("RUNNER_OS", probe("uname", ["-s"], fallback: "unknown-os")),
      runnerArch: Env.get("RUNNER_ARCH", probe("uname", ["-m"], fallback: "unknown-arch")),
      xcodeVersion: Toolchain.xcodeVersionString(),
      swiftVersion: Toolchain.swiftVersionString(),
      weeklyEpoch: probe("date", ["-u", "+%Yw%U"], fallback: "0000w00"),
      compileWriter: writer,
      compileRunUnique: compileRunUnique(),
      isCompileWriter: isCompileWriterGate(writer))
  }

  /// The gates that actually compile the package and therefore own the compile cache:
  /// the build, test, and dead-code gates. A consumer with a bespoke compiling
  /// extra-target sets `SWIFT_MK_COMPILE_CACHE_WRITE=1` to opt that gate in; `0`/`off`
  /// opts a gate out.
  static func isCompileWriterGate(_ gate: String) -> Bool {
    let override = Env.get("SWIFT_MK_COMPILE_CACHE_WRITE").lowercased()
    if ["1", "true", "yes", "on"].contains(override) {
      return true
    }
    if ["0", "false", "no", "off"].contains(override) {
      return false
    }
    return ["build", "test", "lint-deadcode", "deadcode"].contains(gate)
  }

  /// A value unique to this run attempt, so each compile-cache save lands under a fresh
  /// name. In CI it is the run id and attempt; locally it falls back to the wall clock,
  /// which never matters because local builds use the live cache directory, not the
  /// rolling CI cache.
  static func compileRunUnique() -> String {
    let runId = Env.get("GITHUB_RUN_ID")
    if !runId.isEmpty {
      let attempt = Env.get("GITHUB_RUN_ATTEMPT", "1")
      return "\(runId)-\(attempt)"
    }
    return probe("date", ["+%s"], fallback: "0")
  }

  static func resolvedPaths() -> CachePaths.Resolved {
    // Honor $HOME (what the former shell used and what CI sets), falling back to the
    // account home only when it is unset.
    let home = Env.get("HOME", FileManager.default.homeDirectoryForCurrentUser.path)
    let inputs = CachePaths.Inputs(
      home: home,
      derivedDataPath: Toolchain.resolvedDerivedDataPath(),
      spmCachePath: Toolchain.resolvedSharedCachePath(
        "SWIFT_MK_SPM_CACHE", defaultSubdirectory: "SourcePackages"),
      moduleCachePath: Toolchain.resolvedSharedCachePath(
        "SWIFT_MK_MODULE_CACHE", defaultSubdirectory: "ModuleCache"),
      xcodeCachePath: Toolchain.resolvedSharedCachePath(
        "SWIFT_MK_XCODE_CACHE_PATH", defaultSubdirectory: "CompilationCache"),
      swiftpmCachePath: Toolchain.resolvedSharedCachePath(
        "SWIFT_MK_SWIFTPM_CACHE_PATH", defaultSubdirectory: "SwiftPMCompilationCache"),
      extraPaths: extraCachePaths())
    return CachePaths.resolve(inputs)
  }

  /// Split EXTRA_CACHE_PATHS on newlines, dropping blank lines, matching how the
  /// former shell appended a newline-separated value.
  static func extraCachePaths() -> [String] {
    Env.get("EXTRA_CACHE_PATHS")
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// Append text to a file, creating it when absent. Reads and rewrites atomically
  /// so a partial write never corrupts `$GITHUB_OUTPUT`.
  static func appendToFile(path: String, text: String) throws {
    Output.debug("cache: appending to \(path)")
    let existing: String
    if FileManager.default.fileExists(atPath: path) {
      existing = try String(contentsOfFile: path, encoding: .utf8)
    } else {
      existing = ""
    }
    try (existing + text).write(toFile: path, atomically: true, encoding: .utf8)
  }

  /// Run a probe command and return its trimmed stdout, or the fallback when the
  /// command fails or prints nothing. Trailing whitespace is stripped to match how
  /// shell `$(...)` command substitution drops trailing newlines.
  static func probe(_ command: String, _ arguments: [String], fallback: String) -> String {
    Output.debug("cache: probing \(command)")
    let result = Shell.run(command, arguments)
    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.status != 0 || trimmed.isEmpty {
      return fallback
    }
    return trimmed
  }

  static func absolutePath(_ path: String) -> String {
    if (path as NSString).isAbsolutePath {
      return path
    }
    let cwd = FileManager.default.currentDirectoryPath
    return (cwd as NSString).appendingPathComponent(path)
  }

  static func directorySize(_ path: String) -> String {
    Output.debug("cache: sizing \(path)")
    let result = Shell.run("du", ["-sh", path])
    let field = result.stdout.split { $0 == "\t" || $0 == " " }.first
    return field.map(String.init) ?? "?"
  }
}
