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

private typealias GateFamilies = Set<CiChanged.GateFamily>

private let noGateFamilies: GateFamilies = []
private let buildGateFamilies: GateFamilies = [.build]
private let lintGateFamilies: GateFamilies = [.lint]
private let allGateFamilies: GateFamilies = [.build, .lint]

// MARK: - ClassifyCase

private struct ClassifyCase {
  let name: String
  let paths: [String]
  var graph: CiChanged.Graph? = sampleGraph
  var extraDirs: [String] = []
  var deleted: Set<String> = []
  var lint: Set<String> = sampleLint
  let expected: GateFamilies
}

private let classifyCases: [ClassifyCase] = [
  graphCase("docs only skips", ["/r/README.md"], noGateFamilies),
  graphCase(
    "a compiled and linted source feeds build and lint",
    ["/r/Sources/A.swift"],
    allGateFamilies
  ),
  graphCase(
    "a linted tool source the build does not compile feeds lint only",
    ["/r/Tools/Helper.swift"],
    lintGateFamilies
  ),
  graphCase(
    "a compiled objc source not in the lint set feeds build only",
    ["/r/Sources/Legacy.m"],
    buildGateFamilies
  ),
  graphCase(
    "a swiftlint config feeds lint only",
    ["/r/.swiftlint.yml"],
    lintGateFamilies
  ),
  graphCase(
    "a swift-format config feeds lint only",
    ["/r/.swift-format"],
    lintGateFamilies
  ),
  graphCase("Package.resolved feeds build and lint", ["/r/Package.resolved"], allGateFamilies),
  graphCase("Makefile feeds build and lint", ["/r/Makefile"], allGateFamilies),
  graphCase(
    "a workflow change feeds build and lint",
    ["/r/.github/workflows/_ci.yml"],
    allGateFamilies
  ),
  graphCase(
    "an xcode project change feeds build and lint",
    ["/r/App.xcodeproj/project.pbxproj"],
    allGateFamilies
  ),
  graphCase(
    "an xcode workspace change feeds build and lint",
    ["/r/App.xcworkspace/contents.xcworkspacedata"],
    allGateFamilies
  ),
  graphCase(
    "a swift file in neither the graph nor the lint set skips",
    ["/r/Sources/Ghost.swift"],
    noGateFamilies
  ),
  graphCase(
    "a non-swift source outside the graph skips",
    ["/r/Shaders/x.metal"],
    noGateFamilies
  ),
  graphCase(
    "a declared resource directory feeds build only",
    ["/r/Sources/Resources/x.json"],
    buildGateFamilies
  ),
  graphCase(
    "a declared resource file feeds build only",
    ["/r/Sources/mise.toml"],
    buildGateFamilies
  ),
  graphCase("an empty diff skips", [], noGateFamilies),
  deletedCase("a deleted non-doc path feeds build and lint", ["/r/Sources/Gone.swift"]),
  deletedCase("a deleted doc skips", ["/r/OldDoc.md"], noGateFamilies),
  deletedCase("a deleted build config feeds build and lint", ["/r/Package.swift"]),
  deletedCase("a deleted lint config feeds lint only", ["/r/.swiftlint.yml"], lintGateFamilies),
  extraDirCase(
    "a change under an extra dir feeds build only",
    ["/r/Generated/x.json"],
    ["/r/Generated"],
    buildGateFamilies
  ),
  pathCase(
    "a path fallback non-doc feeds build and lint", ["/r/Shaders/x.metal"], allGateFamilies),
  pathCase("docs only without a graph skips", ["/r/README.md"], noGateFamilies),
  pathCase("a build config runs without a graph", ["/r/Makefile"], allGateFamilies),
  extraDirCase(
    "an extra dir runs without a graph",
    ["/r/Gen/y.txt"],
    ["/r/Gen"],
    buildGateFamilies,
    graph: nil
  ),
]

@Test
func classifyUsesTheGraphAndLintSetToDecideRelevance() {
  for testCase in classifyCases {
    let result = CiChanged.classify(
      changedPaths: testCase.paths,
      graph: testCase.graph,
      extraDirs: testCase.extraDirs,
      deletedPaths: testCase.deleted,
      lintSources: testCase.lint)
    #expect(result.families == testCase.expected, "\(testCase.name)")
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

private func graphCase(
  _ name: String,
  _ paths: [String],
  _ expected: GateFamilies
) -> ClassifyCase {
  ClassifyCase(name: name, paths: paths, expected: expected)
}

private func pathCase(
  _ name: String,
  _ paths: [String],
  _ expected: GateFamilies
) -> ClassifyCase {
  ClassifyCase(name: name, paths: paths, graph: nil, lint: [], expected: expected)
}

private func deletedCase(
  _ name: String,
  _ paths: [String],
  _ expected: GateFamilies = allGateFamilies
) -> ClassifyCase {
  ClassifyCase(name: name, paths: paths, deleted: Set(paths), expected: expected)
}

private func extraDirCase(
  _ name: String,
  _ paths: [String],
  _ dirs: [String],
  _ expected: GateFamilies,
  graph: CiChanged.Graph? = sampleGraph
) -> ClassifyCase {
  ClassifyCase(name: name, paths: paths, graph: graph, extraDirs: dirs, expected: expected)
}
