//
//  DeadcodeScan.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - DeadcodeScan

/// Extends the dead-code gate to Xcode targets. `periphery`'s package scan covers
/// the Swift package; this adds a scan of the Xcode project's schemes by reusing
/// the build's index store, so app targets are analyzed without `periphery`
/// rebuilding them and without knowing any build settings.
enum DeadcodeScan {
    // MARK: Constants

    private static let workspaceExtension = "xcworkspace"
    private static let projectExtension = "xcodeproj"
    private static let manifestFiles = ["Project.swift", "Workspace.swift", "project.yml"]
    private static let hardFailStatus: Int32 = 2

    // MARK: Project shape

    /// An Xcode project on disk and whether it is a workspace.
    struct ProjectRef: Equatable {
        let path: String
        let isWorkspace: Bool
    }

    /// The Xcode project shape of the working directory, decided after generation.
    enum ProjectShape: Equatable {
        case manifestWithoutProject(manifest: String)
        case project(ProjectRef)
        case swiftPMOnly
    }

    // MARK: Entry point

    /// Append Xcode dead-code findings to `rawPath`. Does nothing for a SwiftPM-only
    /// repo. Escalates `GateStatus.last` to a hard-fail status when the repo declares
    /// an Xcode project the gate cannot scan, so `runDeadcode` fails loudly.
    static func appendXcodeFindings(rawPath: String) {
        Output.debug("deadcode: resolving Xcode project shape")
        ensureProjectGenerated()
        switch projectShape() {
        case .swiftPMOnly:
            Output.debug("deadcode: SwiftPM-only repo, no Xcode scan")
        case .manifestWithoutProject(let manifest):
            failHard(
                rawPath: rawPath,
                message:
                    "lint-deadcode: \(manifest) declares an Xcode project but none was "
                    + "generated; set SWIFT_GENERATE_CMD so the project is produced before "
                    + "the gate runs")
        case .project(let reference):
            scanProject(
                path: reference.path, isWorkspace: reference.isWorkspace, rawPath: rawPath)
        }
    }

    // MARK: Generation

    /// Bring an Xcode project onto disk when one is declared but absent. Prefers the
    /// consumer's `SWIFT_GENERATE_CMD`, which may do pre-work, and falls back to the
    /// generator that matches the manifest.
    static func ensureProjectGenerated() {
        if onDiskProject() != nil {
            return
        }
        let generateCommand = Env.get("SWIFT_GENERATE_CMD")
        if !generateCommand.isEmpty {
            Output.info("deadcode: generating Xcode project via SWIFT_GENERATE_CMD")
            let result = Shell.sh(generateCommand)
            if result.status != 0 {
                Output.error(
                    "deadcode: SWIFT_GENERATE_CMD failed status=\(result.status)")
            }
            return
        }
        guard let manifest = firstManifest() else {
            return
        }
        runGenerator(forManifest: manifest)
    }

    /// The generator command for a manifest: XcodeGen for `project.yml`, Tuist for a
    /// Tuist manifest.
    static func generatorCommand(
        forManifest manifest: String
    ) -> (tool: String, arguments: [String]) {
        if manifest == "project.yml" {
            return ("xcodegen", ["generate"])
        }
        return ("tuist", ["generate", "--no-open"])
    }

    /// Run the generator matching a manifest.
    static func runGenerator(forManifest manifest: String) {
        Output.info("deadcode: generating Xcode project from \(manifest)")
        let command = generatorCommand(forManifest: manifest)
        let result = Shell.run(command.tool, command.arguments)
        if result.status != 0 {
            Output.error(
                "deadcode: generator for \(manifest) failed status=\(result.status)")
        }
    }

    // MARK: Classification

    /// Classify the working directory once generation has been attempted.
    static func projectShape() -> ProjectShape {
        if let project = onDiskProject() {
            return .project(project)
        }
        if let manifest = firstManifest() {
            return .manifestWithoutProject(manifest: manifest)
        }
        return .swiftPMOnly
    }

    /// The Xcode project on disk in the working directory, preferring a workspace,
    /// since a workspace lists the superset of schemes.
    static func onDiskProject() -> ProjectRef? {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: ".")
        } catch {
            Output.error("deadcode: could not list working directory: \(error)")
            return nil
        }
        let workspace = entries.filter { $0.hasSuffix(".\(workspaceExtension)") }.min()
        if let workspace {
            return ProjectRef(path: workspace, isWorkspace: true)
        }
        let project = entries.filter { $0.hasSuffix(".\(projectExtension)") }.min()
        if let project {
            return ProjectRef(path: project, isWorkspace: false)
        }
        return nil
    }

    /// The first project-defining manifest present in the working directory.
    static func firstManifest() -> String? {
        for manifest in manifestFiles where FileManager.default.fileExists(atPath: manifest) {
            return manifest
        }
        return nil
    }

    // MARK: Scan

    private static func scanProject(path: String, isWorkspace: Bool, rawPath: String) {
        let schemes = discoverSchemes(project: path, isWorkspace: isWorkspace)
        let packageTargets = packageTargetNames()
        let scanSchemes = schemesToScan(schemes, packageTargets: packageTargets)
        guard !scanSchemes.isEmpty else {
            failHard(
                rawPath: rawPath,
                message: "lint-deadcode: no Xcode schemes to scan in \(path)")
            return
        }
        guard let indexStore = ensureIndexStore(rawPath: rawPath) else {
            return
        }
        runPeriphery(
            project: path,
            schemes: scanSchemes,
            excludeTargets: Array(packageTargets).sorted(),
            indexStore: indexStore,
            rawPath: rawPath)
    }

    /// The schemes to scan: every Xcode scheme whose name is not a Swift package
    /// target, since the package scan owns the package targets.
    static func schemesToScan(_ schemes: [String], packageTargets: Set<String>) -> [String] {
        schemes.filter { !packageTargets.contains($0) }
    }

    /// The command that builds the targets to cover. Prefers `SWIFT_DEADCODE_BUILD_CMD`
    /// for a repo whose `SWIFT_BUILD_CMD` needs a target argument or builds a single
    /// platform, and falls back to `SWIFT_BUILD_CMD`.
    static func coverageBuildCommand() -> String {
        let deadcodeBuild = Env.get("SWIFT_DEADCODE_BUILD_CMD")
        if !deadcodeBuild.isEmpty {
            return deadcodeBuild
        }
        return Env.get("SWIFT_BUILD_CMD")
    }

    /// Refresh and locate the build's index store. The build always runs so the
    /// index reflects the current sources; an incremental build only recompiles
    /// what changed, so a result is never carried over from a stale store. A repo
    /// with an Xcode project and no `SWIFT_BUILD_CMD` cannot produce one, which is a
    /// hard fail.
    static func ensureIndexStore(rawPath: String) -> String? {
        let derivedData = Env.get("SWIFT_MK_DERIVED_DATA")
        let buildCommand = coverageBuildCommand()
        guard !buildCommand.isEmpty else {
            failHard(
                rawPath: rawPath,
                message:
                    "lint-deadcode: an Xcode project exists but SWIFT_BUILD_CMD is unset; "
                    + "set it so the index store is produced under SWIFT_MK_DERIVED_DATA")
            return nil
        }
        Output.info("deadcode: building via SWIFT_BUILD_CMD to refresh the index store")
        let result = Shell.sh(buildCommand)
        if result.status != 0 {
            Output.error("deadcode: SWIFT_BUILD_CMD failed status=\(result.status)")
        }
        if let produced = existingIndexStore(derivedData) {
            return produced
        }
        failHard(
            rawPath: rawPath,
            message:
                "lint-deadcode: no index store under \(derivedData) after SWIFT_BUILD_CMD; "
                + "ensure the build passes -derivedDataPath $(SWIFT_MK_DERIVED_DATA)")
        return nil
    }

    static func existingIndexStore(_ derivedData: String) -> String? {
        guard !derivedData.isEmpty else {
            return nil
        }
        let candidates = [
            "\(derivedData)/Index.noindex/DataStore",
            "\(derivedData)/Index/DataStore",
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private static func runPeriphery(
        project: String,
        schemes: [String],
        excludeTargets: [String],
        indexStore: String,
        rawPath: String
    ) {
        Output.debug(
            "deadcode: periphery xcode scan project=\(project) schemes=\(schemes.count)")
        let configPath = Env.get("SWIFT_MK_PERIPHERY_CONFIG", ".make/periphery.yml")
        var arguments = [
            "scan", "--config", configPath, "--strict", "--skip-build",
            "--skip-schemes-validation", "--index-store-path", indexStore,
            "--project", project,
        ]
        for scheme in schemes {
            arguments += ["--schemes", scheme]
        }
        for target in excludeTargets {
            arguments += ["--exclude-targets", target]
        }
        let result = Shell.run(
            Env.get("PERIPHERY", "periphery"), arguments, environment: Lint.lintEnvironment())
        appendCombined(result.combined, to: rawPath)
        if result.status >= hardFailStatus {
            GateStatus.last = result.status
        }
    }

    // MARK: Discovery

    /// Scheme names from `xcodebuild -list -json`.
    static func discoverSchemes(project: String, isWorkspace: Bool) -> [String] {
        Output.debug("deadcode: listing schemes for \(project)")
        let flag = isWorkspace ? "-workspace" : "-project"
        let result = Shell.run("xcodebuild", ["-list", "-json", flag, project])
        if result.status != 0 {
            Output.error("deadcode: xcodebuild -list failed status=\(result.status)")
            return []
        }
        return parseSchemes(result.stdout)
    }

    static func parseSchemes(_ json: String) -> [String] {
        do {
            let decoded = try JSONDecoder().decode(XcodeList.self, from: jsonData(json))
            return decoded.project?.schemes ?? decoded.workspace?.schemes ?? []
        } catch {
            Output.error("deadcode: could not parse xcodebuild -list json: \(error)")
            return []
        }
    }

    /// Swift package target names from `swift package describe --type json`, used to
    /// drop package targets from the Xcode scan since the package scan owns them.
    static func packageTargetNames() -> Set<String> {
        Output.debug("deadcode: reading swift package targets")
        let result = Shell.run("swift", ["package", "describe", "--type", "json"])
        if result.status != 0 {
            Output.debug("deadcode: swift package describe failed; no package targets to exclude")
            return []
        }
        return parsePackageTargets(result.stdout)
    }

    static func parsePackageTargets(_ json: String) -> Set<String> {
        do {
            let decoded = try JSONDecoder().decode(PackageDescription.self, from: jsonData(json))
            return Set(decoded.targets.map(\.name))
        } catch {
            Output.error("deadcode: could not parse swift package describe json: \(error)")
            return []
        }
    }

    // MARK: Helpers

    /// Bytes from the first `{` onward, so a tool that prints a preamble before its
    /// JSON still decodes.
    static func jsonData(_ text: String) -> Data {
        guard let brace = text.firstIndex(of: "{") else {
            return Data(text.utf8)
        }
        return Data(text[brace...].utf8)
    }

    private static func appendCombined(_ text: String, to path: String) {
        var existing = ""
        if FileManager.default.fileExists(atPath: path) {
            do {
                existing = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                Output.error("deadcode: could not read \(path): \(error)")
            }
        }
        do {
            try (existing + text).write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            Output.error("deadcode: could not append to \(path): \(error)")
        }
    }

    private static func failHard(rawPath: String, message: String) {
        Output.error(message)
        appendCombined(message + "\n", to: rawPath)
        GateStatus.last = hardFailStatus
    }
}

// MARK: - XcodeList

/// The shape of `xcodebuild -list -json`: a top-level `project` or `workspace`
/// object carrying the scheme names.
struct XcodeList: Decodable {
    struct Container: Decodable {
        let schemes: [String]?
    }

    let project: Container?
    let workspace: Container?
}

// MARK: - PackageDescription

/// The subset of `swift package describe --type json` the gate reads: the target
/// names of the Swift package.
struct PackageDescription: Decodable {
    struct Target: Decodable {
        let name: String
    }

    let targets: [Target]
}
