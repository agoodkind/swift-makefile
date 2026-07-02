//
//  RuleSupport.swift
//  SwiftCheckCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftSyntax

// MARK: - Source file helpers

func isSwiftFile(_ path: String) -> Bool {
  path.hasSuffix(".swift")
}

func collectSwiftFiles(paths: [String]) -> [String] {
  let fileManager = FileManager.default
  var collectedPaths = Set<String>()

  for inputPath in paths {
    var isDirectory = ObjCBool(false)
    if fileManager.fileExists(atPath: inputPath, isDirectory: &isDirectory) {
      if isDirectory.boolValue {
        if let enumerator = fileManager.enumerator(atPath: inputPath) {
          for case let relativePath as String in enumerator
          where isSwiftFile(relativePath) {
            collectedPaths.insert("\(inputPath)/\(relativePath)")
          }
        }
      } else if isSwiftFile(inputPath) {
        collectedPaths.insert(inputPath)
      }
    }
  }

  return collectedPaths.sorted()
}

func isTestPath(_ path: String) -> Bool {
  path.contains("/Tests/") || path.hasSuffix("Tests.swift")
}

func isCLIEntryPointPath(_ path: String) -> Bool {
  path.hasSuffix("/main.swift")
}

func logNeedlePresent(in source: String) -> Bool {
  let needles = [
    ".debug(",
    ".error(",
    ".info(",
    ".notice(",
    ".warning(",
  ]
  return needles.contains { needle in
    source.contains(needle)
  }
}

func boundaryNeedlePresent(in source: String) -> Bool {
  let needles = [
    "Process(",
    ".run(",
    "copyItem(",
    "moveItem(",
    "removeItem(",
    "write(to:",
    "read(from:",
    "URLSession",
    "NWConnection",
    "NWListener",
    "register(",
    "unregister(",
    "launchctl",
    "xcodebuild",
    "open(",
  ]
  return needles.contains { needle in
    source.contains(needle)
  }
}

/// Whether a string literal is the name of a build-toolchain executable, used as a
/// command argument. The match is exact (trimmed): `"xcodebuild"`, `"tuist"`, or
/// `"xcodegen"`, which is how a process spawn names the program (`Shell.run(
/// "xcodebuild", ...)`, the `"tuist"` element of an argument array). Exact match,
/// not prefix, so prose that merely starts with the word, such as an error string
/// "xcodegen requires --project", does not match. Combined with an invocation-
/// context check at the call site, this flags spawning the build toolchain, not
/// mentioning it. The single sanctioned site is swift-mk's own `Toolchain`, which
/// swift-mk excludes through its own lint config; a consumer has no such file, so
/// any consumer invocation is a violation with no opt-out.
func buildToolNeedlePresent(in literal: String) -> Bool {
  let trimmed = literal.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed == "tuist" || trimmed == "xcodegen" || trimmed == "xcodebuild"
}

/// Whether a string literal is exactly `"swift"` (trimmed), the executable name a
/// process spawn uses to run the Swift command-line tool. Paired at the call site
/// with a check that the following argument is a banned subcommand, this flags
/// spawning `swift build`/`run`/`test` outside the engine chokepoint while leaving a
/// mere mention of the word alone.
func swiftExecutableNeedlePresent(in literal: String) -> Bool {
  literal.trimmingCharacters(in: .whitespacesAndNewlines) == "swift"
}

/// Whether a `swift` subcommand is one that compiles and so must route through the
/// engine `SwiftPM` chokepoint (for the `BuildLock`, the compile cache, and the gate
/// proof). `build`, `run`, and `test` compile; `package` is a metadata or clean
/// operation and a `<file>.swift` argument runs a standalone script, so both are
/// allowed. The check is exact-trimmed so prose is not matched.
func swiftBuildSubcommandBanned(in argument: String) -> Bool {
  let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed == "build" || trimmed == "run" || trimmed == "test"
}

/// The subcommand a `"swift"` executable literal is invoked with, or nil when it
/// cannot be read as a literal. Handles the two spawn shapes: an array-literal
/// argument that follows the executable (`run("swift", ["build", ...])`, so the next
/// call argument's first string element), and a flat array literal that holds both
/// (`["swift", "build", ...]`, so the next array element). A computed argument vector
/// (`run("swift", swiftBuildArguments(...))`) yields nil, so a dynamically built spawn
/// is not matched here; the consumer migration removes those.
func swiftSubcommand(after node: StringLiteralExprSyntax) -> String? {
  // Shape `["swift", "build", ...]`: the executable is an array element, so the
  // subcommand is the next element in the same array.
  if let element = node.parent?.as(ArrayElementSyntax.self),
    let list = element.parent?.as(ArrayElementListSyntax.self)
  {
    let elements = Array(list)
    guard let index = elements.firstIndex(where: { $0.id == element.id }),
      index + 1 < elements.count,
      let next = elements[index + 1].expression.as(StringLiteralExprSyntax.self)
    else {
      return nil
    }
    return stringLiteralContent(next)
  }
  // Shape `call("swift", ["build", ...])`: the executable is a call argument, so the
  // subcommand is the first string element of the next argument's array, or the next
  // argument itself when it is a scalar string literal.
  if let argument = node.parent?.as(LabeledExprSyntax.self),
    let list = argument.parent?.as(LabeledExprListSyntax.self)
  {
    let arguments = Array(list)
    guard let index = arguments.firstIndex(where: { $0.id == argument.id }),
      index + 1 < arguments.count
    else {
      return nil
    }
    let next = arguments[index + 1].expression
    if let array = next.as(ArrayExprSyntax.self) {
      for arrayElement in array.elements {
        if let literalElement = arrayElement.expression.as(StringLiteralExprSyntax.self) {
          return stringLiteralContent(literalElement)
        }
      }
      return nil
    }
    return next.as(StringLiteralExprSyntax.self).map(stringLiteralContent)
  }
  return nil
}

/// The concatenated content of a string literal's plain text segments, ignoring any
/// interpolation. Shared by the rules that inspect a literal's value.
func stringLiteralContent(_ node: StringLiteralExprSyntax) -> String {
  var literal = ""
  for segment in node.segments {
    if let stringSegment = segment.as(StringSegmentSyntax.self) {
      literal += stringSegment.content.text
    }
  }
  return literal
}

func location(for position: AbsolutePosition, converter: SourceLocationConverter) -> (
  line: Int, column: Int
) {
  let resolved = converter.location(for: position)
  return (resolved.line, resolved.column)
}
