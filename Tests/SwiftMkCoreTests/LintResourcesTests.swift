//
//  LintResourcesTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - LintResourcesTests

/// The bundled gate configs must match the repo's root config files byte for byte,
/// so the engine-owned resources never drift from the source the maintainer edits,
/// and `LintResources.ensure` writes the configs into a fresh checkout.
enum LintResourcesTests {
  /// A bundled resource paired with the repo-root file it must equal.
  struct Pair {
    let interpolatesGitIdentity: Bool
    let resourceExtension: String
    let resourceName: String
    let rootFile: String
  }

  /// Each bundled resource and its source-of-truth root file.
  static let pairs: [Pair] = [
    Pair(
      interpolatesGitIdentity: true,
      resourceExtension: "yml",
      resourceName: "swiftlint",
      rootFile: ".swiftlint.yml"),
    Pair(
      interpolatesGitIdentity: false,
      resourceExtension: "json",
      resourceName: "swift-format",
      rootFile: ".swift-format"),
    Pair(
      interpolatesGitIdentity: false,
      resourceExtension: "yml",
      resourceName: "periphery",
      rootFile: ".periphery.yml"),
    Pair(
      interpolatesGitIdentity: false,
      resourceExtension: "toml",
      resourceName: "osv-scanner",
      rootFile: "osv-scanner.toml"),
    Pair(
      interpolatesGitIdentity: false,
      resourceExtension: "toml",
      resourceName: "mise",
      rootFile: "mise.toml"),
  ]

  /// The repo root, derived from this test file's path so it is independent of the
  /// process working directory (other suites change it).
  static func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

@Test
func bundledConfigsMatchRootConfigsByteForByte() throws {
  let root = LintResourcesTests.repoRoot()
  for pair in LintResourcesTests.pairs {
    let bundled = try #require(
      LintResources.bundledData(
        resourceName: pair.resourceName, resourceExtension: pair.resourceExtension),
      "bundled \(pair.resourceName).\(pair.resourceExtension) is missing")
    let rootData = try Data(contentsOf: root.appendingPathComponent(pair.rootFile))
    #expect(bundled == rootData, "drift in \(pair.rootFile)")
  }
}

@Test
func ensureWritesConfigsIntoAFreshCheckout() throws {
  let manager = FileManager.default
  let checkout = NSTemporaryDirectory() + "swiftmk-resources-" + UUID().uuidString
  try manager.createDirectory(atPath: checkout, withIntermediateDirectories: true)
  defer { removeTemporary(checkout) }
  let repo = URL(fileURLWithPath: checkout, isDirectory: true)
  try initGitRepo(repo, name: "Test User", email: "test@example.com")
  let gitEnvironment = isolatedGitEnvironment(in: repo)

  let ok = LintResources.ensure(
    context: PathContext(pwd: checkout + "/", cwd: checkout + "/"),
    gitEnvironment: gitEnvironment,
    githubActions: "",
    githubRunId: "")
  #expect(ok)
  #expect(manager.fileExists(atPath: checkout + "/.make/swiftlint.yml"))
  #expect(manager.fileExists(atPath: checkout + "/.make/swift-format.json"))
  #expect(manager.fileExists(atPath: checkout + "/.make/periphery.yml"))
  #expect(manager.fileExists(atPath: checkout + "/.make/osv-scanner.toml"))
  #expect(manager.fileExists(atPath: checkout + "/.config/mise/conf.d/swift-mk.toml"))

  let identity = GitIdentity(name: "Test User", email: "test@example.com")
  let bundledSwiftlint = try #require(
    LintResources.bundledData(resourceName: "swiftlint", resourceExtension: "yml"))
  let expected = try LintResources.interpolatedSwiftlintYAML(
    template: bundledSwiftlint, identity: identity)
  let written = try Data(contentsOf: URL(fileURLWithPath: checkout + "/.make/swiftlint.yml"))
  #expect(written == expected)

  let formatBundled = try #require(
    LintResources.bundledData(resourceName: "swift-format", resourceExtension: "json"))
  let formatWritten = try Data(
    contentsOf: URL(fileURLWithPath: checkout + "/.make/swift-format.json"))
  #expect(formatWritten == formatBundled)
}

@Test
func ensureFailsWhenGitIdentityIsMissing() throws {
  let manager = FileManager.default
  let checkout = NSTemporaryDirectory() + "swiftmk-resources-noid-" + UUID().uuidString
  try manager.createDirectory(atPath: checkout, withIntermediateDirectories: true)
  defer { removeTemporary(checkout) }
  let repo = URL(fileURLWithPath: checkout, isDirectory: true)
  try initGitRepo(repo, name: nil, email: nil)

  let ok = LintResources.ensure(
    context: PathContext(pwd: checkout + "/", cwd: checkout + "/"),
    gitEnvironment: isolatedGitEnvironment(in: repo),
    githubActions: "",
    githubRunId: "")
  #expect(!ok)
  #expect(!manager.fileExists(atPath: checkout + "/.make/swiftlint.yml"))
}

@Test
func ensureInGitHubActionsDisablesFileHeaderWithoutGitIdentity() throws {
  let manager = FileManager.default
  let checkout = NSTemporaryDirectory() + "swiftmk-resources-ci-" + UUID().uuidString
  try manager.createDirectory(atPath: checkout, withIntermediateDirectories: true)
  defer { removeTemporary(checkout) }
  let repo = URL(fileURLWithPath: checkout, isDirectory: true)
  try initGitRepo(repo, name: nil, email: nil)

  let ok = LintResources.ensure(
    context: PathContext(pwd: checkout + "/", cwd: checkout + "/"),
    gitEnvironment: isolatedGitEnvironment(in: repo),
    githubActions: "true",
    githubRunId: "12345")
  #expect(ok)
  let yaml = try String(
    contentsOf: URL(fileURLWithPath: checkout + "/.make/swiftlint.yml"), encoding: .utf8)
  #expect(yaml.contains("\n  - file_header\n"))
  #expect(!yaml.contains("required_pattern:"))
  #expect(!yaml.contains("[^<\\n]+"))
  #expect(!yaml.contains("[[GIT_USER_NAME]]"))
}

@Test
func swiftlintYAMLDisablingFileHeaderRemovesPatternAndDisablesRule() throws {
  let bundled = try #require(
    LintResources.bundledData(resourceName: "swiftlint", resourceExtension: "yml"))
  let yamlData = try LintResources.swiftlintYAMLDisablingFileHeader(bundled)
  let yaml = try #require(String(bytes: yamlData, encoding: .utf8))
  #expect(yaml.contains("disabled_rules:\n  - file_header\n"))
  #expect(!yaml.contains("file_header:\n"))
  #expect(!yaml.contains("required_pattern:"))
  #expect(!yaml.contains("[[GIT_USER_NAME]]"))
  #expect(!yaml.contains("[^<\\n]+"))
}

@Test
func interpolatedFileHeaderMatchesGitIdentityAndRejectsAgents() throws {
  let identity = GitIdentity(name: "Test User", email: "test@example.com")
  let bundled = try #require(
    LintResources.bundledData(resourceName: "swiftlint", resourceExtension: "yml"))
  let yamlData = try LintResources.interpolatedSwiftlintYAML(
    template: bundled, identity: identity)
  let yaml = try #require(String(bytes: yamlData, encoding: .utf8))
  #expect(!yaml.contains("[^<\\n]+"))
  #expect(!yaml.contains("[[GIT_USER_NAME]]"))
  #expect(yaml.contains("Created by Test User <test@example\\.com>"))

  let pattern = try requiredPattern(from: yaml)
  let expression = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
  let accepted = header(
    name: "Test User", email: "test@example.com", date: "2026-07-26")
  let codex = header(
    name: "Codex", email: "noreply@openai.com", date: "2026-07-26")
  let alex = header(
    name: "Alex Goodkind", email: "alex@goodkind.io", date: "2026-07-26")
  #expect(matchCount(expression, in: accepted) == 1)
  #expect(matchCount(expression, in: codex) == 0)
  #expect(matchCount(expression, in: alex) == 0)
}

// MARK: - Header pattern helpers

private let yamlRequiredPatternIndentCount = 4

private func requiredPattern(from yaml: String) throws -> String {
  var collecting = false
  var lines: [String] = []
  for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
    let text = String(line)
    if text.contains("required_pattern:") {
      collecting = true
      continue
    }
    if collecting {
      if text.hasPrefix("    ") {
        lines.append(String(text.dropFirst(yamlRequiredPatternIndentCount)))
        continue
      }
      if text.isEmpty {
        continue
      }
      break
    }
  }
  let pattern = lines.joined(separator: "\n")
  if pattern.isEmpty {
    throw PatternExtractError.empty
  }
  return pattern
}

// MARK: - PatternExtractError

private enum PatternExtractError: Error {
  case empty
}

private func header(name: String, email: String, date: String) -> String {
  """
  //
  //  Foo.swift
  //  Module
  //
  //  Created by \(name) <\(email)> on \(date).
  //  Copyright © 2026, all rights reserved.
  //
  """
}

private func matchCount(_ expression: NSRegularExpression, in text: String) -> Int {
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  return expression.numberOfMatches(in: text, options: [], range: range)
}

private func initGitRepo(_ directory: URL, name: String?, email: String?) throws {
  runGit(["init", "-q"], in: directory)
  let emptyHooks = directory.appendingPathComponent(".git/no-hooks", isDirectory: true)
  try FileManager.default.createDirectory(at: emptyHooks, withIntermediateDirectories: true)
  runGit(["config", "core.hooksPath", emptyHooks.path], in: directory)
  if let name {
    runGit(["config", "user.name", name], in: directory)
  }
  if let email {
    runGit(["config", "user.email", email], in: directory)
  }
}

private func isolatedGitEnvironment(in repo: URL) -> [String: String] {
  let empty = repo.appendingPathComponent("empty.gitconfig").path
  if !FileManager.default.fileExists(atPath: empty) {
    let created = FileManager.default.createFile(atPath: empty, contents: Data())
    if !created {
      Output.error("lint-resources-test: could not create \(empty)")
    }
  }
  return [
    "GIT_CONFIG_GLOBAL": empty,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_SYSTEM": empty,
  ]
}

@discardableResult
private func runGit(_ arguments: [String], in directory: URL) -> Shell.Result {
  Shell.run("git", ["-C", directory.path] + arguments)
}
