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

public enum LintResources {
  struct Resource {
    let resourceName: String
    let resourceExtension: String
    let destinationComponents: [String]
    let interpolatesGitIdentity: Bool
  }

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

  private final class BundleFinder {}

  private static let bundleName = "swift-makefile_SwiftMkCore.bundle"

  /// The lookup returns nil when the resource bundle is missing.
  private static let resourceBundle: Bundle? = {
    let finderBundle = Bundle(for: BundleFinder.self)
    let candidateDirectories: [URL?] = [
      Bundle.main.resourceURL,
      finderBundle.resourceURL,
      Bundle.main.bundleURL,
      finderBundle.bundleURL.deletingLastPathComponent(),
      Bundle.main.executableURL?.deletingLastPathComponent(),
    ]
    for directory in candidateDirectories {
      guard let candidate = directory?.appendingPathComponent(bundleName) else {
        continue
      }
      if let bundle = Bundle(url: candidate) {
        return bundle
      }
    }
    return nil
  }()

  public static func bundledData(resourceName: String, resourceExtension: String) -> Data? {
    guard let bundle = resourceBundle else {
      Output.error(missingBundleMessage())
      return nil
    }
    guard
      let url = bundle.url(
        forResource: resourceName, withExtension: resourceExtension)
    else {
      Output.error(
        "lint-resources: \(resourceName).\(resourceExtension) is missing from "
          + "\(bundle.bundlePath)")
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

  static func missingBundleMessage(
    executableURL: URL? = Bundle.main.executableURL
  ) -> String {
    guard let directory = executableURL?.deletingLastPathComponent().path else {
      return "lint-resources: missing folder \(bundleName), which stores the swift-mk "
        + "lint configs. Rebuild swift-mk."
    }
    return "lint-resources: missing folder \(directory)/\(bundleName), which stores the "
      + "swift-mk lint configs. Delete \(directory)/swift-mk.key and run make again to "
      + "rebuild it."
  }

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

  /// ensure writes bundled configuration files that are missing or differ.
  /// SwiftLint requires Git identity outside GitHub Actions. GitHub Actions
  /// disables file_header instead. The function returns false if a resource
  /// cannot be read, rendered, or written.
  @discardableResult
  public static func ensure(
    context: PathContext = .current(),
    gitEnvironment: [String: String] = [:],
    githubActions: String = Env.get("GITHUB_ACTIONS"),
    githubRunId: String = Env.get("GITHUB_RUN_ID")
  ) -> Bool {
    guard resourceBundle != nil else {
      Output.error(missingBundleMessage())
      return false
    }
    let root = URL(fileURLWithPath: context.cwd, isDirectory: true)
    var allPresent = true
    for resource in resources {
      guard
        let bundled = bundledData(
          resourceName: resource.resourceName,
          resourceExtension: resource.resourceExtension)
      else {
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
      let destination = destinationURL(for: resource, root: root, context: context)
      if !writeIfChanged(data, to: destination) {
        allPresent = false
      }
    }
    return allPresent
  }

  /// Relative SWIFT_MK_SWIFTLINT_CONFIG paths are resolved against context.pwd,
  /// because the gate passes the same value to `swiftlint --config` and
  /// swiftlint resolves it against the process working directory.
  /// Other destinations are relative to context.cwd.
  private static func destinationURL(
    for resource: Resource,
    root: URL,
    context: PathContext
  ) -> URL {
    if resource.interpolatesGitIdentity {
      let configured = Env.get("SWIFT_MK_SWIFTLINT_CONFIG")
      if !configured.isEmpty {
        if configured.hasPrefix("/") {
          return URL(fileURLWithPath: configured)
        }
        let workingDirectory = URL(fileURLWithPath: context.pwd, isDirectory: true)
        return workingDirectory.appendingPathComponent(configured)
      }
    }
    var destination = root
    for component in resource.destinationComponents {
      destination = destination.appendingPathComponent(component)
    }
    return destination
  }

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
  ) -> Result<Data, Error> {
    if Build.isGitHubActionsCI(githubActions: githubActions, githubRunId: githubRunId) {
      do {
        let disabled = try swiftlintYAMLDisablingFileHeader(bundled)
        Output.info("lint-resources: disabled SwiftLint file_header in GitHub Actions")
        return .success(disabled)
      } catch {
        Output.error("lint-resources: could not disable SwiftLint file_header: \(error)")
        return .failure(error)
      }
    }
    let directory = checkoutDirectory(context.cwd)
    switch GitIdentity.load(directory: directory, environment: gitEnvironment) {
    case .failure(let failure):
      return .failure(failure)
    case .success(let identity):
      do {
        let interpolated = try interpolatedSwiftlintYAML(
          template: bundled, identity: identity)
        Output.info("lint-resources: interpolated SwiftLint file_header from git identity")
        return .success(interpolated)
      } catch {
        Output.error("lint-resources: could not interpolate SwiftLint YAML: \(error)")
        return .failure(error)
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
