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
  /// Returned when a product build succeeds but its binary cannot be resolved.
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

  // MARK: Read-only query (no gate, no artifact)

  /// The package's built-products directory from `swift build --show-bin-path`. It
  /// produces no artifact, so it needs no gate, but it resolves the package and may
  /// write `.build`, so it still takes the build lock.
  public static func binPath(_ request: Request) -> String? {
    let arguments =
      ["build"] + cacheArguments() + packageArguments(request)
      + configurationArguments(request) + ["--show-bin-path"]
    let result = BuildLock.withLock {
      Shell.run("swift", arguments, environment: request.environment)
    }
    guard result.status == 0 else {
      return nil
    }
    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  // MARK: Shared bodies

  static func buildWithoutGateCheck(_ request: Request) -> Int32 {
    runSwift("build", request, extra: productArguments(request))
  }

  static func buildProductWithoutGateCheck(_ request: Request) -> ProductBuild {
    let status = buildWithoutGateCheck(request)
    guard status == 0 else {
      return ProductBuild(status: status, binPath: nil, executablePath: nil)
    }
    let binPath = binPath(request)
    let executablePath = executablePath(binPath: binPath, product: request.product)
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
  /// no consumer hand-rolls them.
  static func cacheArguments() -> [String] {
    Env.words(Env.get("SWIFT_MK_SWIFTPM_CACHE_ARGS"))
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
