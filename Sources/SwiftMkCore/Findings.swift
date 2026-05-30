//
//  Findings.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026
//

import Foundation

// MARK: - Findings

/// Finding normalization and keying.
///
/// Port of `scripts/swift-mk-findings.awk`. Paths are normalized relative to the
/// working directory and the project root, and a finding "key" blanks the
/// `:line:column:` coordinate to `:::` so a finding matches across line shifts.
public enum Findings {
    private static var locationPattern: Regex<Substring> { /:[0-9]+:[0-9]+:/ }
    private static let parentDirectoryPrefix = "../"

    /// Strip a leading `pwd/` prefix, then a leading `cwd/` prefix, then any
    /// leading `../` segments.
    public static func normalizePath(_ line: String, pwd: String, cwd: String) -> String {
        var output = line
        if !pwd.isEmpty, output.hasPrefix(pwd) {
            output = String(output.dropFirst(pwd.count))
        }
        if !cwd.isEmpty, output.hasPrefix(cwd) {
            output = String(output.dropFirst(cwd.count))
        }
        while output.hasPrefix(parentDirectoryPrefix) {
            output = String(output.dropFirst(parentDirectoryPrefix.count))
        }
        return output
    }

    /// Replace the first `:line:column:` with `:::` after path normalization.
    public static func key(_ line: String, pwd: String, cwd: String) -> String {
        let normalized = normalizePath(line, pwd: pwd, cwd: cwd)
        guard let range = normalized.firstRange(of: locationPattern) else {
            return normalized
        }
        return normalized.replacingCharacters(in: range, with: ":::")
    }

    /// Extract the finding text from a baseline line, dropping the metadata
    /// suffix `\t# <label>:...`. Returns nil for blank or comment lines.
    public static func baselineFinding(
        _ line: String, label: String, pwd: String, cwd: String
    ) -> String? {
        if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") {
            return nil
        }
        let marker = "\t# \(label):"
        var finding = line
        if let markerRange = line.range(of: marker) {
            finding = String(line[line.startIndex..<markerRange.lowerBound])
        }
        return normalizePath(finding, pwd: pwd, cwd: cwd)
    }

    /// Human display form: a location line and an indented message line.
    public static func rendered(_ line: String, pwd: String, cwd: String) -> String {
        let normalized = normalizePath(line, pwd: pwd, cwd: cwd)
        guard let range = normalized.firstRange(of: locationPattern) else {
            return "  \(normalized)"
        }
        let location = String(
            normalized[normalized.startIndex..<normalized.index(before: range.upperBound)])
        var message = String(normalized[range.upperBound...])
        message = message.drop { $0 == " " || $0 == "\t" }.description
        return "  \(location)\n    \(message)"
    }

    // MARK: PathContext convenience

    public static func normalizePath(_ line: String, _ context: PathContext) -> String {
        normalizePath(line, pwd: context.pwd, cwd: context.cwd)
    }

    public static func key(_ line: String, _ context: PathContext) -> String {
        key(line, pwd: context.pwd, cwd: context.cwd)
    }

    public static func baselineFinding(
        _ line: String,
        label: String,
        _ context: PathContext
    ) -> String? {
        baselineFinding(line, label: label, pwd: context.pwd, cwd: context.cwd)
    }

    public static func rendered(_ line: String, _ context: PathContext) -> String {
        rendered(line, pwd: context.pwd, cwd: context.cwd)
    }
}
