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

  /// Whether `build` runs the lint gates inline. A local or agent run has no
  /// GitHub Actions environment, so `build` is the unbypassable chokepoint and
  /// runs the gates itself. A CI run (`GITHUB_ACTIONS=true` with a non-empty
  /// `GITHUB_RUN_ID`) runs the gates as its own decoupled job in the reusable
  /// workflow, so `build` skips them and stays a pure compile, with no double
  /// gating. `GITHUB_ACTIONS` without a run id is not a CI run, so gates still fire.
  public static func runsInlineGates(githubActions: String, githubRunId: String) -> Bool {
    !(githubActions == "true" && !githubRunId.isEmpty)
  }

  /// Run the lint gates once, then the configured build command with its output
  /// forwarded live. This is the single place every `make build` gates off-CI, so
  /// the build command and any `toolchain build` it calls stay pure compilers and
  /// never double-gate. On CI the gates run as their own decoupled job, so this
  /// skips them. Returns the gate-failure status when the gates fail off-CI, a
  /// nonzero status when `SWIFT_BUILD_CMD` is unset, or the build command's exit
  /// status.
  public static func gateAndBuild() -> Int32 {
    // Mark this gated invocation before any compile so the configured build
    // command, and any `toolchain build` it calls, carry the gate proof. On CI
    // the inline gates skip, but the proof must still be set so the downstream
    // compile is not refused.
    GateProof.mark()
    guard SigningBuildConfig.checkSigningPreflight() else {
      return missingBuildCommandStatus
    }
    let inlineGates = runsInlineGates(
      githubActions: Env.get("GITHUB_ACTIONS"), githubRunId: Env.get("GITHUB_RUN_ID"))
    if inlineGates {
      if !Lint.runBuildCheck(context: PathContext.current()) {
        return Toolchain.gateFailureStatus
      }
    } else {
      Output.log("build: gates run in the CI gate job; skipping inline gates")
    }
    let command = Env.get("SWIFT_BUILD_CMD")
    guard !command.isEmpty else {
      Output.error("build: SWIFT_BUILD_CMD is not set")
      return missingBuildCommandStatus
    }
    Output.info("build: running configured build command")
    let cacheEnvironment = BuildCache.environment() ?? [:]
    // Serialize against any other build in this worktree (a dev-tool SwiftPM build, the
    // dead-code coverage build) so two builds never share one `.build`/DerivedData and
    // corrupt each other. Re-entrant, so a `toolchain build`/`swiftpm build` child the
    // command spawns inherits this hold instead of deadlocking on it.
    return BuildLock.withLock {
      Shell.runForwardingOutput("/bin/sh", ["-c", command], environment: cacheEnvironment)
    }
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
    return BuildLock.withLock {
      Shell.runForwardingOutput("/bin/sh", ["-c", command], environment: cacheEnvironment)
    }
  }
}
