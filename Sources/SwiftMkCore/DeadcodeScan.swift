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

  /// Whether to run the Xcode dead-code scan. True only for a consumer that
  /// configures an Xcode build (`SWIFT_MK_XCODE_BUILD == "1"`). A SwiftPM package is
  /// covered by periphery's package scan, and a stray on-disk project (a developer
  /// opening Xcode, a manual tuist run) must not force an Xcode scan that has no
  /// index store to read.
  static func xcodeScanEnabled(_ flag: String) -> Bool {
    flag == "1"
  }

  /// Append Xcode dead-code findings to `rawPath`. Does nothing for a SwiftPM repo.
  /// Escalates `GateStatus.last` to a hard-fail status when the repo declares an
  /// Xcode project the gate cannot scan, so `runDeadcode` fails loudly.
  ///
  /// The Xcode scan runs when the consumer configures an Xcode build
  /// (`SWIFT_MK_XCODE_BUILD == "1"`, the make path) or when the in-process API
  /// supplies a `coverage` callback, which is the decoupled path's signal that this
  /// is an Xcode consumer. With no env flag and no callback it stays a SwiftPM scan.
  static func appendXcodeFindings(rawPath: String, coverage: DeadcodeCoverageBuild? = nil) {
    guard xcodeScanEnabled(Env.get("SWIFT_MK_XCODE_BUILD")) || coverage != nil else {
      Output.debug(
        "deadcode: SwiftPM build (SWIFT_MK_XCODE_BUILD unset), skipping Xcode scan; "
          + "periphery's package scan covers the package")
      return
    }
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
        path: reference.path,
        isWorkspace: reference.isWorkspace,
        rawPath: rawPath,
        coverage: coverage)
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
    if !Env.get("SWIFT_GENERATE_CMD").isEmpty {
      // Shared with the other compile-based gates: runs SWIFT_GENERATE_CMD once
      // per `make lint` (guarded by SWIFT_MK_GENERATED) and surfaces its output on
      // failure, so a generation error is not masked by the later "no project
      // generated" message.
      Lint.ensureGenerated()
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

  private static func scanProject(
    path: String, isWorkspace: Bool, rawPath: String, coverage: DeadcodeCoverageBuild? = nil
  ) {
    let schemes = discoverSchemes(project: path, isWorkspace: isWorkspace)
    let packageTargets = packageTargetNames()
    let scanSchemes = schemesToScan(schemes, packageTargets: packageTargets)
    guard !scanSchemes.isEmpty else {
      failHard(
        rawPath: rawPath,
        message: "lint-deadcode: no Xcode schemes to scan in \(path)")
      return
    }
    // Serialize the coverage build against every other build in this worktree (a make
    // build, a dev-tool SwiftPM build) so two builds never share `.build`/DerivedData
    // and corrupt each other's index store. This per-worktree lock replaces the old
    // dead-code-only `.make/deadcode-build.lock`, and is re-entrant so the coverage
    // build's own nested engine calls do not self-deadlock.
    BuildLock.withLock {
      guard let indexStore = ensureIndexStore(rawPath: rawPath, coverage: coverage) else {
        return
      }
      // A partial index is never scanned: periphery would read a missing
      // reference as a false unused finding. The exact missing list goes to a
      // trace-scoped log, so a failure is debuggable from the run's trace id.
      let outcome = IndexCompleteness.verify(
        indexStorePath: indexStore,
        projectPath: path,
        isWorkspace: isWorkspace,
        excludeTargets: packageTargets)
      switch outcome {
      case .complete(let message):
        Output.info(message)
      case .incomplete(let message):
        failHard(rawPath: rawPath, message: message)
        return
      }
      runPeriphery(
        project: path,
        schemes: scanSchemes,
        excludeTargets: Array(packageTargets).sorted(),
        indexStore: indexStore,
        rawPath: rawPath)
    }
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

  /// Refresh and locate the build's index store, then wait for it to settle.
  /// The build always runs so the index reflects the current sources. Xcode
  /// writes the index store as background indexing finishes, which can lag the
  /// build command's exit, so the scan waits until the store stops growing to
  /// avoid reading a partial store and reporting phantom unused symbols that
  /// clear on a later run. A repo with an Xcode project and no coverage build
  /// (no `SWIFT_DEADCODE_BUILD_CMD`/`SWIFT_BUILD_CMD` and no callback) cannot
  /// produce one, which is a hard fail.
  ///
  /// Two coverage paths share the failure and locate handling. The make path shells
  /// the consumer's `SWIFT_DEADCODE_BUILD_CMD` with the signing-disabled
  /// `DeadcodeBuildConfig` environment. The in-process API path mints a scoped
  /// `DeadcodeCoverageAuthorization` and runs the consumer's `coverage` callback with
  /// the same environment, so a decoupled build with no make ancestor still produces
  /// a complete index without a subprocess.
  static func ensureIndexStore(
    rawPath: String, coverage: DeadcodeCoverageBuild? = nil
  ) -> String? {
    // Absolutize the derived-data root (PR #32) so a relative SWIFT_MK_DERIVED_DATA
    // does not resolve OBJROOT against each SwiftPM package's source root.
    let derivedData = DeadcodeBuildConfig.resolvedDerivedDataRoot(
      Env.get("SWIFT_MK_DERIVED_DATA"))
    // Disable code signing for the coverage build only: it produces the index,
    // not a signed product, and a signed build can fail on provisioning and leave
    // a partial index. swift-mk owns this, so consumers need no configuration.
    let environment = DeadcodeBuildConfig.buildEnvironment(derivedData: derivedData)
    let outcome: (status: Int32, output: String)
    if let coverage {
      // Mint the scoped capability here and hand it plus the signing-disabled
      // environment to the consumer's coverage callback.
      Output.info("deadcode: building via the in-process coverage callback")
      let capability = DeadcodeCoverageAuthorization()
      let result = coverage(capability, environment)
      outcome = (result.status, result.output)
    } else {
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
      let result = Shell.runStreamingStderr(
        "/bin/sh", ["-c", buildCommand], environment: environment)
      outcome = (result.status, result.stdout)
    }
    if outcome.status != 0 {
      diagnoseFailedCoverage(
        rawPath: rawPath,
        status: outcome.status,
        output: outcome.output,
        derivedData: derivedData)
      return nil
    }
    if let produced = existingIndexStore(derivedData) {
      Output.info("deadcode: index store at \(produced)")
      IndexStoreSettle.waitForStable(produced)
      return produced
    }
    failHard(
      rawPath: rawPath,
      message:
        "lint-deadcode: no index store under \(derivedData) after the coverage build; "
        + "ensure the build passes -derivedDataPath $(SWIFT_MK_DERIVED_DATA)")
    return nil
  }

  private static func runPeriphery(
    project: String,
    schemes: [String],
    excludeTargets: [String],
    indexStore: String,
    rawPath: String
  ) {
    Output.info(
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
    Output.info("deadcode: periphery scan finished status=\(result.status)")
    let filtered = filterWitnessFalsePositives(result.combined, indexStore: indexStore)
    appendCombined(filtered, to: rawPath)
    if result.status >= hardFailStatus {
      GateStatus.last = result.status
    }
  }

  // MARK: Discovery

  /// Scheme names from `xcodebuild -list -json`.
  static func discoverSchemes(project: String, isWorkspace: Bool) -> [String] {
    Output.debug("deadcode: listing schemes for \(project)")
    let result = Toolchain.listSchemes(container: project, isWorkspace: isWorkspace)
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

// MARK: - DeadcodeScan

extension DeadcodeScan {
  /// Diagnose a failed coverage build the same way for both coverage paths: save the
  /// transcript under a trace-scoped name, surface the structured compiler errors
  /// from the xcresult bundle, and fail hard so periphery never scans a partial
  /// index. A partial index reads missing references as false "unused" findings, so
  /// the scan must not run.
  static func diagnoseFailedCoverage(
    rawPath: String, status: Int32, output: String, derivedData: String
  ) {
    let logPath = BuildFailureLog.write(
      output: output,
      logDirectory: Logging.logDirectory,
      traceID: Logging.correlation.traceID)
    let errorIssues = buildIssues(derivedData: derivedData).filter { issue in
      issue.severity == "error"
    }
    for issue in errorIssues {
      outputBuildIssue(issue)
    }
    if errorIssues.isEmpty {
      Output.error(
        "deadcode: no structured build issues found; full transcript at "
          + (logPath ?? "(unavailable)"))
    }
    failHard(
      rawPath: rawPath,
      message:
        "lint-deadcode: the coverage build failed status=\(status); the index store is "
        + "incomplete, not scanning; full build output at "
        + (logPath ?? "(build log unavailable)"))
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

  private static func buildIssues(derivedData: String) -> [XCResult.Issue] {
    let trimmed = derivedData.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      return []
    }
    return issues(inBundleDirectory: "\(trimmed)/ResultBundles")
  }

  private static func issues(inBundleDirectory directory: String) -> [XCResult.Issue] {
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return []
    }

    let entries: [String]
    do {
      entries = try FileManager.default.contentsOfDirectory(atPath: directory)
    } catch {
      Output.error("deadcode: could not list \(directory): \(error)")
      return []
    }

    let bundles =
      entries
      .filter { entry in
        entry.hasSuffix(".xcresult")
      }
      .sorted()
    var issues: [XCResult.Issue] = []
    for bundleName in bundles {
      let bundle = (directory as NSString).appendingPathComponent(bundleName)
      let result = Shell.run(
        "xcrun",
        [
          "xcresulttool",
          "get",
          "build-results",
          "--path",
          bundle,
          "--format",
          "json",
        ])
      guard result.status == 0 else {
        Output.error("deadcode: could not read \(bundle)")
        continue
      }
      let bundleIssues = XCResult.issuesFromBuildResultsJSON(Data(result.stdout.utf8))
      guard !bundleIssues.isEmpty else {
        Output.error("deadcode: could not read \(bundle)")
        continue
      }
      issues.append(contentsOf: bundleIssues)
    }
    return issues
  }

  private static func outputBuildIssue(_ issue: XCResult.Issue) {
    if issue.file.isEmpty {
      Output.error("deadcode: \(issue.message)")
      return
    }
    Output.error("deadcode: \(issue.file):\(issue.line): \(issue.message)")
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
