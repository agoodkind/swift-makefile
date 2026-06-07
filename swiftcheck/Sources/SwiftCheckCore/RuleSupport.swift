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
