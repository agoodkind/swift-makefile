//
//  SwiftPM.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - SwiftPM

/// The chokepoint that drives the `swift` package manager, the SwiftPM peer of
/// `Toolchain`. `Toolchain` is the one site that runs `xcodebuild`; `SwiftPM` is the
/// one site that runs `swift build`/`swift test`/`swift run`, so a consumer or a dev
/// tool never shells `swift` directly. Every invocation is authorized the same two ways
/// as `Toolchain`: a make-path entry proves a live `make`/`swift-mk` ancestor through
/// `GateProof`, and an in-process entry carries a `GateReceipt` that only a passed hard
/// gate can mint. Each `swift` process runs inside `BuildLock`, so two builds in one
/// worktree serialize on the shared `.build` instead of aborting each other.
public enum SwiftPM {
  /// A non-zero status for an engine-internal precondition failure: a product operation
  /// invoked without a product name, a built product whose binary cannot be resolved, or
  /// a failed post-build-tests staging step.
  private static let resolutionFailureStatus: Int32 = 1

  // MARK: Configuration

  /// The build configuration, named the Xcode way (`Debug`/`Release`) at the call site
  /// and lowered to SwiftPM's `-c debug`/`-c release`.
  public enum Configuration: String, Sendable {
    case debug
    case release
  }

  // MARK: Requests

  /// One `swift build`/`swift run` against a package directory.
  public struct Request: Sendable {
    /// The `--package-path`; nil builds the package in the current directory.
    public let packagePath: String?
    public let configuration: Configuration
    /// The `--product`; nil builds the whole package.
    public let product: String?
    public let extraArguments: [String]
    /// Merged over the parent environment for the spawned `swift` (a dev tool's
    /// signing-disabled or CC/CXX environment); empty inherits the parent unchanged.
    public let environment: [String: String]

    public init(
      packagePath: String? = nil,
      configuration: Configuration = .debug,
      product: String? = nil,
      extraArguments: [String] = [],
      environment: [String: String] = [:]
    ) {
      self.packagePath = packagePath
      self.configuration = configuration
      self.product = product
      self.extraArguments = extraArguments
      self.environment = environment
    }
  }

  /// A `swift test` request. `buildTests` runs `swift build --build-tests` first as a
  /// separate step, `afterBuildTests` runs between that build and the test inside the
  /// one held build lock (lmd stages its metallib there), `skipBuild` adds
  /// `--skip-build`, and `filter` adds `--filter`.
  public struct TestRequest: Sendable {
    public let package: Request
    public let buildTests: Bool
    public let skipBuild: Bool
    public let filter: String?
    public let afterBuildTests: (@Sendable () -> Bool)?

    @preconcurrency
    public init(
      package: Request,
      buildTests: Bool = false,
      skipBuild: Bool = false,
      filter: String? = nil,
      afterBuildTests: (@Sendable () -> Bool)? = nil
    ) {
      self.package = package
      self.buildTests = buildTests
      self.skipBuild = skipBuild
      self.filter = filter
      self.afterBuildTests = afterBuildTests
    }
  }

  /// A product build result for a caller that then execs the binary (`run`, the CLI
  /// `run-tool`, a dev tool's install step). `binPath` is the resolved
  /// `swift build --show-bin-path` directory; `executablePath` is the product inside it.
  public struct ProductBuild: Sendable {
    public let status: Int32
    public let binPath: String?
    public let executablePath: String?
  }

  // MARK: Make-path entries (GateProof)

  /// Build the package, refused when not inside a swift-mk gated make flow.
  @discardableResult
  public static func build(_ request: Request) -> Int32 {
    if let refusal = GateProof.refusal(entry: "swiftpm build") {
      return refusal
    }
    return buildWithoutGateCheck(request)
  }

  /// Build a product and resolve its binary path.
  public static func buildProduct(_ request: Request) -> ProductBuild {
    if let refusal = GateProof.refusal(entry: "swiftpm build-product") {
      return ProductBuild(status: refusal, binPath: nil, executablePath: nil)
    }
    return buildProductWithoutGateCheck(request)
  }

  /// Build the product if needed, then exec it forwarding `arguments`.
  @discardableResult
  public static func run(_ request: Request, arguments: [String]) -> Int32 {
    if let refusal = GateProof.refusal(entry: "swiftpm run") {
      return refusal
    }
    return runWithoutGateCheck(request, arguments: arguments)
  }

  /// Test the package.
  @discardableResult
  public static func test(_ request: TestRequest) -> Int32 {
    if let refusal = GateProof.refusal(entry: "swiftpm test") {
      return refusal
    }
    return testWithoutGateCheck(request)
  }

  // MARK: In-process entries (GateReceipt)

  @discardableResult
  public static func build(_ request: Request, receipt: GateReceipt) -> Int32 {
    _ = receipt
    return buildWithoutGateCheck(request)
  }

  public static func buildProduct(_ request: Request, receipt: GateReceipt) -> ProductBuild {
    _ = receipt
    return buildProductWithoutGateCheck(request)
  }

  @discardableResult
  public static func run(
    _ request: Request, arguments: [String], receipt: GateReceipt
  ) -> Int32 {
    _ = receipt
    return runWithoutGateCheck(request, arguments: arguments)
  }

  @discardableResult
  public static func test(_ request: TestRequest, receipt: GateReceipt) -> Int32 {
    _ = receipt
    return testWithoutGateCheck(request)
  }

  // MARK: No-artifact operations (no gate, lock only)

  /// The package's built-products directory from `swift build --show-bin-path`. It
  /// produces no artifact, so it needs no gate, but it resolves the package and may
  /// write `.build`, so it still takes the build lock.
  public static func binPath(_ request: Request) -> String? {
    Output.debug("swiftpm: resolving bin path")
    let arguments =
      ["build"] + cacheArguments() + packageArguments(request)
      + configurationArguments(request) + ["--show-bin-path"]
    let result = BuildLock.withLock {
      Shell.run("swift", arguments, environment: request.environment)
    }
    guard result.status == 0 else {
      return nil
    }
    // Take the last non-empty line: `--show-bin-path` prints the path last, after any
    // package-resolution notes.
    let lines = result.stdout.split(whereSeparator: \.isNewline)
    guard let last = lines.last else {
      return nil
    }
    let trimmed = last.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Remove the package build directory with `swift package clean`. It produces no build
  /// artifact, so it needs no gate, but it mutates `.build`, so it runs under the build
  /// lock to never race a build in the same worktree. Output is forwarded, not captured,
  /// so a `clean` failure shows the user the underlying error rather than a bare status.
  @discardableResult
  public static func clean(_ request: Request = Request()) -> Int32 {
    Output.debug("swiftpm: cleaning the package build directory")
    return BuildLock.withLock {
      Shell.runForwardingOutput(
        "swift",
        ["package"] + packageArguments(request) + ["clean"],
        environment: request.environment
      )
    }
  }

  /// `swift package describe --type json` for the package, captured. A read-only query
  /// (no artifact, so no gate), wrapped in the build lock because it resolves the
  /// package and may write `.build`. Returns nil on a nonzero status.
  public static func describePackageJSON(_ request: Request = Request()) -> String? {
    Output.debug("swiftpm: describing package targets")
    let arguments = ["package"] + packageArguments(request) + ["describe", "--type", "json"]
    let result = BuildLock.withLock {
      Shell.run("swift", arguments, environment: request.environment)
    }
    guard result.status == 0 else {
      return nil
    }
    return result.stdout
  }

  // MARK: Engine-internal

  /// Build a product for an engine-owned tool (the swiftcheck analyzer) with the build
  /// lock but NOT the gate. This builds swift-mk's own tooling while a gate is already
  /// running, so there is no consumer-product gate to satisfy and it must not be
  /// refused. Engine callers in `SwiftMkCore` only.
  static func buildProductInternal(_ request: Request) -> ProductBuild {
    buildProductWithoutGateCheck(request)
  }

  // MARK: Shared bodies

  static func buildWithoutGateCheck(_ request: Request) -> Int32 {
    runSwift("build", request, extra: productArguments(request))
  }

  static func buildProductWithoutGateCheck(_ request: Request) -> ProductBuild {
    // A product operation needs a product name. Fail fast with a clear message rather
    // than building the whole package and returning a nil executable later.
    guard let product = request.product, !product.isEmpty else {
      Output.error("swiftpm build-product: a product name is required")
      return ProductBuild(status: resolutionFailureStatus, binPath: nil, executablePath: nil)
    }
    let status = buildWithoutGateCheck(request)
    guard status == 0 else {
      return ProductBuild(status: status, binPath: nil, executablePath: nil)
    }
    let binPath = binPath(request)
    let executablePath = executablePath(binPath: binPath, product: product)
    return ProductBuild(status: status, binPath: binPath, executablePath: executablePath)
  }

  static func runWithoutGateCheck(_ request: Request, arguments: [String]) -> Int32 {
    let built = buildProductWithoutGateCheck(request)
    guard built.status == 0 else {
      return built.status
    }
    guard let executablePath = built.executablePath else {
      Output.error("swiftpm run: could not resolve the built product binary")
      return resolutionFailureStatus
    }
    // Exec the built binary OUTSIDE the build lock: a long-running tool must not hold
    // the worktree build lock for its whole runtime.
    return Shell.runForwardingOutput(
      executablePath, arguments, environment: request.environment)
  }

  static func testWithoutGateCheck(_ request: TestRequest) -> Int32 {
    // Hold the lock across the whole sequence so the metallib staging step runs between
    // `--build-tests` and `--skip-build` without another build mutating `.build`. The
    // inner `runSwift` calls re-enter the lock through its depth counter.
    BuildLock.withLock {
      if request.buildTests {
        let buildStatus = runSwift(
          "build", request.package, extra: ["--build-tests"])
        guard buildStatus == 0 else {
          return buildStatus
        }
        if let afterBuildTests = request.afterBuildTests, !afterBuildTests() {
          Output.error("swiftpm test: post-build-tests staging step failed")
          return resolutionFailureStatus
        }
      }
      var testExtra: [String] = []
      if request.skipBuild {
        testExtra.append("--skip-build")
      }
      if let filter = request.filter {
        testExtra.append(contentsOf: ["--filter", filter])
      }
      return runSwift("test", request.package, extra: testExtra)
    }
  }

  // MARK: The single `swift` site

  /// The one place a `swift` subcommand is spawned, inside the per-worktree build lock.
  static func runSwift(_ subcommand: String, _ request: Request, extra: [String]) -> Int32 {
    let arguments =
      [subcommand] + cacheArguments() + packageArguments(request)
      + configurationArguments(request) + extra + request.extraArguments
    return BuildLock.withLock {
      Shell.runForwardingOutput("swift", arguments, environment: request.environment)
    }
  }

  // MARK: Argument assembly

  /// The shared SwiftPM cache flags the make layer computes, injected by the engine so
  /// no consumer hand-rolls them. Includes compilation-cache flags when the engine's
  /// `SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED` flag is YES.
  static func cacheArguments() -> [String] {
    var args = Env.words(Env.get("SWIFT_MK_SWIFTPM_CACHE_ARGS"))
    args.append(contentsOf: compileCacheArguments())
    return args
  }

  /// The LLVM compilation-cache flags for `swift build`/`swift test` when the enable
  /// flag is YES and the CAS store path is usable. The make layer sets the enable flag
  /// on by default on any toolchain that supports `-cache-compile-job` (Swift 6.3+) and
  /// to NO otherwise, so these flags never reach an unsupporting compiler.
  private static func compileCacheArguments() -> [String] {
    guard Env.get("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED") == "YES" else {
      return []
    }
    // Resolve the store path the same way the cache-path list does. The engine owns
    // this cache with no consumer opt-out, so a disable token is ignored (the value only
    // relocates the store), and the path always resolves.
    guard
      let path = Toolchain.resolvedSharedCachePath(
        "SWIFT_MK_SWIFTPM_CACHE_PATH",
        defaultSubdirectory: "SwiftPMCompilationCache",
        honorDisableToken: false)
    else {
      return []
    }
    var flags: [String] = [
      "-Xswiftc",
      "-explicit-module-build",
      "-Xswiftc",
      "-cache-compile-job",
      "-Xswiftc",
      "-cas-path",
      "-Xswiftc",
      path,
    ]
    if isTruthy(Env.get("SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS")) {
      flags.append(contentsOf: ["-Xswiftc", "-Rcache-compile-job"])
    }
    return flags
  }

  /// Whether a raw env-variable value is truthy. Matches the same token set as the
  /// swift.mk `filter` lists for `_DIAGNOSTICS` flags.
  private static func isTruthy(_ value: String) -> Bool {
    ["1", "true", "yes", "on"].contains(value.lowercased())
  }

  static func packageArguments(_ request: Request) -> [String] {
    guard let packagePath = request.packagePath else {
      return []
    }
    return ["--package-path", packagePath]
  }

  static func configurationArguments(_ request: Request) -> [String] {
    ["-c", request.configuration.rawValue]
  }

  static func productArguments(_ request: Request) -> [String] {
    guard let product = request.product else {
      return []
    }
    return ["--product", product]
  }

  static func executablePath(binPath: String?, product: String?) -> String? {
    guard let binPath, let product else {
      return nil
    }
    return (binPath as NSString).appendingPathComponent(product)
  }
}
