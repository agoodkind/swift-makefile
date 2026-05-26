import ArgumentParser
import Foundation
import SwiftMkCore
import SwiftMkRenderCore

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
            BaselineCommand.self, NoticeCommand.self, Render.self,
        ]
    )
}

private func gate(_ body: (PathContext) -> Bool) throws {
    if !body(PathContext.current()) { throw ExitCode(1) }
}

struct LintCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint")

    func run() throws { try gate(Lint.runLint) }
}

struct LintTools: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-tools")

    func run() throws { try gate(Lint.runTools) }
}

struct LintSwiftlint: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-swiftlint")

    func run() throws { try gate(Lint.runSwiftlint) }
}

struct LintFormat: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-format")

    func run() throws { try gate(Lint.runFormat) }
}

struct LintComplexity: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-complexity")

    func run() throws { try gate(Lint.runComplexity) }
}

struct LintDeadcode: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-deadcode")

    func run() throws { try gate(Lint.runDeadcode) }
}

struct LintFiles: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-files")

    func run() throws { try gate(Lint.runLintFiles) }
}

struct LintDiff: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-diff")

    func run() throws { try gate(Lint.runLintDiff) }
}

struct LintSwiftlintScope: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint-swiftlint-scope")

    @Option(name: .long) var rule: String?

    func run() throws {
        if let rule { setenv("RULE", rule, 1) }
        try gate(Lint.runSwiftlintScope)
    }
}

struct SwiftcheckExtra: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "swiftcheck-extra")

    func run() throws { try gate(Swiftcheck.runGate) }
}

struct SwiftcheckExtraBin: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "swiftcheck-extra-bin")

    func run() throws { if !Swiftcheck.resolveBin() { throw ExitCode(1) } }
}

struct Fmt: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fmt")

    func run() throws { try gate(Lint.runFmt) }
}

struct TestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "test")

    func run() throws { try gate(Lint.runTest) }
}

struct Audit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "audit")

    func run() throws { try gate(Lint.runAudit) }
}

struct LogAudit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log-audit")

    func run() throws { try gate(Lint.runLogAudit) }
}

struct BaselineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "baseline")

    @Argument var component: String = "all"
    @Option(name: .long) var rule: String?

    func run() throws {
        if let rule { setenv("RULE", rule, 1) }
        try BaselineRunner.update(component: component, context: PathContext.current())
    }
}

struct NoticeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "notice")

    func run() {
        Output.info("notice: applying notices")
        Notice.run(context: PathContext.current())
    }
}

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
