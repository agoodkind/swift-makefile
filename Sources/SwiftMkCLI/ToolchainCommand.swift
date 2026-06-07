//
//  ToolchainCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import Foundation
import SwiftMkCore

// MARK: - ToolchainCommand

/// `swift-mk toolchain <op>`: the only CLI surface that spawns tuist, xcodegen, or
/// xcodebuild. Make consumers route generate/install/build/test through here so no
/// consumer Makefile names the build toolchain directly.
struct ToolchainCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "toolchain",
    abstract: "Drive the Xcode build toolchain (tuist/xcodegen/xcodebuild).",
    subcommands: [
      ToolchainGenerate.self, ToolchainInstall.self, ToolchainBuild.self,
      ToolchainBuildForTesting.self, ToolchainTest.self, ToolchainVersion.self,
    ]
  )
}

private func resolveGenerator(_ raw: String) throws -> Toolchain.Generator {
  guard let value = Toolchain.Generator(rawValue: raw) else {
    throw ValidationError("unknown generator '\(raw)'; use tuist or xcodegen")
  }
  return value
}

private func toolchainExit(_ status: Int32) throws {
  if status != 0 { throw ExitCode(status) }
}

// MARK: - ToolchainRequestOptions

/// Shared options for build and test. `--project` is required for xcodegen; the
/// tuist path drives its own workspace and needs only the scheme.
struct ToolchainRequestOptions: ParsableArguments {
  @Option(name: .long, help: "Project generator: tuist or xcodegen.")
  var generator: String = "tuist"

  @Option(name: .long, help: "Scheme to build or test.")
  var scheme: String

  @Option(name: .long, help: "Build configuration.")
  var configuration: String = "Debug"

  @Option(name: .long, help: "Path to the .xcworkspace (required for tuist build).")
  var workspace: String?

  @Option(name: .long, help: "Path to the .xcodeproj (required for xcodegen).")
  var project: String?

  @Option(name: .long, help: "xcodebuild -destination value.")
  var destination: String?

  @Option(name: .customLong("derived-data-path"), help: "xcodebuild -derivedDataPath value.")
  var derivedDataPath: String?

  @Argument(help: "Extra KEY=value build settings.")
  var settings: [String] = []

  func request() throws -> Toolchain.Request {
    let resolvedGenerator = try resolveGenerator(generator)
    if resolvedGenerator == .xcodegen, project == nil {
      throw ValidationError("xcodegen requires --project")
    }
    var extra: [String: String] = [:]
    for pair in settings {
      guard let equals = pair.firstIndex(of: "=") else {
        throw ValidationError("build setting '\(pair)' must be KEY=value")
      }
      extra[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
    }
    let request = Toolchain.Request(
      generator: resolvedGenerator,
      scheme: scheme,
      configuration: configuration,
      workspace: workspace,
      project: project,
      destination: destination,
      derivedDataPath: derivedDataPath,
      extraSettings: extra
    )
    if let key = Toolchain.forbiddenSigningSetting(in: request) {
      throw ValidationError(
        "build setting '\(key)' is forbidden; swift-mk owns code signing via "
          + "XCODE_XCCONFIG_FILE and a command-line setting would beat it. Remove it "
          + "and set the identity and team through the swift-mk signing source.")
    }
    return request
  }
}

// MARK: - ToolchainGenerate

struct ToolchainGenerate: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "generate")
  @Option(name: .long) var generator: String = "tuist"

  func run() throws { try toolchainExit(Toolchain.generate(resolveGenerator(generator))) }
}

// MARK: - ToolchainInstall

struct ToolchainInstall: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install")
  @Option(name: .long) var generator: String = "tuist"

  func run() throws {
    try toolchainExit(Toolchain.installDependencies(resolveGenerator(generator)))
  }
}

// MARK: - ToolchainBuild

struct ToolchainBuild: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "build")
  @OptionGroup var options: ToolchainRequestOptions

  func run() throws { try toolchainExit(Toolchain.build(options.request())) }
}

// MARK: - ToolchainBuildForTesting

struct ToolchainBuildForTesting: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "build-for-testing")
  @OptionGroup var options: ToolchainRequestOptions

  func run() throws { try toolchainExit(Toolchain.buildForTesting(options.request())) }
}

// MARK: - ToolchainTest

struct ToolchainTest: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "test")
  @OptionGroup var options: ToolchainRequestOptions

  func run() throws { try toolchainExit(Toolchain.test(options.request())) }
}

// MARK: - ToolchainVersion

struct ToolchainVersion: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "version")

  func run() { Output.log(Toolchain.version()) }
}

// MARK: - BuildToolingAuditCommand

/// `swift-mk build-tooling-audit [paths...]`: the make-side half of the build-tooling
/// ban. Fails when a consumer make file invokes tuist/xcodegen/xcodebuild directly
/// instead of routing through `$(SWIFT_MK_BIN) toolchain`. Defaults to `Makefile`.
struct BuildToolingAuditCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "build-tooling-audit",
    abstract: "Fail when a consumer make file invokes the build toolchain directly."
  )

  @Argument(help: "Make files to scan (default: Makefile).")
  var paths: [String] = []

  func run() throws {
    let scanned = paths.isEmpty ? ["Makefile"] : paths
    let findings = BuildToolingAudit.scan(paths: scanned)
    for finding in findings {
      Output.logError(finding.rendered)
    }
    if !findings.isEmpty {
      throw ExitCode(1)
    }
  }
}
