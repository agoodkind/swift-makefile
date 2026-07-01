//
//  ToolchainReceiptTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ToolchainReceiptTests

/// The receipt-authorized compile overload skips the make-anchored `GateProof`
/// and still rejects forbidden signing settings.
enum ToolchainReceiptTests {}

@Test
func toolchainBuildWithReceiptSkipsGateProofAndStillRejectsSigning() {
  // The receipt overload is the in-process product path: it skips the make-anchored
  // GateProof check, so even with no gate ancestor it reaches the signing rejection
  // (64) rather than the gate-proof refusal (70). The receipt's presence is the
  // proof; here a test mints one through the module-internal initializer.
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "App",
    workspace: "App.xcworkspace",
    extraSettings: ["CODE_SIGN_IDENTITY": "Developer ID Application"]
  )
  #expect(
    Toolchain.build(request, receipt: GateReceipt())
      == Toolchain.signingOverrideRejectionStatus)
}
