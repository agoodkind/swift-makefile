//
//  Toolchain.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Toolchain

/// This type is the only site that runs `tuist`, `xcodegen`, or `xcodebuild`.
/// Make consumers run `swift-mk toolchain <op>`, and Swift dev tools import
/// SwiftMkCore. A swiftcheck rule and the build-tooling audit reject a reference to
/// those tools from any other file.
///
/// A bare `xcodebuild -scheme` without a container opens the app project and does
/// not see an external SPM dependency that Tuist adds only to the workspace. Build
/// commands pass `-workspace` for Tuist or `-project` for xcodegen.
public enum Toolchain {
  public enum Generator: String, Sendable {
    case tuist
    case xcodegen
  }

  public struct Request: Sendable {
    public let generator: Generator
    public let scheme: String
    public let configuration: String
    public let workspace: String?
    public let project: String?
    public let destination: String?
    public let derivedDataPath: String?
    public let extraSettings: [String: String]
    /// xcodebuild flags that are not `KEY=value` settings, such as
    /// `-allowProvisioningUpdates`.
    public let extraArguments: [String]

    public init(
      generator: Generator,
      scheme: String,
      configuration: String = "Debug",
      workspace: String? = nil,
      project: String? = nil,
      destination: String? = nil,
      derivedDataPath: String? = nil,
      extraSettings: [String: String] = [:],
      extraArguments: [String] = []
    ) {
      self.generator = generator
      self.scheme = scheme
      self.configuration = configuration
      self.workspace = workspace
      self.project = project
      self.destination = destination
      self.derivedDataPath = derivedDataPath
      self.extraSettings = extraSettings
      self.extraArguments = extraArguments
    }
  }

  // MARK: Project generation and dependencies

  /// Tuist fetches external SPM dependencies into `Tuist/.build`.
  @discardableResult
  public static func installDependencies(_ generator: Generator) -> Int32 {
    switch generator {
    case .tuist:
      Output.info("toolchain: tuist install")
      return runTuistResolve(["install"])
    case .xcodegen:
      Output.info("toolchain: xcodegen has no dependency install step")
      return 0
    }
  }

  // MARK: Signing-setting rejection

  /// `EX_USAGE` in sysexits.h.
  static let signingOverrideRejectionStatus: Int32 = 64

  static let gateFailureStatus: Int32 = 1

  /// swift-mk sets signing through an `XCODE_XCCONFIG_FILE` override, and a
  /// command-line `KEY=value` setting takes precedence over that file. Every build
  /// path rejects these keys. The dead-code coverage build disables signing through
  /// the xcconfig of `DeadcodeBuildConfig` and does not use these settings. The
  /// matcher compares the uppercase form of the key.
  static let forbiddenSigningSettingKeys: Set<String> = [
    "CODE_SIGN_IDENTITY",
    "EXPANDED_CODE_SIGN_IDENTITY",
    "CODE_SIGNING_REQUIRED",
    "CODE_SIGNING_ALLOWED",
    "DEVELOPMENT_TEAM",
    "CODE_SIGN_STYLE",
    "PROVISIONING_PROFILE",
    "PROVISIONING_PROFILE_SPECIFIER",
    "CODE_SIGN_ENTITLEMENTS",
    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS",
    "OTHER_CODE_SIGN_FLAGS",
  ]

  /// Returns the first forbidden signing key in its original spelling, or nil. The
  /// function checks the keys of `extraSettings` and each `KEY=value` token in
  /// `extraArguments`. The CLI rejects a request with this function before a build.
  public static func forbiddenSigningSetting(in request: Request) -> String? {
    for key in request.extraSettings.keys.sorted()
    where forbiddenSigningSettingKeys.contains(key.uppercased()) {
      return key
    }
    for token in request.extraArguments {
      guard let equals = token.firstIndex(of: "=") else {
        continue
      }
      let key = String(token[..<equals])
      if forbiddenSigningSettingKeys.contains(key.uppercased()) {
        return key
      }
    }
    return nil
  }

  static func rejectionForSigningOverride(_ request: Request) -> Int32? {
    guard let key = forbiddenSigningSetting(in: request) else {
      return nil
    }
    Output.error(
      "toolchain: build setting '\(key)' is forbidden; swift-mk owns code signing "
        + "via XCODE_XCCONFIG_FILE and a command-line setting would beat it. Remove it "
        + "and set the identity and team through the swift-mk signing source.")
    return signingOverrideRejectionStatus
  }

  // MARK: Build and test

  /// The build uses xcodebuild and does not use `tuist build`. A consumer that
  /// packages its product reads it from `-derivedDataPath`, and `tuist build`
  /// writes to the DerivedData directory of Tuist.
  ///
  /// The function does not run the lint gates. `swift-mk build` runs them once, and
  /// a second `toolchain build` for a Metal or helper target does not run them again.
  @discardableResult
  public static func build(_ request: Request) -> Int32 {
    // A forbidden signing setting is a caller error, and its check does not depend
    // on the gate proof. `buildWithoutGateCheck` skips its own check when
    // `signingAlreadyRejected` is true.
    if let rejection = rejectionForSigningOverride(request) {
      return rejection
    }
    // A secondary build after `swift-mk build` exits passes, because its `make`
    // ancestor is the anchor. A dev tool without `make` calls `build(_:receipt:)`,
    // which requires a `GateReceipt` from the hard gate.
    if let refusal = GateProof.refusal(entry: "toolchain build") {
      return refusal
    }
    return buildWithoutGateCheck(request, signingAlreadyRejected: true)
  }

  /// An `XCODE_XCCONFIG_FILE` exported by the make signing prelude takes
  /// precedence, and the function returns no override. Otherwise the function
  /// writes an override from the identity and team in the environment. With
  /// neither set, `SigningBuildConfig.write` returns nil and the build uses its own
  /// signing. The function does not add ad hoc signing.
  static func signingEnvironment() -> [String: String] {
    if !Env.get("XCODE_XCCONFIG_FILE").isEmpty {
      return [:]
    }
    guard let path = SigningBuildConfig.write() else {
      return [:]
    }
    return ["XCODE_XCCONFIG_FILE": path]
  }

  /// The Tuist path runs `tuist test --no-selective-testing`. Selective testing
  /// skips the whole suite.
  @discardableResult
  public static func test(_ request: Request) -> Int32 {
    if let rejection = rejectionForSigningOverride(request) {
      return rejection
    }
    switch request.generator {
    case .tuist:
      return Shell.runForwardingOutput("tuist", tuistTestArguments(request))
    case .xcodegen:
      return runXcodebuildForwarding(request, actions: ["test"], environment: [:])
    }
  }

  /// The dead-code gate calls `buildCoverage(_:)` and does not run this command.
  @discardableResult
  public static func buildForTesting(_ request: Request) -> Int32 {
    if let refusal = GateProof.refusal(entry: "toolchain build-for-testing") {
      return refusal
    }
    return runXcodebuildForwarding(
      request, actions: ["build-for-testing"], environment: [:])
  }

  /// `swiftlint analyze` reads the compiler log at `logPath`.
  @discardableResult
  public static func buildWritingLog(
    _ request: Request, logPath: String, clean: Bool = false
  ) -> Int32 {
    if let refusal = GateProof.refusal(entry: "toolchain build --log-path") {
      return refusal
    }
    let actions = clean ? ["clean", "build"] : ["build"]
    guard ToolchainPrebuild.run() else {
      return prebuildFailureStatus
    }
    return Shell.runWritingOutput(
      "xcodebuild",
      xcodebuildArguments(request, actions: actions),
      toFile: logPath,
      environment: signingEnvironment()
    )
  }

  // MARK: Read-only toolchain queries

  public static func version() -> String {
    func line(_ tool: String, _ arguments: [String]) -> String {
      let result = Shell.run(tool, arguments)
      return result.status == 0
        ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        : "\(tool): unavailable"
    }
    return [
      line("swift", ["--version"]),
      line("xcodebuild", ["-version"]),
      line("tuist", ["version"]),
    ].joined(separator: "\n")
  }

  public static func listSchemes(container: String, isWorkspace: Bool) -> Shell.Result {
    let flag = isWorkspace ? "-workspace" : "-project"
    return Shell.run("xcodebuild", ["-list", "-json", flag, container])
  }

  /// The signing verifier reads this output.
  public static func showBuildSettings(
    workspace: String, scheme: String, configuration: String? = nil
  ) -> Shell.Result {
    var arguments = ["-showBuildSettings", "-workspace", workspace, "-scheme", scheme]
    if let configuration {
      arguments.append(contentsOf: ["-configuration", configuration])
    }
    return Shell.run("xcodebuild", arguments)
  }

  /// The dead-code coverage build reads the destinations of a scheme from this
  /// output. xcodebuild resolves `SUPPORTED_PLATFORMS` through the xcconfig files of
  /// the consumer, and the raw project file does not contain a value resolved that way.
  public static func showDestinations(
    container: String, isWorkspace: Bool, scheme: String
  ) -> Shell.Result {
    let containerFlag = isWorkspace ? "-workspace" : "-project"
    return Shell.run(
      "xcodebuild",
      ["-showdestinations", containerFlag, container, "-scheme", scheme])
  }

  @discardableResult
  public static func downloadComponent(_ name: String) -> Int32 {
    Output.info("toolchain: downloadComponent \(name)")
    return Shell.runForwardingOutput("xcodebuild", ["-downloadComponent", name])
  }

  // MARK: Argument assembly (exposed for tests)

  /// `--derived-data-path` uses the same path as the build and coverage paths.
  /// `tuist test` passes the `KEY=value` settings after `--` to xcodebuild.
  static func tuistTestArguments(_ request: Request) -> [String] {
    var args = [
      "test", request.scheme, "--configuration", request.configuration,
      "--no-selective-testing",
    ]
    if let derivedDataPath = request.derivedDataPath {
      args.append(contentsOf: ["--derived-data-path", derivedDataPath])
    }
    if !request.extraSettings.isEmpty {
      args.append("--")
      args.append(contentsOf: settingArguments(request.extraSettings))
    }
    return args
  }

  /// A missing container returns `-version`, and xcodebuild does not discover a
  /// project.
  static func xcodebuildArguments(
    _ request: Request, actions: [String], resultBundleDirectory: String? = nil
  ) -> [String] {
    var args: [String] = []
    switch request.generator {
    case .tuist:
      guard let workspace = request.workspace else {
        Output.error(
          "toolchain: tuist \(actions.joined(separator: " ")) requires a workspace path")
        return ["-version"]
      }
      args.append(contentsOf: ["-workspace", workspace])
    case .xcodegen:
      guard let project = request.project else {
        Output.error(
          "toolchain: xcodegen \(actions.joined(separator: " ")) requires a project path")
        return ["-version"]
      }
      args.append(contentsOf: ["-project", project])
    }
    args.append(contentsOf: ["-scheme", request.scheme])
    args.append(contentsOf: ["-configuration", request.configuration])
    if let destination = request.destination {
      args.append(contentsOf: ["-destination", destination])
    }
    if let derivedDataPath = request.derivedDataPath {
      args.append(contentsOf: ["-derivedDataPath", derivedDataPath])
    }
    args.append(contentsOf: sharedCacheArguments())
    args.append(contentsOf: request.extraArguments)
    args.append(contentsOf: settingArguments(request.extraSettings))
    args.append(contentsOf: resultBundleArguments(request, dir: resultBundleDirectory))
    args.append(contentsOf: actions)
    return args
  }

  private static func resultBundleArguments(_ request: Request, dir: String? = nil) -> [String] {
    let configuredDirectory = dir ?? Env.get("SWIFT_MK_RESULT_BUNDLE_DIR")
    guard !configuredDirectory.isEmpty else { return [] }
    var bundleName = sanitizedResultBundleComponent(request.scheme)
    if !request.configuration.isEmpty {
      bundleName += "-\(sanitizedResultBundleComponent(request.configuration))"
    }
    let bundlePath = (configuredDirectory as NSString).appendingPathComponent(
      "\(bundleName).xcresult")
    guard removeExistingResultBundle(atPath: bundlePath) else {
      return []
    }
    return ["-resultBundlePath", bundlePath]
  }

  private static func sanitizedResultBundleComponent(_ component: String) -> String {
    component
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: " ", with: "-")
  }

  private static func removeExistingResultBundle(atPath path: String) -> Bool {
    do {
      try FileManager.default.removeItem(atPath: path)
      return true
    } catch {
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
      Output.error("toolchain: could not remove result bundle \(path): \(error)")
      return false
    }
  }

  private static func settingArguments(_ settings: [String: String]) -> [String] {
    var result: [String] = []
    for key in settings.keys.sorted() {
      guard let value = settings[key] else {
        continue
      }
      result.append("\(key)=\(value)")
    }
    return result
  }
}

// MARK: - Shared content-addressed caches

extension Toolchain {
  static let sharedCacheDisableTokens: Set<String> = ["off", "none", "0", "disabled"]

  /// `-derivedDataPath` is per checkout. The Clang module cache, the SPM clone
  /// directory, and the LLVM compilation cache store are content-addressed, and
  /// every checkout uses one location for each. `SWIFT_MK_MODULE_CACHE`,
  /// `SWIFT_MK_SPM_CACHE`, and `SWIFT_MK_XCODE_CACHE_PATH` set the locations.
  ///
  /// The compilation cache store is outside DerivedData. Xcode stores it in
  /// `<derivedDataPath>/CompilationCache.noindex` by default, and the dead-code
  /// coverage build deletes DerivedData. The setting has no effect when compilation
  /// caching is off.
  ///
  /// With `SWIFT_MK_POOL=1`, the package cache and the module cache use a local
  /// directory of the VM, and only SourcePackages stays on the shared host mount.
  /// Xcode writes often to those two caches.
  static func sharedCacheArguments() -> [String] {
    var args: [String] = []
    let isPool = Env.get("SWIFT_MK_POOL") == "1"
    let spm = resolvedSharedCachePath(
      "SWIFT_MK_SPM_CACHE", defaultSubdirectory: "SourcePackages")
    if let spm {
      args.append(contentsOf: ["-clonedSourcePackagesDirPath", spm])
      if isPool {
        args.append(contentsOf: ["-packageCachePath", poolLocalCachePath("PackageCache")])
      }
      if isPool,
        sharedSourcePackagesCheckoutIsPopulated(spm)
      {
        args.append("-disableAutomaticPackageResolution")
      }
    }
    let module = resolvedSharedCachePath(
      "SWIFT_MK_MODULE_CACHE", defaultSubdirectory: "ModuleCache")
    if let module {
      let modulePath = isPool ? poolLocalCachePath("ModuleCache") : module
      args.append("MODULE_CACHE_DIR=\(modulePath)")
    }
    let cas = resolvedSharedCachePath(
      "SWIFT_MK_XCODE_CACHE_PATH", defaultSubdirectory: "CompilationCache")
    if let cas {
      args.append("COMPILATION_CACHE_CAS_PATH=\(cas)")
    }
    return args
  }

  /// Returns nil for a disable token. An empty value returns the default under
  /// `~/Library/Caches/swift-mk`. The function does not create the directory. With
  /// `honorDisableToken: false`, a disable token returns the default path.
  static func resolvedSharedCachePath(
    _ envName: String, defaultSubdirectory: String, honorDisableToken: Bool = true
  ) -> String? {
    let raw = Env.get(envName).trimmingCharacters(in: .whitespacesAndNewlines)
    let isDisableToken = sharedCacheDisableTokens.contains(raw.lowercased())
    if isDisableToken, honorDisableToken {
      return nil
    }
    if raw.isEmpty || isDisableToken {
      return defaultSharedCacheRoot().appendingPathComponent(defaultSubdirectory).path
    }
    return raw
  }

  static func poolLocalCachePath(_ subdirectory: String) -> String {
    let explicitRoot = Env.get("SWIFT_MK_POOL_LOCAL_CACHE")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !explicitRoot.isEmpty {
      return URL(fileURLWithPath: explicitRoot, isDirectory: true)
        .appendingPathComponent(subdirectory, isDirectory: true)
        .path
    }

    let runnerTemp = Env.get("RUNNER_TEMP")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let tempRoot =
      runnerTemp.isEmpty
      ? FileManager.default.temporaryDirectory.path
      : runnerTemp
    return URL(fileURLWithPath: tempRoot, isDirectory: true)
      .appendingPathComponent("swift-mk", isDirectory: true)
      .appendingPathComponent("pool-cache", isDirectory: true)
      .appendingPathComponent(subdirectory, isDirectory: true)
      .path
  }

  private static func sharedSourcePackagesCheckoutIsPopulated(
    _ sourcePackagesPath: String
  ) -> Bool {
    let checkoutsURL = URL(fileURLWithPath: sourcePackagesPath, isDirectory: true)
      .appendingPathComponent("checkouts", isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: checkoutsURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return false
    }
    guard let enumerator = FileManager.default.enumerator(atPath: checkoutsURL.path) else {
      return false
    }
    return enumerator.nextObject() != nil
  }

  private static func defaultSharedCacheRoot() -> URL {
    // The cache plan also reads $HOME. The account home is the fallback when HOME
    // is unset.
    let home = Env.get("HOME")
    let base =
      home.isEmpty
      ? FileManager.default.homeDirectoryForCurrentUser
      : URL(fileURLWithPath: home, isDirectory: true)
    return base.appendingPathComponent("Library/Caches/swift-mk", isDirectory: true)
  }
}

// MARK: - Toolchain version probes

extension Toolchain {
  /// Used in cache keys.
  public static func xcodeVersionString() -> String {
    Output.debug("toolchain: reading xcodebuild -version")
    return probedToolVersion("xcodebuild", ["-version"], fallback: "xcode-unavailable")
  }

  /// Used in cache keys.
  public static func swiftVersionString() -> String {
    Output.debug("toolchain: reading swift --version")
    return probedToolVersion("swift", ["--version"], fallback: "swift-unavailable")
  }

  /// Cache keys depend on this trimming, which matches the output of shell `$(...)`.
  private static func probedToolVersion(
    _ command: String, _ arguments: [String], fallback: String
  ) -> String {
    let result = Shell.run(command, arguments)
    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.status != 0 || trimmed.isEmpty {
      return fallback
    }
    return trimmed
  }
}

// MARK: - Raw xcodebuild invocation

extension Toolchain {
  static let prebuildFailureStatus: Int32 = 1

  static func runXcodebuildForwarding(
    _ request: Request, actions: [String], environment: [String: String]
  ) -> Int32 {
    Output.debug("toolchain: xcodebuild \(actions.joined(separator: " "))")
    guard ToolchainPrebuild.run() else {
      return prebuildFailureStatus
    }
    return Shell.runForwardingOutput(
      "xcodebuild", xcodebuildArguments(request, actions: actions), environment: environment)
  }

  /// The dead-code coverage build reads the captured stdout to classify a failure.
  static func runXcodebuildCapturing(
    _ request: Request,
    actions: [String],
    environment: [String: String],
    resultBundleDirectory: String? = nil,
    timeoutSeconds: Double = 0
  ) -> Shell.StreamingResult {
    Output.debug("toolchain: xcodebuild (captured) \(actions.joined(separator: " "))")
    guard ToolchainPrebuild.run() else {
      return Shell.StreamingResult(status: prebuildFailureStatus, stdout: "", timedOut: false)
    }
    let arguments = xcodebuildArguments(
      request, actions: actions, resultBundleDirectory: resultBundleDirectory)
    let result = Shell.runForwardingAndCapturingStreaming(
      "xcodebuild",
      arguments,
      environment: environment,
      timeoutSeconds: timeoutSeconds)
    return Shell.StreamingResult(
      status: result.status,
      stdout: result.stdout,
      timedOut: result.timedOut)
  }
}
