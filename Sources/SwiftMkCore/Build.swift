//
//  Build.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Build

/// The build chokepoint. It runs the lint gates in-process and then runs the
/// consumer's configured build command, so a product build never runs without the
/// gates: `make build` routes here, and there is no separate recipe step that
/// compiles on its own.
public enum Build {
  /// The exit status returned when `SWIFT_BUILD_CMD` is unset, so a misconfigured
  /// consumer fails loudly rather than silently building nothing.
  static let missingBuildCommandStatus: Int32 = 1

  /// Whether `build` runs the lint gates inline. `SWIFT_MK_SKIP_INLINE_GATES=1`
  /// explicitly keeps a caller-owned build step to a pure compile. Otherwise, a
  /// local or agent run has no GitHub Actions environment, so `build` runs the
  /// gates itself. A CI run (`GITHUB_ACTIONS=true` with a non-empty
  /// `GITHUB_RUN_ID`) runs the gates as its own decoupled job in the reusable
  /// workflow, so `build` skips them and stays a pure compile, with no double
  /// gating. `GITHUB_ACTIONS` without a run id is not a CI run, so gates still fire.
  public static func runsInlineGates(
    githubActions: String, githubRunId: String, skipInlineGates: String
  ) -> Bool {
    if skipInlineGates == "1" {
      return false
    }
    return !isGitHubActionsCI(githubActions: githubActions, githubRunId: githubRunId)
  }

  /// A GitHub Actions job sets `GITHUB_ACTIONS=true` and a non-empty
  /// `GITHUB_RUN_ID`. Hosted runners do not set `git config user.name` or
  /// `user.email`. actions/checkout ADR 0153 records that the service provides
  /// no default identity.
  public static func isGitHubActionsCI(githubActions: String, githubRunId: String) -> Bool {
    githubActions == "true" && !githubRunId.isEmpty
  }

  /// Run the lint gates once, then the configured build command with its output
  /// forwarded live. This is the single place every `make build` gates off-CI, so
  /// the build command and any `toolchain build` it calls stay pure compilers and
  /// never double-gate. On CI the gates run as their own decoupled job, so this
  /// skips them. Returns the gate-failure status when the gates fail off-CI, a
  /// nonzero status when `SWIFT_BUILD_CMD` is unset, or the build command's exit
  /// status.
  ///
  /// `command` names the command to build instead of reading the consumer's configured
  /// one, which is how `release-build` runs a release command through the same gated
  /// entry. It is an argument rather than an environment variable because `swift.mk`
  /// exports `SWIFT_BUILD_CMD` and defines it with `?=`: an inherited value wins over
  /// that default, so a release command that recurses into make would have the nested
  /// make read the release command back as its build command and re-enter this entry.
  /// A stickies release recursed 256 levels deep that way and died when the runner ran
  /// out of processes.
  public static func gateAndBuild(command: String? = nil) -> Int32 {
    // Mark this gated invocation before any compile so the configured build
    // command, and any `toolchain build` it calls, carry the gate proof. On CI
    // the inline gates skip, but the proof must still be set so the downstream
    // compile is not refused.
    GateProof.mark()
    guard SigningBuildConfig.checkSigningPreflight() else {
      return missingBuildCommandStatus
    }
    let inlineGates = runsInlineGates(
      githubActions: Env.get("GITHUB_ACTIONS"),
      githubRunId: Env.get("GITHUB_RUN_ID"),
      skipInlineGates: Env.get("SWIFT_MK_SKIP_INLINE_GATES"))
    if inlineGates {
      if !Lint.runBuildCheck(context: PathContext.current()) {
        return Toolchain.gateFailureStatus
      }
    } else {
      Output.log("build: inline gates disabled; skipping inline gates")
    }
    let configured = resolvedBuildCommand(command)
    guard !configured.isEmpty else {
      Output.error("build: SWIFT_BUILD_CMD is not set")
      return missingBuildCommandStatus
    }
    let resolved = withSwiftPMCompileCache(configured)
    Output.info("build: running configured build command")
    let cacheEnvironment = BuildCache.environment() ?? [:]
    // Serialize against any other build in this worktree (a dev-tool SwiftPM build, the
    // dead-code coverage build) so two builds never share one `.build`/DerivedData and
    // corrupt each other. Re-entrant, so a `toolchain build`/`swiftpm build` child the
    // command spawns inherits this hold instead of deadlocking on it.
    return BuildLock.withLock {
      Shell.runForwardingOutput("/bin/sh", ["-c", resolved], environment: cacheEnvironment)
    }
  }

  /// The command to build: the one passed in when there is one, else the consumer's
  /// configured `SWIFT_BUILD_CMD`. A passed command is never written back into the
  /// environment, which is what keeps a release command out of a nested make's reach.
  static func resolvedBuildCommand(_ passed: String?) -> String {
    if let passed, !passed.isEmpty {
      return passed
    }
    return Env.get("SWIFT_BUILD_CMD")
  }

  /// Run a compile command under the gate proof: refuse loud when this process is
  /// not inside a swift-mk gated invocation, else run the command with its output
  /// forwarded. This is the single engine compile entry a Swift dev tool calls
  /// instead of a raw `swift build`, so a SwiftPM product (which the xcodebuild
  /// `Toolchain` chokepoint does not cover) has no ungated leaf to invoke
  /// directly. `entry` names the dev-tool subcommand for the refusal message.
  public static func gatedCompile(_ command: String, entry: String) -> Int32 {
    if let refusal = GateProof.refusal(entry: entry) {
      return refusal
    }
    let cacheEnvironment = BuildCache.environment() ?? [:]
    let cached = withSwiftPMCompileCache(command)
    return BuildLock.withLock {
      Shell.runForwardingOutput("/bin/sh", ["-c", cached], environment: cacheEnvironment)
    }
  }

  /// The configured command with the SwiftPM compilation-cache flags appended when it
  /// is one bare `swift build` or `swift test`, else unchanged.
  ///
  /// A command routed through the engine (`swift-mk toolchain swiftpm build`, the
  /// default) already receives these flags inside `SwiftPM.runSwift`, as an argv array.
  /// A consumer that writes the invocation itself, which the build-tooling audit allows
  /// in a make variable, was reaching the compiler with no `-cas-path` at all, so its
  /// content-addressed store stayed empty, nothing was ever saved to the CI compile
  /// bucket, and every run compiled cold. Appending here is what makes the engine own
  /// the cache for both command shapes rather than only the routed one. It also keeps
  /// every engine-mediated compile in one module mode: `-explicit-module-build` and
  /// plain builds sharing one `.build` poison each other's clang module records, which
  /// is why the dead-code scan already forwards these same flags.
  ///
  /// The rewrite is deliberately narrow:
  /// - `swift run` is never rewritten. Its arguments after the product name belong to
  ///   the consumer's tool, so an append would hand the flags to that tool.
  /// - A command carrying any shell operator is never rewritten, because the append
  ///   target is not determinable from here.
  /// - A command already naming `-cas-path` is never rewritten, so an explicit consumer
  ///   choice is not doubled.
  static func withSwiftPMCompileCache(
    _ command: String,
    flags: [String] = SwiftPM.compileCacheArguments()
  ) -> String {
    guard !flags.isEmpty else {
      return command
    }
    guard isBareSwiftCompile(command) else {
      Output.debug(
        "build: leaving the configured command unchanged; it is not a single bare "
          + "`swift build`/`swift test`, so route it through `swift-mk toolchain "
          + "swiftpm` to get the compilation cache")
      return command
    }
    if command.contains("-cas-path") {
      return command
    }
    // The command string runs through `/bin/sh -c`, so each appended flag is
    // single-quoted; the CAS path under the user's home may contain characters the
    // shell would otherwise split or expand.
    return ([command] + flags.map(shellQuoted)).joined(separator: " ")
  }

  /// Whether the command is one `swift build` or `swift test` with no shell operator,
  /// so appended arguments land on that invocation, and on nothing else, as options
  /// swift itself parses.
  static func isBareSwiftCompile(_ command: String) -> Bool {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let appendableSubcommands = ["build", "test"]
    let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    // The executable word and the subcommand word.
    let minimumInvocationWords = 2
    guard words.count >= minimumInvocationWords, words[0] == "swift",
      appendableSubcommands.contains(words[1])
    else {
      return false
    }
    // Any shell operator means more than one command, a redirection, or a substitution
    // whose text is not known here, so the append target is not determinable.
    let shellOperators = ["&&", "||", ";", "|", "&", "`", "$(", ">", "<", "\n"]
    return !shellOperators.contains { trimmed.contains($0) }
  }

  /// The argument wrapped in single quotes for `/bin/sh -c`, with embedded single
  /// quotes escaped by the standard close-escape-reopen sequence.
  static func shellQuoted(_ argument: String) -> String {
    "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
