//
//  GateProofCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-14.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import Foundation
import SwiftMkCore

// MARK: - GateProofCommand

/// Prove a compile runs inside the swift-mk lint gate. `check` is the guard a
/// shell caller invokes before compiling; `probe` and `selftest` verify the
/// cross-process mechanism.
struct GateProofCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "gate-proof",
    abstract: "Prove a compile runs inside the swift-mk lint gate.",
    subcommands: [GateProofCheck.self, GateProofProbe.self, GateProofSelftest.self]
  )
}

// MARK: - GateProofCheck

/// Refuse with a loud message and a nonzero status when this process is not
/// inside a swift-mk gated invocation. A shell-side compile leaf runs this first.
struct GateProofCheck: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "check")

  @Option(name: .customLong("entry"), help: "Name of the compile entry being guarded.")
  var entry: String = "compile"

  func run() throws {
    if let status = GateProof.refusal(entry: entry) {
      throw ExitCode(status)
    }
  }
}

// MARK: - GateProofProbe

/// Print the proof verdict for this process, naming each factor. A child the
/// self-test spawns, so the parent gate can confirm the proof crosses a process
/// boundary. Hidden: a diagnostic, not a workflow command.
struct GateProofProbe: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "probe", shouldDisplay: false)

  func run() {
    Output.log(GateProof.probeReport())
  }
}

// MARK: - GateProofSelftest

/// Mark this process as a gate, spawn the same binary running `gate-proof probe`,
/// and report whether the child saw the proof. Exits nonzero when the child does
/// not, so the mechanism is verifiable in CI without a full consumer build.
struct GateProofSelftest: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "selftest", shouldDisplay: false)

  func run() throws {
    let report = GateProof.selftest()
    Output.log(report)
    if !report.hasPrefix("gated=true") {
      throw ExitCode(1)
    }
  }
}
