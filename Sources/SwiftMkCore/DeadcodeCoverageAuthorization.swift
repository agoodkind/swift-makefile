//
//  DeadcodeCoverageAuthorization.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - DeadcodeCoverageAuthorization

/// A capability that authorizes the dead-code coverage compile, and nothing else.
///
/// The coverage build must reach a compile from inside the dead-code gate, before
/// any product `GateReceipt` exists, so a product receipt cannot authorize it. This
/// scoped capability does instead: its initializer is module-internal, so a
/// consumer linking `SwiftMkCore` cannot construct one, and swift-mk mints it only
/// inside the running dead-code gate, immediately before it invokes the consumer's
/// coverage callback. A consumer's callback receives the value and passes it to
/// `Toolchain.buildForTesting(_:authorization:environment:)`; once the gate returns,
/// the value is out of scope, so a captured copy cannot drive a later compile.
public struct DeadcodeCoverageAuthorization: Sendable {
  // The synthesized `init()` of this public struct is internal, so only swift-mk's
  // dead-code gate (in this module) can mint it; a consumer in another module cannot
  // construct one, which is what keeps the coverage compile from being a bypass.
}

// MARK: - DeadcodeCoverageResult

/// The outcome of a consumer's in-process coverage build: the exit status of the
/// build, and its captured combined output. The captured output feeds the
/// gate's fail-hard transcript when the coverage build fails, so the structured
/// xcresult diagnosis and the saved build log still work without a subprocess.
public struct DeadcodeCoverageResult: Sendable {
  public let status: Int32
  public let output: String

  public init(status: Int32, output: String) {
    self.status = status
    self.output = output
  }
}

// MARK: - DeadcodeCoverageBuild

/// A consumer's in-process coverage build. The dead-code gate mints a
/// `DeadcodeCoverageAuthorization`, computes the signing-disabled coverage
/// environment (the `DeadcodeBuildConfig` xcconfig plus the result-bundle
/// directory), and hands both to this callback, which runs one or more
/// `Toolchain.buildForTesting(_:authorization:environment:)` calls covering its
/// target matrix and returns the combined status and captured output. The make
/// path keeps its `SWIFT_DEADCODE_BUILD_CMD` subprocess and supplies no callback.
public typealias DeadcodeCoverageBuild =
  @Sendable (DeadcodeCoverageAuthorization, [String: String]) -> DeadcodeCoverageResult
