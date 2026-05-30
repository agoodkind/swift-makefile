//
//  Notice.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//

import Foundation

// MARK: - Notice

/// Announce changes and auto-baseline a newly introduced rule's slice.
///
/// `notices.txt` records are `id<TAB>directive<TAB>summary`. A directive of `-`
/// announces only; `GATE=swiftlint RULE=<id>` declares an auto-baseline scope.
/// Applied ids live in the committed `.swift-mk-applied-notices`; the last
/// printed id lives in gitignored `.make/.swift-mk-notice-seen`.
public enum Notice {
    static let seenPath = ".make/.swift-mk-notice-seen"
    private static let directiveFieldIndex = 1
    private static let summaryFieldIndex = 2
    private static let minimumDirectiveFieldCount = 2
    private static let minimumSummaryFieldCount = 3
    private static let gatePrefix = "GATE="
    private static let rulePrefix = "RULE="
    private static let patternPrefix = "PATTERN="

    static func noticesPath() -> String { Env.get("SWIFT_MK_NOTICES_FILE", ".make/notices.txt") }

    static func appliedPath() -> String {
        Env.get("SWIFT_MK_APPLIED_NOTICES", ".swift-mk-applied-notices")
    }

    static func stderr(_ message: String) {
        Output.emitStandardError("\(message)\n")
    }

    public static func run(context: PathContext) {
        let noticesFile = noticesPath()
        guard FileManager.default.fileExists(atPath: noticesFile) else { return }

        var applied = Set(
            Text.readLines(appliedPath())
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        let lastSeen = Int(Text.readLines(seenPath).first ?? "") ?? 0
        var maxSeen = lastSeen

        for line in Text.readLines(noticesFile) {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.components(separatedBy: "\t")
            guard let id = fields.first, let idNumber = Int(id) else { continue }
            let directive =
                fields.count >= minimumDirectiveFieldCount ? fields[directiveFieldIndex] : "-"
            let summary =
                fields.count >= minimumSummaryFieldCount ? fields[summaryFieldIndex] : ""

            if directive != "-", !directive.isEmpty, !applied.contains(id) {
                runAutoBaseline(id: id, directive: directive, context: context)
                applied.insert(id)
            }
            if idNumber > lastSeen {
                stderr("swift-makefile notice #\(id): \(summary)")
            }
            if idNumber > maxSeen { maxSeen = idNumber }
        }

        Capture.ensureMakeDir()
        do {
            try "\(maxSeen)\n".write(toFile: seenPath, atomically: true, encoding: .utf8)
        } catch {
            Output.error("notice: could not write \(seenPath): \(error)")
        }
    }

    static func runAutoBaseline(id: String, directive: String, context: PathContext) {
        var gate = "swiftlint"
        var rule = ""
        var pattern = ""
        for token in directive.split(separator: " ") {
            if token.hasPrefix(gatePrefix) {
                gate = String(token.dropFirst(gatePrefix.count))
            } else if token.hasPrefix(rulePrefix) {
                rule = String(token.dropFirst(rulePrefix.count))
            } else if token.hasPrefix(patternPrefix) {
                pattern = String(token.dropFirst(patternPrefix.count))
            }
        }
        guard gate == "swiftlint" else {
            stderr(
                "swift-makefile notice #\(id): unsupported auto-baseline gate '\(gate)'; skipping")
            return
        }
        stderr("swift-makefile notice #\(id): auto-baselining existing findings for \(directive)")
        setenv("RULE", rule, 1)
        setenv("SWIFTLINT_BASELINE_SCOPE_PATTERN", pattern, 1)
        let baseline = Env.get("SWIFTLINT_BASELINE", ".swiftlint-baseline.txt")
        do {
            try BaselineRunner.autoBaselineSwiftlintScope(context: context)
            appendApplied(id)
            stderr(
                "swift-makefile notice #\(id): wrote \(baseline). "
                    + "Review with 'git diff \(baseline)' and commit it together with \(appliedPath())."
            )
        } catch {
            Output.error(
                "swift-makefile notice #\(id): auto-baseline failed; run the scoped baseline target manually"
            )
        }
    }

    static func appendApplied(_ id: String) {
        var ids = Text.readLines(appliedPath())
        ids.append(id)
        do {
            try Text.writeLines(ids, to: appliedPath())
        } catch {
            Output.error("notice: could not write \(appliedPath()): \(error)")
        }
    }
}
