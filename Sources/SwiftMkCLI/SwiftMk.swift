//
//  SwiftMk.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import Foundation
import SwiftMkCore
import SwiftMkRenderCore

// MARK: - SwiftMk

@main
struct SwiftMk: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "swift-mk",
    abstract: "swift-makefile tooling: lint, baseline, gate, and notices.",
    subcommands: [
      LintCommand.self, LintTools.self, LintSwiftlint.self, LintFormat.self,
      LintComplexity.self, LintDeadcode.self, LintFiles.self, LintDiff.self,
      LintSwiftlintScope.self, SwiftcheckExtra.self, SwiftcheckExtraBin.self,
      Fmt.self, TestCommand.self, Audit.self, LogAudit.self,
      BaselineCommand.self, NoticeCommand.self, Render.self, RenderBatch.self,
      XcodeFileHeader.self, BuildCheck.self, BuildCommand.self, GateToken.self,
      GateProofCommand.self,
      SigningXcconfig.self, SigningIdentity.self, VerifySigning.self, CodesignRun.self,
      NotarizeCommand.self,
      TraceCommand.self, ToolchainCommand.self, BuildToolingAuditCommand.self,
    ]
  )
}

private func gate(_ body: (PathContext) -> Bool) throws {
  if !body(PathContext.current()) { throw ExitCode(1) }
}

// MARK: - TraceCommand

struct TraceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "trace",
    subcommands: [TraceBegin.self]
  )
}

// MARK: - TraceBegin

struct TraceBegin: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "begin")

  func run() {
    Logging.beginRun()
  }
}

// MARK: - LintCommand

struct LintCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "lint")

  func run() throws { try gate(Lint.runLint) }
}

// MARK: - LintTools

struct LintTools: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "lint-tools")

  func run() throws { try gate(Lint.runTools) }
}

// MARK: - LintSwiftlint

struct LintSwiftlint: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "lint-swiftlint")

  func run() throws { try gate(Lint.runSwiftlint) }
}

// MARK: - LintFormat

struct LintFormat: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "lint-format")

  func run() throws { try gate(Lint.runFormat) }
}

// MARK: - LintComplexity

struct LintComplexity: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "lint-complexity")

  func run() throws { try gate(Lint.runComplexity) }
}

// MARK: - LintDeadcode

struct LintDeadcode: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "lint-deadcode")

  func run() throws { try gate(Lint.runDeadcode) }
}

// MARK: - LintFiles

struct LintFiles: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "lint-files")

  func run() throws { try gate(Lint.runLintFiles) }
}

// MARK: - LintDiff

struct LintDiff: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "lint-diff")

  func run() throws { try gate(Lint.runLintDiff) }
}

// MARK: - LintSwiftlintScope

struct LintSwiftlintScope: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "lint-swiftlint-scope")

  @Option(name: .long) var rule: String?

  func run() throws {
    if let rule { setenv("RULE", rule, 1) }
    try gate(Lint.runSwiftlintScope)
  }
}

// MARK: - SwiftcheckExtra

struct SwiftcheckExtra: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "swiftcheck-extra")

  func run() throws { try gate(Swiftcheck.runGate) }
}

// MARK: - SwiftcheckExtraBin

struct SwiftcheckExtraBin: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "swiftcheck-extra-bin")

  func run() throws { if !Swiftcheck.resolveBin() { throw ExitCode(1) } }
}

// MARK: - Fmt

struct Fmt: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "fmt")

  func run() throws { try gate(Lint.runFmt) }
}

// MARK: - TestCommand

struct TestCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "test")

  func run() throws { try gate(Lint.runTest) }
}

// MARK: - Audit

struct Audit: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "audit")

  func run() throws { try gate(Lint.runAudit) }
}

// MARK: - LogAudit

struct LogAudit: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "log-audit")

  func run() throws { try gate(Lint.runLogAudit) }
}

// MARK: - BuildCheck

struct BuildCheck: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "build-check")

  func run() throws { try gate(Lint.runBuildCheck) }
}

// MARK: - BuildCommand

/// `swift-mk build`: the build chokepoint. It runs the lint gates in-process and
/// then the consumer's configured build command, so a product build cannot run
/// without the gates. The make `build` target routes here instead of running the
/// build command on its own.
struct BuildCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "build",
    abstract: "Run the lint gates, then the configured build command."
  )

  func run() throws {
    let status = Build.gateAndBuild()
    if status != 0 { throw ExitCode(status) }
  }
}

// MARK: - GateToken

/// Print the rotating daily token for BYPASS_LINT or BASELINE_TOKEN. Hidden: it
/// carries the maintainer secret, so it is not advertised in help.
struct GateToken: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "gate-token", shouldDisplay: false)

  func run() throws {
    guard let slug = TokenGate.dailyTokenSlug() else {
      Output.logError("gate-token: could not resolve the daily token")
      throw ExitCode(1)
    }
    Output.log(slug)
  }
}

// MARK: - SigningXcconfig

/// Write `.make/signing.xcconfig` from the signing inputs and print its absolute
/// path on standard output. Prints nothing when no signing values are set, so
/// `build`/`deploy` skip the override and an unsigned build still works.
struct SigningXcconfig: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "signing-xcconfig",
    abstract:
      "Write the build-time code-signing xcconfig and print its path; "
      + "print nothing when no signing values are set."
  )

  func run() {
    if let path = SigningBuildConfig.write() {
      Output.log(path)
    }
  }
}

// MARK: - SigningIdentity

/// Print the resolved code-signing identity on standard output, so a post-build
/// `codesign` step (a SwiftPM product that has no xcodebuild signing phase) can
/// sign with the same identity swift-mk resolves for xcodebuild. Reads
/// SWIFT_MK_SIGN_IDENTITY then CODE_SIGN_IDENTITY.
///
/// When no real identity is set it prints nothing, so a caller never silently signs
/// ad-hoc, with one carve-out: a SwiftPM package on the compiled-in
/// `AdHocSigningAllowlist` (an embedded helper the product re-signs) prints the ad-hoc
/// identity `-` with a stderr audit line. There is no flag or knob; the allowlist is
/// the only path to ad-hoc and it is gate-protected from mutation.
struct SigningIdentity: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "signing-identity",
    abstract:
      "Print the resolved code-signing identity; print nothing when unset."
  )

  func run() {
    let identity = SigningBuildConfig.environmentInputs().identity
      .trimmingCharacters(in: .whitespaces)
    if !identity.isEmpty {
      Output.log(identity)
      return
    }
    guard let allowed = AdHocSigningAllowlist.allowedPackageName() else {
      return
    }
    Output.logError(
      "signing-identity: package '\(allowed)' is on swift-mk's compiled-in ad-hoc "
        + "allowlist and no real identity is set; using ad-hoc '-'.")
    Output.log("-")
  }
}

// MARK: - VerifySigning

/// Verify the build-time signature matches what swift-mk resolves. `settings`
/// reads `xcodebuild -showBuildSettings` before a build; `artifacts` reads
/// `codesign` on the produced bundles after.
struct VerifySigning: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify-signing",
    abstract: "Verify the build-time signature matches what swift-mk resolves.",
    subcommands: [VerifySigningArtifacts.self, VerifySigningSettings.self]
  )
}

// MARK: - VerifySigningArtifacts

struct VerifySigningArtifacts: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "artifacts")

  @Option(
    name: .customLong("xcconfig"),
    parsing: .upToNextOption,
    help: "Local xcconfig paths to read signing values from when unset in the environment."
  )
  var xcconfigPaths: [String] = []

  @Argument(help: "Built artifacts (.app bundles or binaries) to verify.")
  var paths: [String]

  func run() throws {
    let passed = SigningVerification.verifyArtifacts(
      paths: paths, localXcconfigPaths: xcconfigPaths)
    if !passed {
      throw ExitCode(1)
    }
  }
}

// MARK: - VerifySigningSettings

struct VerifySigningSettings: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "settings")

  @Option(name: .customLong("workspace")) var workspace: String
  @Option(name: .customLong("scheme")) var scheme: String
  @Option(name: .customLong("configuration")) var configuration: String?

  @Option(
    name: .customLong("xcconfig"),
    parsing: .upToNextOption,
    help: "Local xcconfig paths to read signing values from when unset in the environment."
  )
  var xcconfigPaths: [String] = []

  func run() throws {
    let passed = SigningVerification.verifySettings(
      workspace: workspace,
      scheme: scheme,
      configuration: configuration,
      localXcconfigPaths: xcconfigPaths)
    if !passed {
      throw ExitCode(1)
    }
  }
}

// MARK: - BaselineCommand

struct BaselineCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "baseline")

  @Argument var component: String = "all"
  @Option(name: .long) var rule: String?
  @Flag(name: .long, help: "Emit machine-readable JSON instead of text.") var json = false

  func run() throws {
    if let rule { setenv("RULE", rule, 1) }
    if json { setenv("BASELINE_OUTPUT_FORMAT", "json", 1) }
    try BaselineRunner.update(component: component, context: PathContext.current())
  }
}

// MARK: - NoticeCommand

struct NoticeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "notice")

  func run() {
    Output.info("notice: applying notices")
    Notice.run(context: PathContext.current())
  }
}

// MARK: - Render

struct Render: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "render")

  @Argument var templatePath: String

  struct Context: Decodable { let values: [String: String] }

  func run() throws {
    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    let context = try JSONDecoder().decode(Context.self, from: inputData)
    let templateText = try String(contentsOfFile: templatePath, encoding: .utf8)
    let rendered = try TemplateRenderer.render(
      templateText: templateText, values: context.values)
    FileHandle.standardOutput.write(Data(rendered.utf8))
  }
}

// MARK: - RenderBatch

struct RenderBatch: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "render-batch",
    abstract:
      "Render every *.template file under --templates-dir to --output-dir "
      + "using environment variables for [[KEY]] substitutions."
  )

  @Option(name: .customLong("templates-dir"))
  var templatesDir: String

  @Option(name: .customLong("output-dir"))
  var outputDir: String

  @Option(
    name: .customLong("env"),
    parsing: .upToNextOption,
    help: "Names of environment variables to expose as [[KEY]] substitutions."
  )
  var envKeys: [String] = []

  func run() throws {
    Output.info(
      "render-batch: starting templates=\(templatesDir) output=\(outputDir)"
    )
    let fileManager = FileManager.default
    let environment = ProcessInfo.processInfo.environment
    var values: [String: String] = [:]
    for key in envKeys {
      values[key] = environment[key] ?? ""
    }

    let templatesURL = URL(fileURLWithPath: templatesDir, isDirectory: true)
    var isDir: ObjCBool = false
    guard
      fileManager.fileExists(atPath: templatesURL.path, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw RenderBatchError.templatesDirMissing(templatesURL.path)
    }

    let outputURL = URL(fileURLWithPath: outputDir, isDirectory: true)
    try fileManager.createDirectory(
      at: outputURL, withIntermediateDirectories: true)

    guard
      let enumerator = fileManager.enumerator(
        at: templatesURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      throw RenderBatchError.cannotEnumerate(templatesURL.path)
    }

    let templateSuffix = ".template"
    var renderedCount = 0
    for case let templateURL as URL in enumerator {
      let templateName = templateURL.lastPathComponent
      guard templateName.hasSuffix(templateSuffix) else { continue }
      let templateText = try String(contentsOf: templateURL, encoding: .utf8)
      let rendered = try TemplateRenderer.render(
        templateText: templateText, values: values)
      let outputName = String(templateName.dropLast(templateSuffix.count))
      let outputFileURL = outputURL.appendingPathComponent(outputName)
      try rendered.write(to: outputFileURL, atomically: true, encoding: .utf8)
      renderedCount += 1
    }

    Output.info(
      "render-batch: rendered \(renderedCount) file(s) to \(outputURL.path)"
    )
  }
}

// MARK: - RenderBatchError

private enum RenderBatchError: Error, CustomStringConvertible {
  case cannotEnumerate(String)
  case templatesDirMissing(String)

  var description: String {
    switch self {
    case .cannotEnumerate(let path):
      return "cannot enumerate directory: \(path)"
    case .templatesDirMissing(let path):
      return "templates directory not found: \(path)"
    }
  }
}

// MARK: - XcodeFileHeader

struct XcodeFileHeader: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "xcode-file-header",
    abstract:
      "Render Xcode file-header macros (IDETemplateMacros.plist) from the "
      + "current git identity, rewriting outputs only when they change."
  )

  @Option(name: .customLong("templates-dir"))
  var templatesDir: String

  @Option(name: .customLong("output-dir"))
  var outputDir: String?

  func run() throws {
    let name = Self.gitConfig("user.name")
    let email = Self.gitConfig("user.email")
    guard !name.isEmpty, !email.isEmpty else {
      Output.log(
        "xcode-file-header: no git identity (user.name/user.email); skipping")
      return
    }
    let values = ["GIT_USER_NAME": name, "GIT_USER_EMAIL": email]
    let destination = outputDir ?? Self.defaultOutputDir()
    let written = try Self.renderChangedTemplates(
      templatesDir: templatesDir, outputDir: destination, values: values)
    Output.info("xcode-file-header: \(written) file(s) updated in \(destination)")
  }

  private static func gitConfig(_ key: String) -> String {
    Output.debug("xcode-file-header: reading git config \(key)")
    return Shell.run("git", ["config", key]).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func defaultOutputDir() -> String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Developer/Xcode/UserData").path
  }

  /// Render every `*.template` under `templatesDir`, writing each output only
  /// when its content differs from what is already on disk. Returns the count
  /// of files actually written.
  private static func renderChangedTemplates(
    templatesDir: String, outputDir: String, values: [String: String]
  ) throws -> Int {
    let fileManager = FileManager.default
    let templatesURL = URL(fileURLWithPath: templatesDir, isDirectory: true)
    var isDir: ObjCBool = false
    guard
      fileManager.fileExists(atPath: templatesURL.path, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw RenderBatchError.templatesDirMissing(templatesURL.path)
    }
    let outputURL = URL(fileURLWithPath: outputDir, isDirectory: true)
    try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
    guard
      let enumerator = fileManager.enumerator(
        at: templatesURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      throw RenderBatchError.cannotEnumerate(templatesURL.path)
    }
    let templateSuffix = ".template"
    var written = 0
    for case let templateURL as URL in enumerator {
      let templateName = templateURL.lastPathComponent
      guard templateName.hasSuffix(templateSuffix) else { continue }
      let outputName = String(templateName.dropLast(templateSuffix.count))
      let outputFileURL = outputURL.appendingPathComponent(outputName)
      if try renderPlist(at: templateURL, to: outputFileURL, values: values) {
        written += 1
      }
    }
    return written
  }

  /// Decode the macros plist with Foundation's property-list reader, substitute
  /// the identity tokens in the FILEHEADER value, and write a canonical XML
  /// plist only when it changes. Returns whether the output was written.
  private static func renderPlist(
    at templateURL: URL, to outputFileURL: URL, values: [String: String]
  ) throws -> Bool {
    Output.debug(
      "xcode-file-header: rendering plist template=\(templateURL.path) output=\(outputFileURL.path)"
    )
    let templateData = try Data(contentsOf: templateURL)
    var macros = try PropertyListDecoder().decode(
      TemplateMacros.self, from: templateData)
    macros.fileHeader = try TemplateRenderer.render(
      templateText: macros.fileHeader, values: values)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    let rendered = try encoder.encode(macros)
    let existing: Data?
    do {
      existing = try Data(contentsOf: outputFileURL)
    } catch {
      let cocoaError = error as NSError
      guard
        cocoaError.domain == NSCocoaErrorDomain,
        cocoaError.code == NSFileReadNoSuchFileError
      else {
        throw error
      }
      existing = nil
    }
    if existing == rendered { return false }
    try rendered.write(to: outputFileURL, options: .atomic)
    return true
  }

  private struct TemplateMacros: Codable {
    var fileHeader: String

    enum CodingKeys: String, CodingKey {
      case fileHeader = "FILEHEADER"
    }
  }
}
