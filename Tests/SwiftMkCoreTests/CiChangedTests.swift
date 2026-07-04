//
//  CiChangedTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - CiChangedTests

enum CiChangedTests {}

// A.swift is compiled and linted; Legacy.m is compiled but not linted, so it exercises
// the build-graph branch that the lint set does not cover.
private let sampleGraph = CiChanged.Graph(
  sources: ["/r/Sources/A.swift", "/r/Sources/Legacy.m"],
  resourcePrefixes: ["/r/Sources/Resources", "/r/Sources/mise.toml"])

// The set the lint gate scans: every tracked .swift, including a tool script the build
// does not compile. A git-ignored or generated .swift is absent, so it is not in scope.
private let sampleLint: Set<String> = ["/r/Sources/A.swift", "/r/Tools/Helper.swift"]

// MARK: - ClassifyCase

private struct ClassifyCase {
  let name: String
  let paths: [String]
  var graph: CiChanged.Graph? = sampleGraph
  var extraDirs: [String] = []
  var deleted: Set<String> = []
  var lint: Set<String> = sampleLint
  let expected: Bool
}

@Test
func classifyUsesTheGraphAndLintSetToDecideRelevance() {
  let cases: [ClassifyCase] = [
    graphCase("docs only skips", ["/r/README.md"], false),
    graphCase("a compiled and linted source runs", ["/r/Sources/A.swift"], true),
    graphCase(
      "a compiled objc source not in the lint set runs via the graph", ["/r/Sources/Legacy.m"], true
    ),
    graphCase(
      "a linted tool source the build does not compile runs", ["/r/Tools/Helper.swift"], true),
    graphCase(
      "a swift file in neither the graph nor the lint set skips", ["/r/Sources/Ghost.swift"], false),
    graphCase("a non-swift source outside the graph skips", ["/r/Shaders/x.metal"], false),
    graphCase("a declared resource directory runs", ["/r/Sources/Resources/x.json"], true),
    graphCase("a declared resource file runs", ["/r/Sources/mise.toml"], true),
    graphCase("a build config runs", ["/r/Package.resolved"], true),
    graphCase("a workflow change runs", ["/r/.github/workflows/_ci.yml"], true),
    graphCase("an xcode project change runs", ["/r/App.xcodeproj/project.pbxproj"], true),
    graphCase(
      "an xcode workspace change runs", ["/r/App.xcworkspace/contents.xcworkspacedata"], true),
    graphCase("an empty diff skips", [], false),
    deletedCase("a deleted source runs", ["/r/Sources/Gone.swift"], true),
    deletedCase("a deleted resource runs", ["/r/Assets/icon.png"], true),
    deletedCase("a deleted doc skips", ["/r/OldDoc.md"], false),
    deletedCase("a deleted build config runs", ["/r/Package.swift"], true),
    extraDirCase("a change under an extra dir runs", ["/r/Generated/x.json"], ["/r/Generated"]),
    pathCase("a source change runs without a graph", ["/r/Sources/Any.swift"], true),
    pathCase("a metal change runs without a graph", ["/r/Shaders/x.metal"], true),
    pathCase("a resource change runs without a graph", ["/r/App/Assets.xcassets/icon.png"], true),
    pathCase("docs only without a graph skips", ["/r/README.md"], false),
    pathCase("a build config runs without a graph", ["/r/Makefile"], true),
    extraDirCase("an extra dir runs without a graph", ["/r/Gen/y.txt"], ["/r/Gen"], graph: nil),
  ]

  for testCase in cases {
    let result = CiChanged.classify(
      changedPaths: testCase.paths,
      graph: testCase.graph,
      extraDirs: testCase.extraDirs,
      deletedPaths: testCase.deleted,
      lintSources: testCase.lint)
    #expect(result.changed == testCase.expected, "\(testCase.name)")
  }
}

@Test
func supportedEventsAreOnlyPushAndPullRequest() {
  #expect(CiChanged.isSupportedEvent("push"))
  #expect(CiChanged.isSupportedEvent("pull_request"))
  #expect(!CiChanged.isSupportedEvent(""))
  #expect(!CiChanged.isSupportedEvent("workflow_dispatch"))
  #expect(!CiChanged.isSupportedEvent("schedule"))
}

private func graphCase(_ name: String, _ paths: [String], _ run: Bool) -> ClassifyCase {
  ClassifyCase(name: name, paths: paths, expected: run)
}

private func pathCase(_ name: String, _ paths: [String], _ run: Bool) -> ClassifyCase {
  ClassifyCase(name: name, paths: paths, graph: nil, lint: [], expected: run)
}

private func deletedCase(_ name: String, _ paths: [String], _ run: Bool) -> ClassifyCase {
  ClassifyCase(name: name, paths: paths, deleted: Set(paths), expected: run)
}

private func extraDirCase(
  _ name: String,
  _ paths: [String],
  _ dirs: [String],
  graph: CiChanged.Graph? = sampleGraph
) -> ClassifyCase {
  ClassifyCase(name: name, paths: paths, graph: graph, extraDirs: dirs, expected: true)
}
