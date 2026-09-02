//
//  LintResources.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkRenderCore

// MARK: - LintResources

/// The gate configuration files swift-mk owns, shipped as SwiftPM resources and
/// materialized into a checkout on demand.
///
/// The make path lands these in `.make/` (and the mise file under
/// `.config/mise/conf.d/`) through `swift.mk`'s fetch. The decoupled in-process
/// API has no make to fetch them, so it writes the same bundled bytes itself,
/// which also makes a fresh checkout that has never run `make` work. Shipping the
/// configs as engine-owned resources is what makes CI, make, and the API converge
/// on the same files. The SwiftLint YAML is a template: `ensure` interpolates
/// `git config user.name` and `user.email` into `file_header` before writing
/// `.make/swiftlint.yml`. A GitHub Actions run disables `file_header` instead,
/// because hosted runners do not set git identity.
public enum LintResources {
  /// One shipped config: the bundle resource that carries it and the
  /// checkout-relative path it is written to.
  struct Resource {
    let resourceName: String
    let resourceExtension: String
    let destinationComponents: [String]
    let interpolatesGitIdentity: Bool
  }

  /// Every shipped gate config and where it lands in a checkout. The destinations
  /// mirror the `swift.mk` fetch targets exactly (`.make/swiftlint.yml`,
  /// `.make/swift-format.json`, `.make/periphery.yml`, `.make/osv-scanner.toml`,
  /// and the additive mise location), so the in-process path produces the same
  /// files the make path does.
  static let resources: [Resource] = [
    Resource(
      resourceName: "swiftlint",
      resourceExtension: "yml",
      destinationComponents: [".make", "swiftlint.yml"],
      interpolatesGitIdentity: true),
    Resource(
      resourceName: "swift-format",
      resourceExtension: "json",
      destinationComponents: [".make", "swift-format.json"],
      interpolatesGitIdentity: false),
    Resource(
      resourceName: "periphery",
      resourceExtension: "yml",
      destinationComponents: [".make", "periphery.yml"],
      interpolatesGitIdentity: false),
    Resource(
      resourceName: "osv-scanner",
      resourceExtension: "toml",
      destinationComponents: [".make", "osv-scanner.toml"],
      interpolatesGitIdentity: false),
    Resource(
      resourceName: "mise",
      resourceExtension: "toml",
      destinationComponents: [".config", "mise", "conf.d", "swift-mk.toml"],
      interpolatesGitIdentity: false),
  ]

  // MARK: Bundled bytes

  /// The bundled bytes of a shipped config, or nil when the resource is missing
  /// from the bundle. Exposed so the drift test can compare them to the repo's
  /// root config files.
  public static func bundledData(resourceName: String, resourceExtension: String) -> Data? {
    guard
      let url = Bundle.module.url(
        forResource: resourceName, withExtension: resourceExtension)
    else {
      return nil
    }
    do {
      return try Data(contentsOf: url)
    } catch {
      Output.error(
        "lint-resources: could not read bundled \(resourceName).\(resourceExtension): \(error)")
      return nil
    }
  }

  /// Substitute regex-escaped git identity tokens into a SwiftLint YAML template.
  public static func interpolatedSwiftlintYAML(
    template: Data,
    identity: GitIdentity
  ) throws -> Data {
    guard let templateText = String(data: template, encoding: .utf8) else {
      throw InterpolationError.utf8EncodingFailed
    }
    let rendered = try TemplateRenderer.render(
      templateText: templateText, values: identity.regexEscapedHeaderValues)
    guard let data = rendered.data(using: .utf8) else {
      throw InterpolationError.utf8EncodingFailed
    }
    return data
  }

  // MARK: Materialize

  /// Write every shipped config into the checkout rooted at `context.cwd` when it
  /// is missing or its bytes differ from the bytes that should be on disk. The
  /// SwiftLint YAML is interpolated from git identity first; a missing identity
  /// fails the write and does not emit the wildcard author pattern, except in
  /// GitHub Actions where `file_header` is disabled. Other configs stay
  /// byte-identical to the bundle. Returns true when every shipped config is
  /// present and current after the call.
  @discardableResult
  public static func ensure(
    context: PathContext = .current(),
    gitEnvironment: [String: String] = [:],
    githubActions: String = Env.get("GITHUB_ACTIONS"),
    githubRunId: String = Env.get("GITHUB_RUN_ID")
  ) -> Bool {
    let root = URL(fileURLWithPath: context.cwd, isDirectory: true)
    var allPresent = true
    for resource in resources {
      guard
        let bundled = bundledData(
          resourceName: resource.resourceName,
          resourceExtension: resource.resourceExtension)
      else {
        Output.error(
          "lint-resources: bundled \(resource.resourceName).\(resource.resourceExtension) "
            + "is unavailable")
        allPresent = false
        continue
      }
      let data: Data
      if resource.interpolatesGitIdentity {
        switch bytesForSwiftlintYAML(
          bundled: bundled,
          context: context,
          gitEnvironment: gitEnvironment,
          githubActions: githubActions,
          githubRunId: githubRunId)
        {
        case .success(let interpolated):
          data = interpolated
        case .failure:
          allPresent = false
          continue
        }
      } else {
        data = bundled
      }
      var destination = root
      for component in resource.destinationComponents {
        destination = destination.appendingPathComponent(component)
      }
      if !writeIfChanged(data, to: destination) {
        allPresent = false
      }
    }
    return allPresent
  }

  /// Write `data` to `destination` only when the file is absent or its bytes
  /// differ, so an unchanged config is not rewritten on every run. Returns true
  /// when the file holds the intended bytes after the call.
  private static func writeIfChanged(_ data: Data, to destination: URL) -> Bool {
    if existingData(at: destination) == data {
      return true
    }
    let directory = destination.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      try data.write(to: destination, options: .atomic)
      return true
    } catch {
      Output.error(
        "lint-resources: could not write \(destination.path): \(error)")
      return false
    }
  }

  /// The bytes already at `destination`, or nil when the file is absent or
  /// unreadable, so a fresh checkout simply gets the bundled copy written.
  private static func existingData(at destination: URL) -> Data? {
    do {
      return try Data(contentsOf: destination)
    } catch {
      return nil
    }
  }

  // MARK: Interpolation

  public enum InterpolationError: Error {
    case disabledRulesSectionMissing
    case utf8EncodingFailed
  }

  /// Rewrite a SwiftLint YAML template so `file_header` is disabled and its
  /// `required_pattern` is gone. CI uses this because hosted runners have no
  /// git identity to interpolate.
  public static func swiftlintYAMLDisablingFileHeader(_ template: Data) throws -> Data {
    guard let templateText = String(data: template, encoding: .utf8) else {
      throw InterpolationError.utf8EncodingFailed
    }
    let withDisabledRule = try insertingFileHeaderIntoDisabledRules(templateText)
    let stripped = strippingFileHeaderRuleBlock(from: withDisabledRule)
    guard let data = stripped.data(using: .utf8) else {
      throw InterpolationError.utf8EncodingFailed
    }
    return data
  }

  private static func bytesForSwiftlintYAML(
    bundled: Data,
    context: PathContext,
    gitEnvironment: [String: String],
    githubActions: String,
    githubRunId: String
  ) -> Result<Data, GitIdentity.LoadFailure> {
    if Build.isGitHubActionsCI(githubActions: githubActions, githubRunId: githubRunId) {
      do {
        let disabled = try swiftlintYAMLDisablingFileHeader(bundled)
        Output.info("lint-resources: disabled SwiftLint file_header in GitHub Actions")
        return .success(disabled)
      } catch {
        Output.error("lint-resources: could not disable SwiftLint file_header: \(error)")
        return .failure(.missingName)
      }
    }
    let directory = checkoutDirectory(context.cwd)
    switch GitIdentity.load(directory: directory, environment: gitEnvironment) {
    case .failure(let failure):
      Output.error(
        "lint-resources: cannot interpolate SwiftLint file_header from git config")
      return .failure(failure)
    case .success(let identity):
      do {
        let interpolated = try interpolatedSwiftlintYAML(
          template: bundled, identity: identity)
        Output.info("lint-resources: interpolated SwiftLint file_header from git identity")
        return .success(interpolated)
      } catch {
        Output.error("lint-resources: could not interpolate SwiftLint YAML: \(error)")
        return .failure(.missingName)
      }
    }
  }

  private static func insertingFileHeaderIntoDisabledRules(_ yaml: String) throws -> String {
    if yaml.contains("\n  - file_header\n") {
      return yaml
    }
    guard let markerRange = yaml.range(of: "disabled_rules:\n") else {
      throw InterpolationError.disabledRulesSectionMissing
    }
    var updated = yaml
    updated.insert(contentsOf: "  - file_header\n", at: markerRange.upperBound)
    return updated
  }

  private static func strippingFileHeaderRuleBlock(from yaml: String) -> String {
    var kept: [String] = []
    var skipping = false
    for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line)
      if !skipping, text == "file_header:" {
        skipping = true
        continue
      }
      if skipping {
        if text.isEmpty || text.hasPrefix(" ") || text.hasPrefix("\t") {
          continue
        }
        skipping = false
      }
      kept.append(text)
    }
    return kept.joined(separator: "\n")
  }

  private static func checkoutDirectory(_ cwd: String) -> String {
    if cwd.hasSuffix("/") {
      return String(cwd.dropLast())
    }
    return cwd
  }
}
