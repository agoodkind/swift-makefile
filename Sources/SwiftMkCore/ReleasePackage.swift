//
//  ReleasePackage.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - ReleasePackagePlan

public struct ReleasePackagePlan: Equatable, Sendable {
  public let tag: String
  public let distDir: String
  public let signingEnginePath: String?
  public let versionFile: String
  public let buildArguments: [String]
  public let builtProductName: String
  public let stagedBinaryName: String
  public let assetName: String
  public let identifier: String
  public let volumeName: String
  /// When this is true, the dmg includes every `*.bundle` folder next to the binary.
  /// `swift-mk` loads its lint config files from a SwiftPM resource bundle next to
  /// the running executable.
  public let includesResourceBundles: Bool

  public var stageDir: String {
    (distDir as NSString).appendingPathComponent(".stage-\(builtProductName)")
  }

  public var dmgPath: String {
    (distDir as NSString).appendingPathComponent(assetName)
  }
}

// MARK: - ReleasePackageError

public enum ReleasePackageError: Error, Equatable, CustomStringConvertible {
  case binPathUnresolved(String)
  case builtBinaryMissing(String)
  case commandFailed(String, Int32)
  case resourceBundlesMissing(String)
  case signingIdentityUnavailable(String)
  case unsafeTag(String)
  case versionStampFailed(String, String)

  public var description: String {
    switch self {
    case .binPathUnresolved(let command):
      return "\(command) returned no build path"
    case .builtBinaryMissing(let path):
      return "built binary not found at \(path)"
    case let .commandFailed(command, status):
      return "\(command) failed with status \(status)"
    case .resourceBundlesMissing(let binDir):
      return "build did not write a resource bundle in \(binDir)"
    case .signingIdentityUnavailable(let reason):
      return "signing identity unavailable: \(reason)"
    case .unsafeTag(let tag):
      return "release tag has unsafe characters (want [A-Za-z0-9._+-]): \(tag)"
    case let .versionStampFailed(file, tag):
      return "failed to stamp version \(tag) into \(file)"
    }
  }
}

// MARK: - ReleasePackage

public enum ReleasePackage {
  private static let devVersion = "dev"
  // Derive the needle from devVersion so the dev sentinel is defined in one place;
  // a mismatch would silently make stamping fail to match.
  private static let versionNeedle = "static let current = \"\(devVersion)\""
  private static let safeTagScalars = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-")

  /// run() writes the release tag into this file before building both products.
  /// `swift-mk-maint` and `swift-mk` compile it, and `version` prints that tag.
  private static let versionFile = "Sources/SwiftMkMaintCore/ReleaseVersion.swift"

  /// plans() returns the `swift-mk-maint` plan before the `swift-mk` plan.
  /// install.sh and the self-updater install the small `swift-mk-maint` tool.
  /// `swift-mk` is the full engine for the lint, baseline, and gate commands.
  public static func plans(
    tag: String,
    distDir: String,
    signingEnginePath: String?
  ) -> [ReleasePackagePlan] {
    releaseProducts.map { product in
      ReleasePackagePlan(
        tag: tag,
        distDir: distDir,
        signingEnginePath: signingEnginePath,
        versionFile: versionFile,
        buildArguments: [
          "build", "-c", "release", "--product", product.productName, "--arch", "arm64",
        ],
        builtProductName: product.productName,
        stagedBinaryName: product.productName,
        assetName: product.assetName,
        identifier: "io.goodkind.\(product.productName)",
        volumeName: product.productName,
        includesResourceBundles: product.includesResourceBundles)
    }
  }

  private struct ReleaseProduct {
    let productName: String
    let assetName: String
    let includesResourceBundles: Bool
  }

  private static let releaseProducts = [
    ReleaseProduct(
      productName: "swift-mk-maint",
      assetName: "swift-mk-maint_darwin_arm64.dmg",
      includesResourceBundles: false),
    ReleaseProduct(
      productName: "swift-mk",
      assetName: "swift-mk-engine_darwin_arm64.dmg",
      includesResourceBundles: true),
  ]

  public static func run(
    tag: String,
    distDir: String,
    signingEnginePath: String?
  ) throws {
    let plans = plans(tag: tag, distDir: distDir, signingEnginePath: signingEnginePath)
    try validateTag(tag)
    try FileManager.default.createDirectory(
      atPath: distDir,
      withIntermediateDirectories: true)
    // run() reads the original ReleaseVersion.swift text before stamping.
    // If a later build, stage, sign, or dmg step throws for either product,
    // run() writes the saved text back and rethrows.
    // After success, the file keeps the stamped tag.
    let originalVersionContents: String?
    if tag == devVersion {
      originalVersionContents = nil
    } else {
      originalVersionContents = try String(contentsOfFile: versionFile, encoding: .utf8)
    }
    do {
      if tag != devVersion {
        try stampVersion(tag: tag, versionFile: versionFile)
      }
      let shouldSign = try signingIdentityIsAvailable(signingEnginePath: signingEnginePath)
      for plan in plans {
        try packageProduct(plan, shouldSign: shouldSign)
      }
    } catch {
      if let originalVersionContents {
        do {
          try originalVersionContents.write(
            toFile: versionFile, atomically: true, encoding: .utf8)
        } catch {
          Output.warning("release-build: failed to restore \(versionFile): \(error)")
        }
      }
      throw error
    }
  }

  private static func packageProduct(_ plan: ReleasePackagePlan, shouldSign: Bool) throws {
    let built = try buildProduct(plan)
    // The defer calls cleanupPath(plan.stageDir) on every packageProduct() exit,
    // including when a copy fails after stageProduct creates the stage folder.
    defer {
      cleanupPath(plan.stageDir, label: "stage")
    }
    try stageProduct(built: built, plan: plan)
    let stagedBinary = (plan.stageDir as NSString).appendingPathComponent(plan.stagedBinaryName)
    if shouldSign {
      try codesign(
        signingEnginePath: plan.signingEnginePath,
        arguments: [
          "codesign-run", "--mode", "binary", "--identifier", plan.identifier, stagedBinary,
        ])
    }
    try createDmg(plan)
    if shouldSign {
      try codesign(
        signingEnginePath: plan.signingEnginePath,
        arguments: ["codesign-run", "--mode", "dmg", plan.dmgPath])
    }
  }

  public static func stampVersion(tag: String, versionFile: String) throws {
    // Validate here too, not only in run(), so a public caller cannot write an
    // unchecked tag into the version source.
    try validateTag(tag)
    let contents = try String(contentsOfFile: versionFile, encoding: .utf8)
    let replacement = "static let current = \"\(tag)\""
    // Idempotent: the file is already stamped to this tag, so leave it untouched.
    if contents.contains(replacement) {
      return
    }
    // The dev sentinel must be present to stamp. Throw before writing so a file
    // that cannot be stamped (for example already a different value) is left
    // untouched rather than rewritten in a failing call.
    guard contents.contains(versionNeedle) else {
      throw ReleasePackageError.versionStampFailed(versionFile, tag)
    }
    let stamped = contents.replacingOccurrences(of: versionNeedle, with: replacement)
    try stamped.write(toFile: versionFile, atomically: true, encoding: .utf8)
  }

  private static func validateTag(_ tag: String) throws {
    let isSafe = !tag.isEmpty && tag.unicodeScalars.allSatisfy { safeTagScalars.contains($0) }
    if !isSafe {
      throw ReleasePackageError.unsafeTag(tag)
    }
  }

  /// The release build's full argv: the plan's arguments plus the shared
  /// compilation-cache flags. This build is an engine compile like any other, so
  /// it must run in the same module mode as the verify build and read the same
  /// content-addressed store; without the flags the release stage recompiles
  /// cold on the machine whose store the verify build just filled.
  static func buildInvocationArguments(_ plan: ReleasePackagePlan) -> [String] {
    plan.buildArguments + SwiftPM.compileCacheArguments()
  }

  private static func buildProduct(_ plan: ReleasePackagePlan) throws -> String {
    let buildArguments = buildInvocationArguments(plan)
    Output.debug("release-build: running swift build for \(plan.builtProductName)")
    let buildStatus = Shell.runForwardingOutput("swift", buildArguments)
    if buildStatus != 0 {
      throw ReleasePackageError.commandFailed(
        "swift \(buildArguments.joined(separator: " "))",
        buildStatus)
    }
    Output.debug("release-build: resolving build product path for \(plan.builtProductName)")
    let showBinPathArgs = buildArguments + ["--show-bin-path"]
    let binPath = Shell.run("swift", showBinPathArgs)
    let showBinPathCommand = "swift \(showBinPathArgs.joined(separator: " "))"
    if binPath.status != 0 {
      Output.emitStandardError(binPath.combined)
      throw ReleasePackageError.commandFailed(showBinPathCommand, binPath.status)
    }
    let binDir = lastNonemptyLine(binPath.stdout)
    // A zero exit with no path line cannot locate the product, so surface the
    // resolution failure directly rather than a misleading builtBinaryMissing
    // against a relative path.
    guard !binDir.isEmpty else {
      throw ReleasePackageError.binPathUnresolved(showBinPathCommand)
    }
    let built = (binDir as NSString).appendingPathComponent(plan.builtProductName)
    guard FileManager.default.isExecutableFile(atPath: built) else {
      throw ReleasePackageError.builtBinaryMissing(built)
    }
    return built
  }

  private static func stageProduct(built: String, plan: ReleasePackagePlan) throws {
    Output.debug("release-build: staging \(built) into \(plan.stageDir)")
    cleanupPath(plan.stageDir, label: "stage")
    try FileManager.default.createDirectory(
      atPath: plan.stageDir,
      withIntermediateDirectories: true)
    let stagedBinary = (plan.stageDir as NSString).appendingPathComponent(plan.stagedBinaryName)
    try FileManager.default.copyItem(atPath: built, toPath: stagedBinary)
    if plan.includesResourceBundles {
      try stageResourceBundles(binDir: (built as NSString).deletingLastPathComponent, plan: plan)
    }
  }

  /// stageResourceBundles() copies every `*.bundle` folder from the SwiftPM build
  /// output folder into the stage folder. If the build output folder does not
  /// contain a `*.bundle` folder, it throws
  /// ReleasePackageError.resourceBundlesMissing.
  private static func stageResourceBundles(binDir: String, plan: ReleasePackagePlan) throws {
    let entries = try FileManager.default.contentsOfDirectory(atPath: binDir)
    let bundleNames = entries.filter { $0.hasSuffix(".bundle") }.sorted()
    guard !bundleNames.isEmpty else {
      throw ReleasePackageError.resourceBundlesMissing(binDir)
    }
    for bundleName in bundleNames {
      let source = (binDir as NSString).appendingPathComponent(bundleName)
      let destination = (plan.stageDir as NSString).appendingPathComponent(bundleName)
      Output.debug("release-build: staging \(source) into \(plan.stageDir)")
      try FileManager.default.copyItem(atPath: source, toPath: destination)
    }
  }

  private static func createDmg(_ plan: ReleasePackagePlan) throws {
    cleanupPath(plan.dmgPath, label: "dmg")
    let status = Shell.runForwardingOutput(
      "hdiutil",
      [
        "create", "-volname", plan.volumeName, "-srcfolder", plan.stageDir, "-ov",
        "-format", "UDZO", plan.dmgPath,
      ])
    if status != 0 {
      throw ReleasePackageError.commandFailed("hdiutil create", status)
    }
  }

  private static func signingIdentityIsAvailable(signingEnginePath: String?) throws -> Bool {
    guard let signingEnginePath, !signingEnginePath.isEmpty else {
      // No signing engine was passed. This is the expected path for an unsigned
      // local or fork run, so state it plainly rather than as an error.
      Output.info("release-build: no signing engine provided; packaging unsigned artifacts")
      return false
    }
    guard FileManager.default.isExecutableFile(atPath: signingEnginePath) else {
      // A signing engine was configured but cannot run. That is a misconfiguration,
      // not a run without a cert, so fail rather than silently ship unsigned.
      throw ReleasePackageError.signingIdentityUnavailable(
        "signing engine is not executable at \(signingEnginePath)")
    }
    Output.debug("release-build: resolving signing identity")
    let result = Shell.run(signingEnginePath, ["signing-identity"])
    if result.status != 0 {
      // signing-identity prints nothing and exits 0 when no identity is set, so a
      // non-zero status is a genuine command failure, not a run without a cert.
      Output.emitStandardError(result.combined)
      throw ReleasePackageError.commandFailed(
        "\(signingEnginePath) signing-identity", result.status)
    }
    let identity = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if identity.isEmpty {
      // No identity resolved. On a CI or fork run without a cert the identity is
      // simply not imported; Global Constraint 5 requires that run to stay green
      // with signing skipped, so package unsigned rather than fail.
      Output.info("release-build: no signing identity resolved; packaging unsigned artifacts")
      return false
    }
    return true
  }

  private static func codesign(signingEnginePath: String?, arguments: [String]) throws {
    guard let signingEnginePath else {
      return
    }
    let status = Shell.runForwardingOutput(signingEnginePath, arguments)
    if status != 0 {
      throw ReleasePackageError.commandFailed(
        "\(signingEnginePath) \(arguments.joined(separator: " "))",
        status)
    }
  }

  private static func cleanupPath(_ path: String, label: String) {
    guard FileManager.default.fileExists(atPath: path) else {
      return
    }
    do {
      try FileManager.default.removeItem(atPath: path)
    } catch {
      Output.warning("release-build: failed to clean \(label) \(path): \(error)")
    }
  }

  private static func lastNonemptyLine(_ text: String) -> String {
    text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .last { !$0.isEmpty } ?? ""
  }
}
