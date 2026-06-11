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
      ToolchainBuildForTesting.self, ToolchainTest.self, ToolchainAnalyze.self,
      ToolchainVersion.self, ToolchainDownloadComponent.self,
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

  /// Extra generator flags forwarded verbatim, e.g. `-- --cache-profile none` for a
  /// consumer whose `tuist generate` needs them. Pass them after `--`.
  @Argument(help: "Extra generator arguments (after --), e.g. --cache-profile none.")
  var passthrough: [String] = []

  func run() throws {
    try toolchainExit(Toolchain.generate(resolveGenerator(generator), extraArguments: passthrough))
  }
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

  @Flag(name: .long, help: "Run `clean` before `build`. Requires --log-path.")
  var clean = false

  @Option(
    name: .customLong("log-path"),
    help: "Write the full xcodebuild output to this file for `swiftlint analyze` to read.")
  var logPath: String?

  func run() throws {
    let request = try options.request()
    if let logPath {
      try toolchainExit(Toolchain.buildWritingLog(request, logPath: logPath, clean: clean))
      return
    }
    if clean {
      throw ValidationError("--clean requires --log-path")
    }
    try toolchainExit(Toolchain.build(request))
  }
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

// MARK: - ToolchainAnalyze

struct ToolchainAnalyze: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "analyze")
  @OptionGroup var options: ToolchainRequestOptions

  func run() throws { try toolchainExit(Toolchain.analyze(options.request())) }
}

// MARK: - ToolchainVersion

struct ToolchainVersion: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "version")

  func run() { Output.log(Toolchain.version()) }
}

// MARK: - ToolchainDownloadComponent

struct ToolchainDownloadComponent: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "download-component")

  @Argument(help: "The on-demand Xcode component to download.")
  var component: String

  func run() throws { try toolchainExit(Toolchain.downloadComponent(component)) }
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
