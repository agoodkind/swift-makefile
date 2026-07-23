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
    let stamped: Request
    do {
      stamped = try versionStamped(request)
    } catch {
      Output.error("toolchain: could not resolve the build version: \(error)")
      return versionResolutionFailureStatus
    }
    return runXcodebuildForwarding(
      stamped, actions: ["build"], environment: signingEnvironment())
  }

  /// The exit status a product build returns when the version cannot be resolved,
  /// so a version problem fails the build rather than shipping an unstamped bundle.
  static let versionResolutionFailureStatus: Int32 = 1

  /// Return a copy of the request with `MARKETING_VERSION` and
  /// `CURRENT_PROJECT_VERSION` injected from the resolved version, so the built
  /// bundle carries a real version on every product build. A key the caller already
  /// supplied with a non-empty value wins and is left untouched, so a release build
  /// that passes the version explicitly, or a consumer that overrides it, is
  /// unaffected; an empty value counts as missing and is stamped. Only the product
  /// build injects the version; test and analyze builds are unchanged. Throws only
  /// when it must inject an overlong build number, so the build fails loudly.
  static func versionStamped(_ request: Request) throws -> Request {
    let present = Set(
      request.extraSettings
        .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .keys.map { $0.uppercased() })
    let missing = Set(VersionMeta.injectableKeys.filter { !present.contains($0) })
    guard !missing.isEmpty else {
      return request
    }
    let injected = try VersionMeta.injectionSettings(forMissing: missing)
    guard !injected.isEmpty else {
      return request
    }
    var settings = request.extraSettings
    for (key, value) in injected {
      settings[key] = value
    }
    return Request(
      generator: request.generator,
      scheme: request.scheme,
      configuration: request.configuration,
      workspace: request.workspace,
      project: request.project,
      destination: request.destination,
      derivedDataPath: request.derivedDataPath,
      extraSettings: settings,
      extraArguments: request.extraArguments)
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
