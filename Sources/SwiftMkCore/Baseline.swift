import Foundation

/// Baseline update mode.
public enum BaselineMode: String, Sendable {
    case acceptNew
    case pruneFixed
    case sync

    public init?(argument: String) {
        switch argument {
        case "sync": self = .sync
        case "prune-fixed", "remove-fixed": self = .pruneFixed
        case "accept-new": self = .acceptNew
        default: return nil
        }
    }
}

/// Reads, compares, and rewrites baseline files.
///
/// Port of `scripts/swift-mk-baseline.awk` and the baseline helpers in
/// `scripts/swift-mk-common.sh`. A baseline line is
/// `finding<TAB># <label>:first_added=<ISO8601Z> last_seen=<ISO8601Z>`.
public enum Baseline {
    /// Match-everything sentinel for the location coordinate inside a key.
    private struct Entry {
        var finding: String
        var fullLine: String
        var firstAdded: String
    }

    /// Key used while rewriting a baseline: strip `../` and blank `:line:col:`.
    static func writeKey(_ finding: String) -> String {
        Findings.key(finding, pwd: "", cwd: "")
    }

    public static func iso8601Now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date())
    }

    private static let firstAddedPrefix = "first_added="

    private static func firstAdded(fromMetadata metadata: String) -> String {
        let fields = metadata.split(separator: " ", omittingEmptySubsequences: true)
        for field in fields where field.hasPrefix(firstAddedPrefix) {
            return String(field.dropFirst(firstAddedPrefix.count))
        }
        return ""
    }

    private static func inScope(_ finding: String, scope: Regex<AnyRegexOutput>?) -> Bool {
        guard let scope else { return true }
        do {
            return try scope.firstMatch(in: finding) != nil
        } catch {
            return false
        }
    }

    /// Rewrite a baseline file from the current findings under the given mode,
    /// preserving out-of-scope rows when a scope pattern is set.
    public static func writeBaselineFile(_ request: BaselineWriteRequest) throws {
        let scope = Text.compile(request.scopePattern)
        let marker = "\t# \(request.label):"
        let now = request.now

        var currentOrder: [String] = []
        var currentFinding: [String: String] = [:]
        for line in Text.readLines(request.findingsPath) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            let key = writeKey(line)
            if currentFinding[key] == nil { currentOrder.append(key) }
            currentFinding[key] = line
        }

        var oldOrder: [String] = []
        var oldEntry: [String: Entry] = [:]
        for line in Text.readLines(request.oldBaselinePath) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            var finding = line
            var metadata = ""
            if let markerRange = line.range(of: marker) {
                finding = String(line[line.startIndex..<markerRange.lowerBound])
                metadata = String(line[markerRange.upperBound...])
            }
            if finding.isEmpty { continue }
            let key = writeKey(finding)
            if oldEntry[key] == nil { oldOrder.append(key) }
            oldEntry[key] = Entry(
                finding: finding, fullLine: line, firstAdded: firstAdded(fromMetadata: metadata)
            )
        }

        func renderedCurrent(_ key: String) -> String {
            guard let finding = currentFinding[key] else { return "" }
            let priorAdded = oldEntry[key]?.firstAdded ?? ""
            let added = priorAdded.isEmpty ? now : priorAdded
            return "\(finding)\t# \(request.label):first_added=\(added) last_seen=\(now)"
        }

        func oldOutsideScope() -> [String] {
            guard scope != nil else { return [] }
            return oldOrder.compactMap { key in
                guard currentFinding[key] == nil, let entry = oldEntry[key] else { return nil }
                return inScope(entry.finding, scope: scope) ? nil : entry.fullLine
            }
        }

        var out: [String] = ["# \(request.title): generated_at=\(now)"]
        switch request.mode {
        case .sync:
            out += currentOrder.map(renderedCurrent)
            out += oldOutsideScope()
        case .pruneFixed:
            out += currentOrder.filter { oldEntry[$0] != nil }.map(renderedCurrent)
            out += oldOutsideScope()
        case .acceptNew:
            out += currentOrder.map(renderedCurrent)
            out += oldOrder.compactMap { key in
                guard currentFinding[key] == nil else { return nil }
                return oldEntry[key]?.fullLine
            }
        }

        try (out.joined(separator: "\n") + "\n").write(
            toFile: request.outputPath, atomically: true, encoding: .utf8
        )
    }
}
