//
//  main.swift
//  swiftcheck-extra
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//

import Foundation
import SwiftCheckCore

// MARK: - CLIError

enum CLIError: Error, CustomStringConvertible {
    case unknownFlag(String)

    var description: String {
        switch self {
        case .unknownFlag(let flag):
            return "unknown flag \(flag)"
        }
    }
}

func writeStandardOutputLine(_ line: String) {
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
}

func parseOptions() throws -> (rules: Set<Rule>, paths: [String]) {
    var enabledRules = Set<Rule>()
    var paths: [String] = []

    for argument in CommandLine.arguments.dropFirst() {
        if argument == "-flags" {
            for ruleName in availableRuleNames() {
                writeStandardOutputLine("Name: \(ruleName)")
            }
            exit(0)
        }
        if argument.hasPrefix("-") {
            let flag = String(argument.dropFirst())
            guard let rule = Rule(rawValue: flag) else {
                throw CLIError.unknownFlag(argument)
            }
            enabledRules.insert(rule)
            continue
        }
        paths.append(argument)
    }

    if enabledRules.isEmpty {
        enabledRules = Set(Rule.allCases)
    }
    if paths.isEmpty {
        paths = ["."]
    }

    return (enabledRules, paths)
}

do {
    let options = try parseOptions()
    let violations = try scan(paths: options.paths, enabledRules: options.rules)
    for violation in violations {
        writeStandardOutputLine(violation.renderedLine)
    }
    exit(violations.isEmpty ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("swiftcheck-extra: \(error)\n".utf8))
    exit(1)
}
