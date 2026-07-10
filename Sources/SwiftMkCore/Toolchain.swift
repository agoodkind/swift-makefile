//
//  Toolchain.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Toolchain

/// The single sanctioned driver of the Xcode build toolchain. It is the one and
/// only place in the fleet allowed to spawn `tuist`, `xcodegen`, or `xcodebuild`.
/// Make consumers reach it through `swift-mk toolchain <op>`; Swift dev tools reach
/// it through a typed `import SwiftMkCore`. A swiftcheck rule and a make audit forbid
/// any other site from naming those tools, with no opt-out.
///
/// Why a chokepoint: a consumer that ran `tuist xcodebuild build` forwarded a bare
/// `xcodebuild -scheme` with no container, so xcodebuild auto-discovered the app
/// project and missed a Tuist-integrated external SPM dependency wired only at the
/// workspace level (the Automerge break). The fix is verified: native `tuist build`
/// and `tuist test --no-selective-testing` drive Tuist's own workspace and resolve
/// the dependency. So for a Tuist consumer this type emits native `tuist` commands,
/// never `tuist xcodebuild`. For an xcodegen consumer it emits an explicit
/// `xcodebuild -project ... -scheme ...`, never a bare auto-discovering invocation.
public enum Toolchain {
  /// The project generator a consumer uses.
  public enum Generator: String, Sendable {
    case tuist
    case xcodegen
  }

  /// A build/test request. A Tuist build names the `.xcworkspace`; an xcodegen
  /// build names the `.xcodeproj`. Either way xcodebuild is given an explicit
  /// container so it never auto-discovers, which is the Automerge-break fix.
  public struct Request: Sendable {
    public let generator: Generator
    public let scheme: String
    public let configuration: String
    public let workspace: String?
    public let project: String?
    public let destination: String?
    public let derivedDataPath: String?
    public let extraSettings: [String: String]
    /// Passthrough xcodebuild flags that are not `KEY=value` settings, such as
    /// `-allowProvisioningUpdates`, App Store Connect authentication options, or
    /// build-cache flags. A dev tool that needs these passes them here rather
    /// than naming xcodebuild itself.
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

  /// Resolve external SPM dependencies. Tuist fetches into `Tuist/.build`; xcodegen
  /// has no dependency step.
  @discardableResult
  public static func installDependencies(_ generator: Generator) -> Int32 {
    switch generator {
    case .tuist:
      Output.info("toolchain: tuist install")
      return Shell.runForwardingOutput("tuist", ["install"])
    case .xcodegen:
      Output.info("toolchain: xcodegen has no dependency install step")
      return 0
    }
  }

  // MARK: Signing-setting rejection

  /// The exit status a build returns when a request carries a forbidden signing
  /// setting. `EX_USAGE` (64) marks a caller error rather than a build failure.
  static let signingOverrideRejectionStatus: Int32 = 64

  /// The exit status a product build returns when the lint gates fail at the
  /// chokepoint, so a build that ran around the gates stops nonzero like `make
  /// check` would.
  static let gateFailureStatus: Int32 = 1

  /// xcodebuild build settings that decide code signing. swift-mk owns signing
  /// through an `XCODE_XCCONFIG_FILE` override, and a command-line `KEY=value`
  /// out-ranks that override, so a consumer that passed one of these would silently
  /// beat swift-mk's resolved identity. The chokepoint rejects them on every build
  /// path instead, closing the override gap for signing the same way `override
  /// LINT_GATES` closes it for gates. The dead-code coverage build is unaffected: it
  /// disables signing through `DeadcodeBuildConfig`'s xcconfig, never these
  /// per-invocation settings. Keys are listed in the canonical uppercase form
  /// xcodebuild uses; the matcher uppercases the incoming key so an oddly-cased
  /// setting is still caught.
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

  /// The first forbidden signing setting in a request, by its original spelling, or
  /// nil when none is present. Scans both `extraSettings` keys and any `KEY=value`
  /// token in `extraArguments`, since a setting can arrive either way. Public so the
  /// CLI can reject a forbidden setting before it ever reaches a build.
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

  /// Fail the build when a request carries a signing setting that would beat the
  /// swift-mk override, returning a nonzero status so the build stops loudly. Returns
  /// nil when the request is clean, so each entry point guards with one line.
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

  /// Build the scheme. Both generators build with xcodebuild against an explicit
  /// container (workspace for Tuist, project for xcodegen). xcodebuild is used
  /// rather than `tuist build` because a consumer that packages its product reads
  /// it from a known `-derivedDataPath`, and `tuist build` writes to Tuist's own
  /// DerivedData instead. The explicit `-workspace` is what resolves a
  /// Tuist-integrated external SPM dependency (the Automerge-break fix).
  ///
  /// This is a pure compile primitive: it does not run the lint gates. The gates
  /// run once in `swift-mk build` (the build chokepoint), so a `toolchain build`
  /// invoked as a consumer's `SWIFT_BUILD_CMD`, or a second time for a Metal/helper
  /// build, never double-gates. A direct `toolchain build` outside `make build` is
  /// blocked for agents by agent-gate, the same backstop as a raw `swift build`.
  @discardableResult
  public static func build(_ request: Request) -> Int32 {
    // Reject a forbidden signing setting first: it is a caller error in the request
    // itself (EX_USAGE), independent of whether this process is gated, so the result
    // does not depend on a live `make` ancestor. `test()` and `buildWithoutGateCheck`
    // already validate it first. Rejecting here, then passing
    // `signingAlreadyRejected: true` below, scans the settings exactly once; the
    // receipt path keeps `buildWithoutGateCheck`'s own check.
    if let rejection = rejectionForSigningOverride(request) {
      return rejection
    }
    // Refuse a product build that is not inside a swift-mk gated make flow, so a
    // direct `make <sub-target>` or a dev tool that reaches this cannot produce an
    // ungated artifact. The gate proof is anchored to the orchestrating `make`
    // process, so a legitimate secondary build (a Metal/resource compile, an
    // install/deploy step) still passes: that make is a live ancestor even after
    // the gated `swift-mk build` child exits. The in-process API path uses the
    // `build(_:receipt:)` overload instead, which carries a `GateReceipt` that only
    // a passed hard gate can mint, so a decoupled dev tool that never runs `make`
    // still compiles only behind the gate.
    if let refusal = GateProof.refusal(entry: "toolchain build") {
      return refusal
    }
    return buildWithoutGateCheck(request, signingAlreadyRejected: true)
  }

  /// The signing override the chokepoint applies to a build, so swift-mk owns
  /// build-time signing on every path, including a Swift dev tool that calls
  /// `Toolchain.build` directly without the make signing prelude. A caller that
  /// already exported `XCODE_XCCONFIG_FILE` (the make prelude) keeps it, since
  /// inheriting the parent environment carries that value. Otherwise the override
  /// is written from the environment's identity and team; with neither set,
  /// `SigningBuildConfig.write` returns nil and the build keeps its own signing.
  /// This never injects ad-hoc: the style follows the identity a consumer set.
  static func signingEnvironment() -> [String: String] {
    if !Env.get("XCODE_XCCONFIG_FILE").isEmpty {
      return [:]
    }
    guard let path = SigningBuildConfig.write() else {
      return [:]
    }
    return ["XCODE_XCCONFIG_FILE": path]
  }

  /// Test the scheme. The Tuist path uses native `tuist test
  /// --no-selective-testing`, the verified path that runs the full suite and
  /// resolves external SPM (selective testing otherwise skips everything). The
  /// xcodegen path tests the explicit project with xcodebuild.
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

  /// Build-for-testing the scheme through the public CLI. It is a compile surface,
  /// so it refuses unless this process is inside a swift-mk gated make flow. The
  /// dead-code gate no longer shells this command; it calls `buildCoverage(_:)`
  /// directly so the engine owns the full coverage matrix.
  @discardableResult
  public static func buildForTesting(_ request: Request) -> Int32 {
    if let refusal = GateProof.refusal(entry: "toolchain build-for-testing") {
      return refusal
    }
    return runXcodebuildForwarding(
      request, actions: ["build-for-testing"], environment: [:])
  }

  /// Build the scheme writing the full xcodebuild output to `logPath`, optionally
  /// running `clean` before `build`. The swiftlint analyze flow feeds this compiler
  /// log to `swiftlint analyze`, so the invocation is captured to disk rather than
  /// streamed. Applies the signing override like `build`, so the analyze build signs
  /// the same way a real build would. It is a compile surface, so it refuses unless
  /// this process is inside a swift-mk gated make flow.
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

  /// `xcodebuild -list -json` for a workspace or project, captured. A read-only
  /// query, routed here so the chokepoint stays the only site that names
  /// xcodebuild.
  public static func listSchemes(container: String, isWorkspace: Bool) -> Shell.Result {
    let flag = isWorkspace ? "-workspace" : "-project"
    return Shell.run("xcodebuild", ["-list", "-json", flag, container])
  }

  /// `xcodebuild -showBuildSettings` for a workspace scheme, captured. A read-only
  /// query the signing verifier reads; routed here so the chokepoint stays the only
  /// site that names xcodebuild.
  public static func showBuildSettings(
    workspace: String, scheme: String, configuration: String? = nil
  ) -> Shell.Result {
    var arguments = ["-showBuildSettings", "-workspace", workspace, "-scheme", scheme]
    if let configuration {
      arguments.append(contentsOf: ["-configuration", configuration])
    }
    return Shell.run("xcodebuild", arguments)
  }

  /// The `xcodebuild -showdestinations` transcript for a scheme, naming an explicit
  /// container so xcodebuild never auto-discovers. The dead-code coverage build reads
  /// the destinations a scheme can build from this, resolved through the consumer's
  /// xcconfigs the way a real build resolves them, rather than reconstructing platforms
  /// from the raw project file where a dynamically resolved `SUPPORTED_PLATFORMS` reads
  /// as absent.
  public static func showDestinations(
    container: String, isWorkspace: Bool, scheme: String
  ) -> Shell.Result {
    let containerFlag = isWorkspace ? "-workspace" : "-project"
    return Shell.run(
      "xcodebuild",
      ["-showdestinations", containerFlag, container, "-scheme", scheme])
  }

  /// Download an on-demand Xcode component via xcodebuild. The component name
  /// is caller-supplied data, never engine policy; routed here so the consumer
  /// does not name xcodebuild itself.
  @discardableResult
  public static func downloadComponent(_ name: String) -> Int32 {
    Output.info("toolchain: downloadComponent \(name)")
    return Shell.runForwardingOutput("xcodebuild", ["-downloadComponent", name])
  }

  // MARK: Argument assembly (exposed for tests)

  /// Tuist native test argument vector: `tuist test <scheme> --configuration <c>
  /// --no-selective-testing [--derived-data-path <path>] [-- <KEY=value> ...]`.
  /// Selective testing otherwise skips the whole suite. The derived-data path is
  /// pinned to the same `SWIFT_MK_DERIVED_DATA` the build and coverage paths use,
  /// so `tuist test` no longer falls back to system DerivedData and desyncs from
  /// `build` (the xcodegen test path already pins it through `xcodebuildArguments`).
  /// Extra `KEY=value` settings are forwarded after `--` to xcodebuild, the
  /// passthrough form `tuist test` documents, so a consumer that injects a build
  /// setting at test time (a helper-app path, for example) does not silently lose
  /// it the way it would if the setting were dropped.
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

  /// xcodebuild argument vector naming an explicit container, for one or more
  /// actions appended in order (for example `clean build`). A Tuist request names
  /// its `-workspace`; an xcodegen request names its `-project`. A missing container
  /// degrades to `-version` rather than letting xcodebuild auto-discover.
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
  /// Env values that turn a shared cache off.
  static let sharedCacheDisableTokens: Set<String> = ["off", "none", "0", "disabled"]

  /// Shared, content-addressed caches reused across every worktree and clone.
  /// `-derivedDataPath` stays per checkout so concurrent builds never collide, but the
  /// Clang module cache (`MODULE_CACHE_DIR`), the SPM clone dir
  /// (`-clonedSourcePackagesDirPath`), and the LLVM compilation-cache store
  /// (`COMPILATION_CACHE_CAS_PATH`) are keyed by content, so pointing every build at one
  /// location reuses them safely and avoids a multi-GB copy per worktree.
  /// `SWIFT_MK_MODULE_CACHE` / `SWIFT_MK_SPM_CACHE` / `SWIFT_MK_XCODE_CACHE_PATH` set the
  /// locations (the make layer exports the defaults under `~/Library/Caches/swift-mk`);
  /// an env value of `off`/`none` opts out, and an unset value falls back to the
  /// built-in default.
  ///
  /// The CAS store is pinned OUTSIDE DerivedData on purpose. Xcode defaults it to
  /// `<derivedDataPath>/CompilationCache.noindex`, where the dead-code coverage build's
  /// `rm -rf` of DerivedData would destroy it between runs, so cross-run replay never
  /// happened. Pinning it to the shared root makes the store survive that wipe and
  /// persist across runners. The setting is inert when compilation caching is off (the
  /// no-cache coverage build), so injecting it on every path is safe.
  ///
  /// Pool builds keep only the SourcePackages checkouts on the shared host mount.
  /// Xcode's package-support cache and the Clang module cache are write-heavy, so
  /// they move to a VM-local per-slot root when `SWIFT_MK_POOL=1`.
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

  /// Resolve one shared-cache env var into a usable directory path, or nil when the
  /// value names a disable token. An empty value falls back to the built-in default
  /// under `~/Library/Caches/swift-mk`. Pure (no filesystem writes); xcodebuild and
  /// clang create the directory at build time. Pass `honorDisableToken: false` for a
  /// cache the engine owns with no consumer opt-out, where a disable token is ignored
  /// and resolves to the default path so the value only ever relocates the store.
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
    // Honor $HOME (what the cache-plan path list and the home-rooted tool caches
    // use), falling back to the account home only when it is unset, so the build and
    // the cache plan resolve the shared caches to the same location.
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
  /// The full `xcodebuild -version` string, trimmed, for cache keying. Returns a
  /// stable fallback when Xcode is unavailable. Lives in Toolchain because this is
  /// the one place allowed to invoke the build toolchain directly.
  public static func xcodeVersionString() -> String {
    Output.debug("toolchain: reading xcodebuild -version")
    return probedToolVersion("xcodebuild", ["-version"], fallback: "xcode-unavailable")
  }

  /// The full `swift --version` string, trimmed, for cache keying. Returns a stable
  /// fallback when Swift is unavailable.
  public static func swiftVersionString() -> String {
    Output.debug("toolchain: reading swift --version")
    return probedToolVersion("swift", ["--version"], fallback: "swift-unavailable")
  }

  /// Trailing whitespace is stripped to match how shell `$(...)` command substitution
  /// drops trailing newlines, so the sanitized cache key matches the former script.
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
  /// The exit status returned when a prebuild command fails before xcodebuild.
  static let prebuildFailureStatus: Int32 = 1

  /// The single module-internal site that streams an xcodebuild action vector.
  /// Every build, build-for-testing, and analyze path funnels through here, so the
  /// raw `xcodebuild` spawn lives in this one chokepoint file and the build-tooling
  /// audit stays the only backstop against any other site naming it.
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

  /// The captured-output variant of the raw invocation, capturing stdout in full
  /// while forwarding stderr live, for the dead-code coverage build whose fail-hard
  /// diagnosis needs the transcript.
  static func runXcodebuildCapturing(
    _ request: Request,
    actions: [String],
    environment: [String: String],
    resultBundleDirectory: String? = nil
  ) -> Shell.StreamingResult {
    Output.debug("toolchain: xcodebuild (captured) \(actions.joined(separator: " "))")
    guard ToolchainPrebuild.run() else {
      return Shell.StreamingResult(status: prebuildFailureStatus, stdout: "", timedOut: false)
    }
    let arguments = xcodebuildArguments(
      request, actions: actions, resultBundleDirectory: resultBundleDirectory)
    return Shell.runStreamingStderr("xcodebuild", arguments, environment: environment)
  }
}
