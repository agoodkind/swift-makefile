//
//  BuildFreshCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-11.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import Foundation
import SwiftMkCore

// MARK: - BuildFreshCommand

/// `swift-mk build-fresh`: expose the `BuildFreshness` record so a Makefile guard
/// can skip a rebuild when the tracked inputs and the built product are unchanged.
/// `check` carries the fresh verdict in its exit status for a shell `if`; `record`
/// stamps the success record after a build completes.
struct BuildFreshCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "build-fresh",
    abstract: "Check or record build freshness so make build can no-op when nothing changed.",
    subcommands: [BuildFreshCheck.self, BuildFreshRecord.self]
  )
}

// MARK: - BuildFreshCheck

/// Exit 0 when the last recorded build still covers the current inputs and
/// outputs, and nonzero when it does not. A shell `if` consumes this before a
/// build, so the success path stays silent and the verdict rides the exit code.
struct BuildFreshCheck: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract: "Exit 0 when the build is fresh, nonzero when a rebuild is needed."
  )

  @Option(
    name: .customLong("config-key"),
    help: "Opaque config key the freshness record binds to.")
  var configKey: String = ""

  @Option(
    name: .customLong("product"),
    help: "A built product path that must still exist. Repeatable.")
  var productPaths: [String] = []

  func run() throws {
    let fresh = BuildFreshness.isFresh(
      context: .current(), configKey: resolvedConfigKey(configKey), productPaths: productPaths)
    guard fresh else {
      throw ExitCode.failure
    }
    Output.debug("build-fresh: fresh, skipping rebuild")
  }
}

/// Resolve the config key: an explicit `--config-key` wins, otherwise the value
/// the Makefile exports as `SWIFT_MK_FRESH_CONFIG_KEY`. Reading it from the
/// environment lets the make recipe pass the key without shell-quoting a folded
/// value, so a signing identity or command with an apostrophe cannot break the
/// build command.
func resolvedConfigKey(_ flag: String) -> String {
  flag.isEmpty ? Env.get("SWIFT_MK_FRESH_CONFIG_KEY") : flag
}

// MARK: - BuildFreshRecord

/// Stamp the build-freshness record after a build completes, capturing the config
/// key and product paths so a later `check` can decide the build is fresh.
struct BuildFreshRecord: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "record",
    abstract: "Record the successful build so a later check can skip a rebuild."
  )

  @Option(
    name: .customLong("config-key"),
    help: "Opaque config key the freshness record binds to.")
  var configKey: String = ""

  @Option(
    name: .customLong("product"),
    help: "A built product path to record. Repeatable.")
  var productPaths: [String] = []

  func run() {
    BuildFreshness.record(
      context: .current(), configKey: resolvedConfigKey(configKey), productPaths: productPaths)
  }
}
