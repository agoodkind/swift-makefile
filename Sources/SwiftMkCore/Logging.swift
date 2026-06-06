//
//  Logging.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-03.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Logging

/// The run's correlation and per-concern log files, mirroring the go engine.
///
/// The first swift-mk process of a run mints the trace, prints the one-line
/// header, and exports the traceparent so child processes it spawns join the
/// same trace and stay quiet. Every diagnostic record is also written to a
/// per-concern JSONL file under `.make/logs`, carrying the run's trace and span
/// ids, so a failure is traceable from the printed header. Auxiliary subcommands
/// that run as make prerequisites, such as `notice`, never print the header.
public enum Logging {
    /// The per-concern JSONL directory every run writes under.
    public static let logDirectory = ".make/logs"

    private static let sentinelPath = ".make/logs/.run"
    private static let fallbackConcern = "swift-mk"
    private static let headerlessCommands: Set<String> = [
        "notice", "signing-xcconfig", "signing-identity",
    ]

    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var recording = false
    nonisolated(unsafe) private static var correlationValue = Correlation.new()

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The run's correlation, resolving it on first use.
    public static var correlation: Correlation {
        ensureStarted()
        return correlationValue
    }

    /// Resolve the run's trace once: adopt an inherited traceparent or mint a new
    /// one and export it for child processes, then print the header unless this is
    /// an auxiliary subcommand. swift-mk runs single-threaded, so the started flag
    /// needs no lock.
    public static func ensureStarted() {
        if started {
            return
        }
        started = true
        let inherited = Env.get("TRACEPARENT")
        if let adopted = Correlation.fromTraceparent(inherited) {
            correlationValue = adopted
        } else {
            correlationValue = Correlation.new()
            setenv("TRACEPARENT", correlationValue.traceparent, 1)
        }
        if !isHeaderless() {
            printHeaderOnce(correlationValue)
        }
        // Export the run's span when a collector endpoint is set. The exporter
        // adopts the run's trace id, so a collector sees the same trace id the
        // header prints. The flush runs at process exit through atexit, which
        // fires even though the CLI subcommands return rather than call exit.
        OTelExport.start(correlationValue)
        atexit { OTelExport.shutdown() }
    }

    /// Append one diagnostic record to its per-concern JSONL file. The concern is
    /// the first dot-segment of the message, mirroring the go router. The recording
    /// guard drops a re-entrant call, so a write failure that reports through
    /// Output cannot recurse back into a record.
    public static func record(_ message: String, level: String) {
        ensureStarted()
        if recording {
            return
        }
        recording = true
        defer { recording = false }
        let current = correlationValue
        let payload: [String: String] = [
            "time": timestampFormatter.string(from: Date()),
            "level": level,
            "msg": message,
            "trace_id": current.traceID,
            "span_id": current.spanID,
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            Output.error("swift-mk logging: encode record: \(error)")
            return
        }
        guard let line = String(data: data, encoding: .utf8) else {
            return
        }
        appendLine(line, toConcern: concern(of: message))
    }

    private static func isHeaderless() -> Bool {
        for argument in CommandLine.arguments.dropFirst() {
            if argument.hasPrefix("-") {
                continue
            }
            return headerlessCommands.contains(argument)
        }
        return false
    }

    private static func printHeaderOnce(_ correlation: Correlation) {
        if alreadyPrinted(correlation.traceID) {
            return
        }
        ensureLogDirectory()
        do {
            try correlation.traceID.write(toFile: sentinelPath, atomically: true, encoding: .utf8)
        } catch {
            Output.error("swift-mk logging: write run sentinel: \(error)")
        }
        let ids = "trace_id=\(correlation.traceID) span_id=\(correlation.spanID)"
        let header = "🔎 logs=\(logDirectory) \(ids)\n"
        FileHandle.standardError.write(Data(header.utf8))
    }

    private static func alreadyPrinted(_ traceID: String) -> Bool {
        guard FileManager.default.fileExists(atPath: sentinelPath) else {
            return false
        }
        do {
            let previous = try String(contentsOfFile: sentinelPath, encoding: .utf8)
            return previous.trimmingCharacters(in: .whitespacesAndNewlines) == traceID
        } catch {
            Output.error("swift-mk logging: read run sentinel: \(error)")
            return false
        }
    }

    private static func concern(of message: String) -> String {
        // swift-mk diagnostics use a "<concern>: detail" or "<concern> detail"
        // form, so the concern is the leading token up to the first colon or
        // space. That splits records into per-concern files such as lint.jsonl
        // and audit.jsonl, mirroring the go router.
        let boundary = message.firstIndex { $0 == ":" || $0 == " " }
        if let boundary, boundary != message.startIndex {
            return String(message[message.startIndex..<boundary])
        }
        return fallbackConcern
    }

    private static func appendLine(_ line: String, toConcern concern: String) {
        ensureLogDirectory()
        let path = "\(logDirectory)/\(concern).jsonl"
        let data = Data((line + "\n").utf8)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            FileManager.default.createFile(atPath: path, contents: data)
            return
        }
        handle.seekToEndOfFile()
        handle.write(data)
        do {
            try handle.close()
        } catch {
            Output.error("swift-mk logging: close log file: \(error)")
        }
    }

    private static func ensureLogDirectory() {
        do {
            try FileManager.default.createDirectory(
                atPath: logDirectory, withIntermediateDirectories: true)
        } catch {
            Output.error("swift-mk logging: create log directory: \(error)")
        }
    }
}
