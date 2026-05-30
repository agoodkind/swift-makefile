//
//  main.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//

import ArgumentParser
import Foundation
import SwiftMkCore
import SwiftMkRenderCore

// MARK: - SwiftMk

@main
struct SwiftMk: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-mk",
        abstract: "swift-makefile tooling: lint, baseline, gate, and notices.",
        subcommands: [
            LintCommand.self, LintTools.self, LintSwiftlint.self, LintFormat.self,
            LintComplexity.self, LintDeadcode.self, LintFiles.self, LintDiff.self,
            LintSwiftlintScope.self, SwiftcheckExtra.self, SwiftcheckExtraBin.self,
            Fmt.self, TestCommand.self, Audit.self, LogAudit.self,
            BaselineCommand.self, NoticeCommand.self, Render.self, RenderBatch.self,
        ]
    )
}

private func gate(_ body: (PathContext) -> Bool) throws {
    if !body(PathContext.current()) { throw ExitCode(1) }
}

// MARK: - LintCommand

struct LintCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint")

    func run() throws { try gate(Lint.runLint) }
}

// MARK: - LintTools

struct LintTools: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-tools")

    func run() throws { try gate(Lint.runTools) }
}

// MARK: - LintSwiftlint

struct LintSwiftlint: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-swiftlint")

    func run() throws { try gate(Lint.runSwiftlint) }
}

// MARK: - LintFormat

struct LintFormat: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-format")

    func run() throws { try gate(Lint.runFormat) }
}

// MARK: - LintComplexity

struct LintComplexity: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-complexity")

    func run() throws { try gate(Lint.runComplexity) }
}

// MARK: - LintDeadcode

struct LintDeadcode: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-deadcode")

    func run() throws { try gate(Lint.runDeadcode) }
}

// MARK: - LintFiles

struct LintFiles: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-files")

    func run() throws { try gate(Lint.runLintFiles) }
}

// MARK: - LintDiff

struct LintDiff: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-diff")

    func run() throws { try gate(Lint.runLintDiff) }
}

// MARK: - LintSwiftlintScope

struct LintSwiftlintScope: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-swiftlint-scope")

    @Option(name: .long) var rule: String?

    func run() throws {
        if let rule { setenv("RULE", rule, 1) }
        try gate(Lint.runSwiftlintScope)
    }
}

// MARK: - SwiftcheckExtra

struct SwiftcheckExtra: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "swiftcheck-extra")

    func run() throws { try gate(Swiftcheck.runGate) }
}

// MARK: - SwiftcheckExtraBin

struct SwiftcheckExtraBin: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "swiftcheck-extra-bin")

    func run() throws { if !Swiftcheck.resolveBin() { throw ExitCode(1) } }
}

// MARK: - Fmt

struct Fmt: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fmt")

    func run() throws { try gate(Lint.runFmt) }
}

// MARK: - TestCommand

struct TestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "test")

    func run() throws { try gate(Lint.runTest) }
}

// MARK: - Audit

struct Audit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "audit")

    func run() throws { try gate(Lint.runAudit) }
}

// MARK: - LogAudit

struct LogAudit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log-audit")

    func run() throws { try gate(Lint.runLogAudit) }
}

// MARK: - BaselineCommand

struct BaselineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "baseline")

    @Argument var component: String = "all"
    @Option(name: .long) var rule: String?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of text.") var json = false

    func run() throws {
        if let rule { setenv("RULE", rule, 1) }
        if json { setenv("BASELINE_OUTPUT_FORMAT", "json", 1) }
        try BaselineRunner.update(component: component, context: PathContext.current())
    }
}

// MARK: - NoticeCommand

struct NoticeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "notice")

    func run() {
        Output.info("notice: applying notices")
        Notice.run(context: PathContext.current())
    }
}

// MARK: - Render

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "render")

    @Argument var templatePath: String

    struct Context: Decodable { let values: [String: String] }

    func run() throws {
        let inputData = FileHandle.standardInput.readDataToEndOfFile()
        let context = try JSONDecoder().decode(Context.self, from: inputData)
        let templateText = try String(contentsOfFile: templatePath, encoding: .utf8)
        let rendered = try TemplateRenderer.render(
            templateText: templateText, values: context.values)
        FileHandle.standardOutput.write(Data(rendered.utf8))
    }
}

// MARK: - RenderBatch

struct RenderBatch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render-batch",
        abstract:
            "Render every *.template file under --templates-dir to --output-dir "
            + "using environment variables for [[KEY]] substitutions."
    )

    @Option(name: .customLong("templates-dir"))
    var templatesDir: String

    @Option(name: .customLong("output-dir"))
    var outputDir: String

    @Option(
        name: .customLong("env"),
        parsing: .upToNextOption,
        help: "Names of environment variables to expose as [[KEY]] substitutions."
    )
    var envKeys: [String] = []

    func run() throws {
        Output.info(
            "render-batch: starting templates=\(templatesDir) output=\(outputDir)"
        )
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var values: [String: String] = [:]
        for key in envKeys {
            values[key] = environment[key] ?? ""
        }

        let templatesURL = URL(fileURLWithPath: templatesDir, isDirectory: true)
        var isDir: ObjCBool = false
        guard
            fileManager.fileExists(atPath: templatesURL.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            throw RenderBatchError.templatesDirMissing(templatesURL.path)
        }

        let outputURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        try fileManager.createDirectory(
            at: outputURL, withIntermediateDirectories: true)

        guard
            let enumerator = fileManager.enumerator(
                at: templatesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw RenderBatchError.cannotEnumerate(templatesURL.path)
        }

        let templateSuffix = ".template"
        var renderedCount = 0
        for case let templateURL as URL in enumerator {
            let templateName = templateURL.lastPathComponent
            guard templateName.hasSuffix(templateSuffix) else { continue }
            let templateText = try String(contentsOf: templateURL, encoding: .utf8)
            let rendered = try TemplateRenderer.render(
                templateText: templateText, values: values)
            let outputName = String(templateName.dropLast(templateSuffix.count))
            let outputFileURL = outputURL.appendingPathComponent(outputName)
            try rendered.write(to: outputFileURL, atomically: true, encoding: .utf8)
            renderedCount += 1
        }

        Output.info(
            "render-batch: rendered \(renderedCount) file(s) to \(outputURL.path)"
        )
    }
}

// MARK: - RenderBatchError

private enum RenderBatchError: Error, CustomStringConvertible {
    case cannotEnumerate(String)
    case templatesDirMissing(String)

    var description: String {
        switch self {
        case .cannotEnumerate(let path):
            return "cannot enumerate directory: \(path)"
        case .templatesDirMissing(let path):
            return "templates directory not found: \(path)"
        }
    }
}
