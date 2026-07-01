//
//  Toolchain+Coverage.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - DeadcodeCoverageResult

/// The outcome of an engine-owned coverage build: the exit status of the build, and
/// its captured combined output. The captured output feeds the gate's fail-hard
/// transcript when the coverage build fails, so the structured xcresult diagnosis
/// and the saved build log still work.
public struct DeadcodeCoverageResult: Sendable {
  public let status: Int32
  public let output: String

  public init(status: Int32, output: String) {
    self.status = status
    self.output = output
  }
}

// MARK: - Toolchain coverage

extension Toolchain {
  public struct CoverageBuildOptions: Sendable {
    public var containerPath = ""
    public var isWorkspace = false
    public var generator = Generator.tuist
    public var configuration = "Debug"
    public var derivedDataPath = ""
    public var packageTargetNames: Set<String> = []
    public var buildableSchemeNames: Set<String> = []
    public var extraSettings: [String: String] = [:]
    public var environment: [String: String] = [:]

    public init() {
      // Defaults describe an empty Tuist Debug coverage request.
    }
  }

  private static let macOSCoverageDestination = "platform=macOS"
  private static let iOSSimulatorCoverageDestination = "generic/platform=iOS Simulator"
  private static let macCatalystCoverageDestination =
    "generic/platform=macOS,variant=Mac Catalyst"
  private static let coverageDriverFailureStatus: Int32 = 1
  private static let resultBundleDirectoryEnvironmentKey = "SWIFT_MK_RESULT_BUNDLE_DIR"

  /// The xcodebuild `-destination` string for a coverage build of the given platform.
  /// The dead-code coverage build derives one entry per (scheme, platform) from the
  /// generated project, and each platform maps to a fixed destination.
  public static func coverageDestination(for platform: CoveragePlatform) -> String {
    switch platform {
    case .macosx:
      return macOSCoverageDestination
    case .iphoneos, .iphonesimulator:
      return iOSSimulatorCoverageDestination
    case .maccatalyst:
      return macCatalystCoverageDestination
    }
  }

  /// Build a dead-code coverage index for every scheme and platform the generated
  /// project declares. The generated project must already exist; generation is the
  /// gate's responsibility, not this driver.
  public static func buildCoverage(_ options: CoverageBuildOptions) -> DeadcodeCoverageResult {
    let entries: [DeadcodeCoverageEntry]
    do {
      entries = try DeadcodeCoverageMatrix.entries(
        containerPath: options.containerPath,
        isWorkspace: options.isWorkspace,
        packageTargetNames: options.packageTargetNames,
        buildableSchemeNames: options.buildableSchemeNames)
    } catch {
      let message =
        "deadcode: could not enumerate coverage schemes from \(options.containerPath): \(error)"
      Output.error(message)
      return DeadcodeCoverageResult(status: coverageDriverFailureStatus, output: message + "\n")
    }
    guard !entries.isEmpty else {
      let message = "deadcode: no coverage schemes derived from \(options.containerPath)"
      Output.error(message)
      return DeadcodeCoverageResult(status: coverageDriverFailureStatus, output: message + "\n")
    }
    wipeCoverageDerivedData(options.derivedDataPath)
    return buildCoverageEntries(entries, options: options)
  }

  /// Run build-for-testing for each entry and aggregate the captured output.
  static func buildCoverageEntries(
    _ entries: [DeadcodeCoverageEntry], options: CoverageBuildOptions
  ) -> DeadcodeCoverageResult {
    let context = CoverageInvocationContext(
      containerPath: options.containerPath,
      isWorkspace: options.isWorkspace,
      generator: options.generator,
      configuration: options.configuration,
      derivedDataPath: options.derivedDataPath,
      extraSettings: options.extraSettings)
    var combinedOutput = ""
    var firstNonzeroStatus: Int32 = 0
    for entry in entries {
      let request = coverageRequest(entry, context: context)
      let resultBundleDirectory = coverageResultBundleDirectory(
        options.environment, for: entry.platform)
      let result = runXcodebuildCapturing(
        request,
        actions: ["build-for-testing"],
        environment: coverageEnvironment(
          options.environment, resultBundleDirectory: resultBundleDirectory),
        resultBundleDirectory: resultBundleDirectory)
      combinedOutput += result.stdout
      if firstNonzeroStatus == 0, result.status != 0 {
        firstNonzeroStatus = result.status
      }
    }
    return DeadcodeCoverageResult(status: firstNonzeroStatus, output: combinedOutput)
  }

  public static func deadcodeCoverageEnvironment(derivedDataPath: String) -> [String: String] {
    let derivedData = DeadcodeBuildConfig.resolvedDerivedDataRoot(derivedDataPath)
    return DeadcodeBuildConfig.buildEnvironment(derivedData: derivedData)
  }

  private static func coverageRequest(
    _ entry: DeadcodeCoverageEntry,
    context: CoverageInvocationContext
  ) -> Request {
    let destination = coverageDestination(for: entry.platform)
    return Request(
      generator: context.generator,
      scheme: entry.scheme,
      configuration: context.configuration,
      workspace: context.isWorkspace ? context.containerPath : nil,
      project: context.isWorkspace ? nil : context.containerPath,
      derivedDataPath: nonEmptyPath(context.derivedDataPath),
      extraSettings: context.extraSettings,
      extraArguments: ["-destination", destination])
  }

  private static func coverageResultBundleDirectory(
    _ environment: [String: String],
    for platform: CoveragePlatform
  ) -> String? {
    guard let directory = environment[resultBundleDirectoryEnvironmentKey],
      !directory.isEmpty
    else {
      return nil
    }
    return (directory as NSString).appendingPathComponent(platform.rawValue)
  }

  private static func coverageEnvironment(
    _ environment: [String: String],
    resultBundleDirectory: String?
  ) -> [String: String] {
    guard let resultBundleDirectory else {
      return environment
    }
    var result = environment
    result[resultBundleDirectoryEnvironmentKey] = resultBundleDirectory
    return result
  }

  private static func nonEmptyPath(_ path: String) -> String? {
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedPath.isEmpty {
      return nil
    }
    return path
  }

  private static func wipeCoverageDerivedData(_ derivedDataPath: String) {
    let resolvedPath = DeadcodeBuildConfig.resolvedDerivedDataRoot(derivedDataPath)
    guard !resolvedPath.isEmpty else {
      return
    }
    do {
      try FileManager.default.removeItem(atPath: resolvedPath)
      Output.info("deadcode: wiped DerivedData at \(resolvedPath)")
    } catch {
      if isMissingFile(error) {
        Output.info("deadcode: DerivedData already absent at \(resolvedPath)")
        return
      }
      Output.error("deadcode: could not wipe DerivedData at \(resolvedPath): \(error)")
    }
  }

  private static func isMissingFile(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain,
      nsError.code == CocoaError.Code.fileNoSuchFile.rawValue
    {
      return true
    }
    if nsError.domain == NSPOSIXErrorDomain,
      nsError.code == Int(ENOENT)
    {
      return true
    }
    return false
  }

  private struct CoverageInvocationContext {
    let containerPath: String
    let isWorkspace: Bool
    let generator: Generator
    let configuration: String
    let derivedDataPath: String
    let extraSettings: [String: String]
  }
}
