//
//  Toolchain+GatedCompile.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Toolchain gated compile

/// The capability-authorized compile surfaces and the shared raw xcodebuild
/// invocation. These live alongside the make-path `Toolchain` methods but in their
/// own file so the chokepoint type stays readable, while every compile still funnels
/// through one module-internal `xcodebuild` site.
extension Toolchain {
  // MARK: Product build by receipt

  /// Build the scheme for the in-process API path, authorized by a `GateReceipt`
  /// rather than the make-anchored `GateProof`. `GatedBuild.run` mints the receipt
  /// only after `Lint.runHardBuildCheck` passes, and the receipt's initializer is
  /// non-public, so a consumer cannot forge one; the receipt's presence here is the
  /// proof, so this path skips the `GateProof` ancestry check that the make path
  /// keeps. The compile body is shared with the make path so both assemble the same
  /// xcodebuild invocation and reject the same forbidden signing settings.
  @discardableResult
  public static func build(_ request: Request, receipt: GateReceipt) -> Int32 {
    _ = receipt
    return buildWithoutGateCheck(request)
  }

  /// The shared product-build body: reject a forbidden signing setting, then run
  /// the build with the swift-mk signing override. The single module-internal site
  /// that runs the product compile, so the `GateProof` make path and the
  /// `GateReceipt` API path stay byte-identical except for how each is authorized.
  ///
  /// The make-path `build(_:)` rejects a forbidden signing setting before its gate
  /// check, so it passes `signingAlreadyRejected: true` to skip the re-scan here. The
  /// receipt path calls this directly with the default, so it still rejects the
  /// forbidden setting. Either way the settings are scanned exactly once per build.
  static func buildWithoutGateCheck(
    _ request: Request, signingAlreadyRejected: Bool = false
  ) -> Int32 {
    Output.debug("toolchain: product build scheme=\(request.scheme)")
    if !signingAlreadyRejected, let rejection = rejectionForSigningOverride(request) {
      return rejection
    }
    return runXcodebuildForwarding(
      request, actions: ["build"], environment: signingEnvironment())
  }

  // MARK: Coverage build by authorization

  /// Build-for-testing the scheme for the in-process dead-code coverage path,
  /// authorized by a `DeadcodeCoverageAuthorization` rather than the make-anchored
  /// `GateProof`. The gate mints the authorization only inside the running dead-code
  /// gate, and its initializer is non-public, so a consumer cannot reach this path
  /// without the gate running; the authorization's presence is the proof, so this
  /// skips the `GateProof` ancestry check. `environment` carries the
  /// `DeadcodeBuildConfig` signing-disabled xcconfig and the result-bundle
  /// directory, which is why the coverage build needs an environment parameter the
  /// make path supplies through the subprocess env.
  @discardableResult
  public static func buildForTesting(
    _ request: Request,
    authorization: DeadcodeCoverageAuthorization,
    environment: [String: String]
  ) -> Int32 {
    _ = authorization
    Output.debug("toolchain: coverage build-for-testing scheme=\(request.scheme)")
    if let rejection = rejectionForSigningOverride(request) {
      return rejection
    }
    return runXcodebuildForwarding(
      request, actions: ["build-for-testing"], environment: environment)
  }

  /// Build-for-testing the in-process coverage build capturing its combined output
  /// while streaming stderr live, so the dead-code gate's fail-hard path has the
  /// transcript to save and the xcresult to diagnose when the coverage build fails.
  /// The make path captures the same output through its subprocess pipe; this is the
  /// captured variant the decoupled callback uses.
  public static func buildForTestingCapturingOutput(
    _ request: Request,
    authorization: DeadcodeCoverageAuthorization,
    environment: [String: String]
  ) -> Shell.StreamingResult {
    _ = authorization
    Output.debug("toolchain: captured coverage build-for-testing scheme=\(request.scheme)")
    if rejectionForSigningOverride(request) != nil {
      return Shell.StreamingResult(
        status: signingOverrideRejectionStatus, stdout: "", timedOut: false)
    }
    return runXcodebuildCapturing(
      request, actions: ["build-for-testing"], environment: environment)
  }

  // MARK: Static analysis

  /// Static-analyze the scheme with xcodebuild against the explicit container,
  /// applying the signing override like `build` so the analyze build signs the same
  /// way a real build would. It is a make-path compile surface authorized by
  /// `GateProof`, so it refuses unless this process is inside a swift-mk gated make
  /// flow. It lives here, next to the shared xcodebuild forwarding, to keep the
  /// `Toolchain` file within the module's file-size limit.
  @discardableResult
  public static func analyze(_ request: Request) -> Int32 {
    // Reject a forbidden signing setting before the gate check, like `build`, so a
    // caller error in the request returns the same status whether or not this process
    // is gated.
    if let rejection = rejectionForSigningOverride(request) {
      return rejection
    }
    if let refusal = GateProof.refusal(entry: "toolchain analyze") {
      return refusal
    }
    return runXcodebuildForwarding(
      request, actions: ["analyze"], environment: signingEnvironment())
  }
}
