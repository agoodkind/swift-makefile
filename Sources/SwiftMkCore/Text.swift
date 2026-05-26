import Foundation

/// Path-normalization context: the working directory and project root, each
/// with a trailing slash, matching the `pwd`/`cwd` variables the awk receives.
public struct PathContext: Sendable {
    public let pwd: String
    public let cwd: String

    public init(pwd: String, cwd: String) {
        self.pwd = pwd
        self.cwd = cwd
    }

    public static func current() -> PathContext {
        let workingDirectory = FileManager.default.currentDirectoryPath
        let root = ProcessInfo.processInfo.environment["SWIFT_MK_ROOT"] ?? workingDirectory
        return PathContext(pwd: workingDirectory + "/", cwd: root + "/")
    }
}

/// File and regex helpers shared by the lint and baseline engines.
public enum Text {
    public static func readLines(_ path: String) -> [String] {
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return []
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    public static func writeLines(_ lines: [String], to path: String) throws {
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Join comma-separated default and extra patterns into one ERE alternation.
    public static func excludePattern(_ defaults: String, _ extra: String) -> String {
        let combined = defaults + "," + extra
        return
            combined
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    static func compile(_ pattern: String) -> Regex<AnyRegexOutput>? {
        guard !pattern.isEmpty else { return nil }
        do {
            return try Regex(pattern)
        } catch {
            return nil
        }
    }

    /// Drop lines matching the pattern (grep -Ev). Empty pattern keeps all.
    public static func filterExclude(_ lines: [String], _ pattern: String) -> [String] {
        guard let regex = compile(pattern) else { return lines }
        return lines.filter { !$0.contains(regex) }
    }

    /// Keep lines matching the pattern (grep -E). Empty pattern keeps all.
    public static func filterScope(_ lines: [String], _ pattern: String) -> [String] {
        guard let regex = compile(pattern) else { return lines }
        return lines.filter { $0.contains(regex) }
    }

    /// Sorted unique values (sort -u).
    public static func sortedUnique(_ lines: [String]) -> [String] {
        Array(Set(lines)).sorted()
    }
}
