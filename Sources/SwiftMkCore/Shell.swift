//
//  Shell.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Shell

/// Run external programs and capture their output.
public enum Shell {
    /// Exit status used when a program cannot be launched, matching the shell
    /// convention for "command not found".
    private static let launchFailureStatus: Int32 = 127

    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        /// stdout followed by stderr, matching `swift_mk_run_capture`.
        public var combined: String { stdout + stderr }
    }

    /// Run a program found on PATH (or an absolute path) with arguments. An
    /// empty `environment` inherits the current process environment unchanged.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String] = [:]
    ) -> Result {
        Output.debug("Shell.run \(executable) \(arguments.joined(separator: " "))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if !environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return Result(status: launchFailureStatus, stdout: "", stderr: "\(error)\n")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(bytes: outData, encoding: .utf8) ?? "",
            stderr: String(bytes: errData, encoding: .utf8) ?? ""
        )
    }

    /// Run a command string through `/bin/sh -c`. An empty `environment` inherits the
    /// current process environment unchanged; a non-empty one is merged over it.
    @discardableResult
    public static func sh(_ command: String, environment: [String: String] = [:]) -> Result {
        run("/bin/sh", ["-c", command], environment: environment)
    }
}
