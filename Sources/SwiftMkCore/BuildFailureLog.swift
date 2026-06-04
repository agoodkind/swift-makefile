//
//  BuildFailureLog.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - BuildFailureLog

/// Persists a failed dead-code build's output and extracts its compiler errors.
///
/// The dead-code gate builds the project to refresh the Xcode index store. A
/// failed build leaves a partial index, so the gate must not scan it. This saves
/// the full build output under a trace-scoped name, so the failure is reachable
/// from the run's printed trace id, and pulls the compiler-error lines so the
/// cause is visible without opening the file.
enum BuildFailureLog {
    private static let keepCount = 5

    /// Write `output` to `<logDirectory>/deadcode-build.<traceID>.log`, prune old
    /// build logs, and return the path. Returns nil when the write fails.
    static func write(output: String, logDirectory: String, traceID: String) -> String? {
        let path = "\(logDirectory)/deadcode-build.\(traceID).log"
        do {
            try FileManager.default.createDirectory(
                atPath: logDirectory, withIntermediateDirectories: true)
            try output.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            Output.error("deadcode: could not write build log: \(error)")
            return nil
        }
        prune(in: logDirectory)
        return path
    }

    /// The lines that name the failure: compiler errors and the build-failed
    /// banner, in source order.
    static func errorLines(in output: String) -> [String] {
        var lines: [String] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let isError = line.contains("error:")
            let isBanner = line.contains("** BUILD FAILED **")
            let isSummary = line.contains("The following build commands failed")
            if isError || isBanner || isSummary {
                lines.append(line)
            }
        }
        return lines
    }

    /// Keep the most recent build logs and remove older ones so the log directory
    /// does not grow without bound.
    private static func prune(in directory: String) {
        let fileManager = FileManager.default
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: directory)
        } catch {
            Output.error("deadcode: could not list build logs to prune: \(error)")
            return
        }
        let logs = entries.filter { name in
            name.hasPrefix("deadcode-build.") && name.hasSuffix(".log")
        }
        let newestFirst = logs.sorted { first, second in
            modificationDate(of: "\(directory)/\(first)")
                > modificationDate(of: "\(directory)/\(second)")
        }
        for name in newestFirst.dropFirst(keepCount) {
            do {
                try fileManager.removeItem(atPath: "\(directory)/\(name)")
            } catch {
                Output.error("deadcode: could not prune build log \(name): \(error)")
            }
        }
    }

    private static func modificationDate(of path: String) -> Date {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return attributes[.modificationDate] as? Date ?? Date.distantPast
        } catch {
            return Date.distantPast
        }
    }
}
