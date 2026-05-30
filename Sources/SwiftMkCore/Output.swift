//
//  Output.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026
//

import Foundation

// MARK: - Output

/// The single output boundary for the engine.
///
/// User-facing gate text flows through `log`/`logError`/`emitStandardOutput`/
/// `emitStandardError`, which write verbatim to the standard streams. The
/// severity methods `debug`/`info`/`notice`/`warning`/`error` are the structured
/// diagnostic channel for runtime boundary functions (process launches, file
/// mutations, cleanup paths); they stay silent unless `SWIFT_MK_LOG_LEVEL`
/// selects them, so routine runs produce no extra noise while the boundaries
/// still have an explicit, auditable place to report.
public enum Output {
    /// Diagnostic severity, ordered from most to least verbose.
    public enum Level: Int, Sendable {
        case debug = 0
        case error = 4
        case info = 1
        case notice = 2
        case warning = 3
    }

    /// Write a line to standard output, terminated by a single newline.
    public static func log(_ message: String) {
        emit(message + "\n", to: .standardOutput)
    }

    /// Write a line to standard error, terminated by a single newline.
    public static func logError(_ message: String) {
        emit(message + "\n", to: .standardError)
    }

    /// Write text verbatim to standard output without adding a newline.
    public static func emitStandardOutput(_ text: String) {
        emit(text, to: .standardOutput)
    }

    /// Write text verbatim to standard error without adding a newline.
    public static func emitStandardError(_ text: String) {
        emit(text, to: .standardError)
    }

    public static func debug(_ message: String) {
        diagnose(message, at: .debug)
    }

    public static func info(_ message: String) {
        diagnose(message, at: .info)
    }

    public static func notice(_ message: String) {
        diagnose(message, at: .notice)
    }

    public static func warning(_ message: String) {
        diagnose(message, at: .warning)
    }

    /// Errors always surface on standard error regardless of the log level, so a
    /// failed boundary or cleanup step is never silently swallowed.
    public static func error(_ message: String) {
        emit(message + "\n", to: .standardError)
    }

    private static let levelEnvironmentName = "SWIFT_MK_LOG_LEVEL"

    private static func thresholdLevel() -> Level? {
        let raw = Env.get(levelEnvironmentName).lowercased()
        switch raw {
        case "debug":
            return .debug
        case "info":
            return .info
        case "notice":
            return .notice
        case "warning":
            return .warning
        case "error":
            return .error
        default:
            return nil
        }
    }

    private static func diagnose(_ message: String, at level: Level) {
        guard let threshold = thresholdLevel(), level.rawValue >= threshold.rawValue else {
            return
        }
        emit(message + "\n", to: .standardError)
    }

    private enum Stream {
        case standardError
        case standardOutput
    }

    private static func emit(_ text: String, to stream: Stream) {
        let handle: FileHandle
        switch stream {
        case .standardError:
            handle = FileHandle.standardError
        case .standardOutput:
            handle = FileHandle.standardOutput
        }
        handle.write(Data(text.utf8))
    }
}
