//
//  GatedBuild.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - GateReceipt

/// Proof that the hard build gate passed, required to drive the in-process product
/// compile.
///
/// The make path proves a gated compile through `GateProof`, a live `make`/`swift-mk`
/// ancestor a dev tool cannot fabricate. A decoupled dev tool that links
/// `SwiftMkCore` and never runs `make` has no such ancestor, so it needs a different
/// proof. A `GateReceipt` is that proof: its initializer is non-public, so a consumer
/// in another module cannot construct one, and `GatedBuild.run` mints exactly one
/// only after `Lint.runHardBuildCheck` passes. `Toolchain.build(_:receipt:)` requires
/// it, so an environment variable or a stamp file cannot forge an authorized compile
/// the way a `GateProof` flag could, since the receipt is a Swift value, not data the
/// API reads.
public struct GateReceipt: Sendable {
  // The synthesized `init()` of this public struct is internal, so a consumer in
  // another module cannot mint a receipt. In production `GatedBuild.run` is the sole
  // minting site, and it mints only after the hard gate passes; the internal access
  // also lets the engine's own tests exercise `Toolchain.build(_:receipt:)`.
}

// MARK: - GatedBuild

/// The fused, decoupled build entry: run swift-mk's full hard lint gate, then run
/// the consumer's compile, in one process, with no `make`, no environment hand-off,
/// and no `swift-mk` subprocess.
///
/// `run` is a closure-based fuse rather than a one-shot `gateThenBuild` because one
/// passed gate must authorize a multi-target build: a consumer compiling a Mac app,
/// a Mac Catalyst app, and a simulator target wraps all of them in one
/// `GatedBuild.run`, and its `compile` closure calls `Toolchain.build(_:receipt:)`
/// once per target with the single minted receipt, so the gate runs once and covers
/// the whole flow.
public enum GatedBuild {
  // MARK: Options

  /// Signing inputs for the build, mirroring `SigningBuildConfig.applyEnvironmentOverride`.
  /// A dev tool that runs `xcodebuild` without the make signing prelude passes its
  /// gitignored local xcconfig here so swift-mk still owns build-time signing.
  public struct SigningOptions: Sendable {
    public let localXcconfigPaths: [String]

    public init(localXcconfigPaths: [String] = []) {
      self.localXcconfigPaths = localXcconfigPaths
    }
  }

  /// The consumer-supplied steps the hard gate runs: project generation before
  /// discovery, the in-process dead-code coverage build, and the log audit. Each is
  /// optional; a SwiftPM consumer that generates nothing and has no log audit
  /// supplies none. The make path reads `SWIFT_GENERATE_CMD`, `SWIFT_LOG_AUDIT_CMD`,
  /// and `SWIFT_DEADCODE_BUILD_CMD` from the environment instead; the decoupled path
  /// has no such environment, so it carries them as typed closures.
  public struct Hooks: Sendable {
    public let generate: (@Sendable () -> Bool)?
    public let deadcodeCoverage: DeadcodeCoverageBuild?
    public let logAudit: (@Sendable () -> Bool)?

    @preconcurrency
    public init(
      generate: (@Sendable () -> Bool)? = nil,
      deadcodeCoverage: DeadcodeCoverageBuild? = nil,
      logAudit: (@Sendable () -> Bool)? = nil
    ) {
      self.generate = generate
      self.deadcodeCoverage = deadcodeCoverage
      self.logAudit = logAudit
    }
  }

  // MARK: Request

  /// One fused build: the hard gate, then `compile`, with the signing options and
  /// hooks the gate needs.
  public struct Request: Sendable {
    public let entry: String
    public let context: PathContext
    public let signing: SigningOptions
    public let hooks: Hooks
    /// The consumer's compile. It receives the minted receipt and may call
    /// `Toolchain.build(_:receipt:)` any number of times (one per target), returning
    /// the first nonzero status or zero when every target built.
    public let compile: @Sendable (GateReceipt) -> Int32

    @preconcurrency
    public init(
      entry: String,
      context: PathContext = .current(),
      signing: SigningOptions = SigningOptions(),
      hooks: Hooks = Hooks(),
      compile: @escaping @Sendable (GateReceipt) -> Int32
    ) {
      self.entry = entry
      self.context = context
      self.signing = signing
      self.hooks = hooks
      self.compile = compile
    }
  }

  // MARK: Run

  /// Materialize the engine-owned configs, run the signing preflight and the hard
  /// gate, and only on success mint a receipt and run the consumer's compile. On a
  /// preflight or gate failure the compile never runs and the gate-failure status is
  /// returned, so a decoupled build that ran around the gate stops nonzero exactly
  /// like `make check` would.
  @discardableResult
  public static func run(_ request: Request) -> Int32 {
    // (1) Write the bundled gate configs into the checkout, so a fresh checkout that
    // never ran `make` has byte-identical configs before the gate reads them.
    LintResources.ensure(context: request.context)
    // (2) Signing preflight: a consumer that requires signing must resolve a team
    // before the compile, the same precondition `make build` enforces.
    guard SigningBuildConfig.checkSigningPreflight() else {
      return Toolchain.gateFailureStatus
    }
    // (3) The fixed hard gate. (4) On failure, skip the compile and stop nonzero.
    guard Lint.runHardBuildCheck(context: request.context, hooks: request.hooks) else {
      return Toolchain.gateFailureStatus
    }
    // (5) Apply the swift-mk signing override so the compile signs through swift-mk
    // even without the make prelude.
    SigningBuildConfig.applyEnvironmentOverride(
      localXcconfigPaths: request.signing.localXcconfigPaths)
    // (6) Mint the receipt only now, after the gate passed, and (7) run the compile.
    let receipt = GateReceipt()
    return request.compile(receipt)
  }
}
