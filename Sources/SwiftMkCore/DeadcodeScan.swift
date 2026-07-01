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

  /// Labels for the two dead-code scans. Written to both stdout and the raw capture
  /// file so a later `Output:` dump of the capture is self-describing, and the package
  /// scan's "No unused code detected" is never read as contradicting the Xcode scan.
  static let packageScanLabel = "deadcode: package scan (Swift package targets)"
  static let xcodeScanLabel = "deadcode: xcode scan (Xcode project targets)"

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
  /// (`SWIFT_MK_XCODE_BUILD == "1"`). With no env flag it stays a SwiftPM scan.
  /// Returns the index store the Xcode scan read when it ran cleanly, so the runner
  /// can hand it to the coverage-completeness check, or nil when no Xcode scan ran or
  /// it failed.
  @discardableResult
  static func appendXcodeFindings(rawPath: String) -> String? {
    guard xcodeScanEnabled(Env.get("SWIFT_MK_XCODE_BUILD")) else {
      Output.debug(
        "deadcode: SwiftPM build (SWIFT_MK_XCODE_BUILD unset), skipping Xcode scan; "
          + "periphery's package scan covers the package")
      return nil
    }
    // Label the second of the two scans so its output, and any failure, is never
    // read as contradicting the package scan's "No unused code detected" above. The
    // label goes into the raw capture too, so a later `Output:` dump stays labeled.
    Output.log(xcodeScanLabel)
    appendCombined(xcodeScanLabel + "\n", to: rawPath)
    Output.debug("deadcode: resolving Xcode project shape")
    ensureProjectGenerated()
    switch projectShape() {
    case .swiftPMOnly:
      Output.debug("deadcode: SwiftPM-only repo, no Xcode scan")
      return nil
    case .manifestWithoutProject(let manifest):
      failHard(
        rawPath: rawPath,
        message:
          "lint-deadcode: \(manifest) declares an Xcode project but none was "
          + "generated; set SWIFT_GENERATE_CMD so the project is produced before "
          + "the gate runs")
      return nil
    case .project(let reference):
      return scanProject(
        path: reference.path,
        isWorkspace: reference.isWorkspace,
        rawPath: rawPath)
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

  /// Returns the index store the scan read when it ran cleanly, so the runner can
  /// hand it to the coverage-completeness check, or nil on any failure or skip.
  private static func scanProject(
    path: String, isWorkspace: Bool, rawPath: String
  ) -> String? {
    let schemes = discoverSchemes(project: path, isWorkspace: isWorkspace)
    let packageTargets = packageTargetNames()
    let scanSchemes = schemesToScan(schemes, packageTargets: packageTargets)
    guard !scanSchemes.isEmpty else {
      failHard(
        rawPath: rawPath,
        message: "lint-deadcode: no Xcode schemes to scan in \(path)")
      return nil
    }
    // Serialize the coverage build against every other build in this worktree (a make
    // build, a dev-tool SwiftPM build) so two builds never share `.build`/DerivedData
    // and corrupt each other's index store. This per-worktree lock replaces the old
    // dead-code-only `.make/deadcode-build.lock`, and is re-entrant so the coverage
    // build's own nested engine calls do not self-deadlock.
    return BuildLock.withLock { () -> String? in
      guard
        let indexStore = ensureIndexStore(
          path: path,
          isWorkspace: isWorkspace,
          packageTargets: packageTargets,
          rawPath: rawPath)
      else {
        return nil
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
        return nil
      }
      runPeriphery(
        project: path,
        schemes: scanSchemes,
        excludeTargets: Array(packageTargets).sorted(),
        indexStore: indexStore,
        rawPath: rawPath)
      return indexStore
    }
  }

  /// The schemes to scan: every Xcode scheme whose name is not a Swift package
  /// target, since the package scan owns the package targets.
  static func schemesToScan(_ schemes: [String], packageTargets: Set<String>) -> [String] {
    schemes.filter { !packageTargets.contains($0) }
  }

  /// Refresh and locate the build's index store, then wait for it to settle.
  /// The build always runs so the index reflects the current sources. Xcode
  /// writes the index store as background indexing finishes, which can lag the
  /// build command's exit, so the scan waits until the store stops growing to
  /// avoid reading a partial store and reporting phantom unused symbols that clear
  /// on a later run.
  static func ensureIndexStore(
    path: String,
    isWorkspace: Bool,
    packageTargets: Set<String>,
    rawPath: String
  ) -> String? {
    // Absolutize the derived-data root (PR #32) so a relative SWIFT_MK_DERIVED_DATA
    // does not resolve OBJROOT against each SwiftPM package's source root.
    let derivedData = DeadcodeBuildConfig.resolvedDerivedDataRoot(
      Env.get("SWIFT_MK_DERIVED_DATA"))
    Output.info("deadcode: building coverage via swift-mk toolchain coverage")
    let result = Toolchain.buildCoverage(
      coverageBuildOptions(
        path: path,
        isWorkspace: isWorkspace,
        packageTargets: packageTargets))
    if result.status != 0 {
      diagnoseFailedCoverage(
        rawPath: rawPath,
        status: result.status,
        output: result.output,
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
    guard let json = SwiftPM.describePackageJSON() else {
      Output.debug("deadcode: swift package describe failed; no package targets to exclude")
      return []
    }
    return parsePackageTargets(json)
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
  static func coverageBuildOptions(
    path: String,
    isWorkspace: Bool,
    packageTargets: Set<String>
  ) -> Toolchain.CoverageBuildOptions {
    let rawDerivedData = Env.get("SWIFT_MK_DERIVED_DATA")
    let derivedData = DeadcodeBuildConfig.resolvedDerivedDataRoot(rawDerivedData)
    var options = Toolchain.CoverageBuildOptions()
    options.containerPath = path
    options.isWorkspace = isWorkspace
    options.generator = coverageGenerator()
    options.configuration = Env.get("SWIFT_XCODE_COVERAGE_CONFIGURATION", "Debug")
    options.derivedDataPath = rawDerivedData
    options.packageTargetNames = packageTargets
    options.extraSettings = coverageBuildSettings()
    options.environment = DeadcodeBuildConfig.buildEnvironment(derivedData: derivedData)
    return options
  }

  private static func coverageGenerator() -> Toolchain.Generator {
    let fallback = Toolchain.Generator.tuist
    let raw = Env.get("SWIFT_XCODE_GENERATOR", fallback.rawValue)
    guard let generator = Toolchain.Generator(rawValue: raw) else {
      Output.error(
        "deadcode: unknown SWIFT_XCODE_GENERATOR '\(raw)', using \(fallback.rawValue)")
      return fallback
    }
    return generator
  }

  private static func coverageBuildSettings() -> [String: String] {
    var settings: [String: String] = [:]
    for pair in Env.words(Env.get("SWIFT_XCODE_BUILD_SETTINGS")) {
      guard let equals = pair.firstIndex(of: "=") else {
        Output.error("deadcode: ignoring malformed SWIFT_XCODE_BUILD_SETTINGS value \(pair)")
        continue
      }
      let key = String(pair[..<equals])
      let value = String(pair[pair.index(after: equals)...])
      settings[key] = value
    }
    return settings
  }

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

/// The subset of `swift package describe --type json` the gate reads: the package
/// root path and, per target, the name plus the source-file list the coverage check
/// needs. `path` and `sources` are optional so a describe output without them still
/// decodes for `parsePackageTargets`, which reads only `name`.
struct PackageDescription: Decodable {
  struct Target: Decodable {
    let name: String
    let path: String?
    let sources: [String]?
  }

  let path: String?
  let targets: [Target]
}
