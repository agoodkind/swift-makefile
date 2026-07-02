//
//  GatedBuildHarness.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation

@testable import SwiftMkCore

// MARK: - Test cleanup

/// Remove a temporary path, logging rather than discarding a failure, so test
/// teardown satisfies the cleanup-error and silent-try rules the gate enforces.
func removeTemporary(_ path: String) {
  do {
    try FileManager.default.removeItem(atPath: path)
  } catch {
    Output.error("test: could not remove \(path): \(error)")
  }
}

// MARK: - TestGlobalLock

/// A process-wide lock that serializes every test helper which mutates the current
/// working directory or the process environment. Swift Testing's `.serialized`
/// only serializes within one suite, but several suites here chdir and setenv, and
/// they run in parallel, so a shared lock is what keeps them from clobbering each
/// other's global state.
enum TestGlobalLock {
  static let lock = NSRecursiveLock()

  static func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}

// MARK: - GatedBuildHarness

/// A throwaway checkout with fake build tools on `PATH`, used to drive
/// `GatedBuild.run` end to end without a real swiftlint/periphery/xcodebuild and
/// with no `make` ancestor. The fakes report no findings by default so the gate
/// passes; `failSwiftlint` makes the swiftlint fake emit one violation so the gate
/// blocks the compile. The xcodebuild fake writes a marker file, so a test can
/// assert whether the compile actually ran.
enum GatedBuildHarness {
  /// The temporary checkout and the markers a test inspects.
  struct Setup {
    let root: String
    let xcodebuildMarker: String
    let xcodebuildArgumentsLog: String
    let xcodebuildEnvironmentLog: String
  }

  private struct Paths {
    let root: String
    let binDir: String
    let xcodebuildMarker: String
    let xcodebuildArgumentsLog: String
    let xcodebuildEnvironmentLog: String
  }

  /// A SwiftPM manifest with one target covering Sources, so the coverage-completeness
  /// gate sees the checkout's `App.swift` as package-scanned.
  private static let packageManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(name: "App", targets: [.target(name: "App", path: "Sources")])

    """

  /// Run `body` inside a fake checkout, restoring the working directory and the
  /// mutated environment afterward. Serialize callers (the working directory and
  /// process environment are global).
  static func run(
    failSwiftlint: Bool = false,
    signingTeam: String? = nil,
    _ body: (Setup) throws -> Void
  ) throws {
    try TestGlobalLock.withLock {
      try runLocked(failSwiftlint: failSwiftlint, signingTeam: signingTeam, body)
    }
  }

  private static func runLocked(
    failSwiftlint: Bool,
    signingTeam: String?,
    _ body: (Setup) throws -> Void
  ) throws {
    let manager = FileManager.default
    let root = NSTemporaryDirectory() + "swiftmk-gated-" + UUID().uuidString
    let paths = Paths(
      root: root,
      binDir: root + "/fakebin",
      xcodebuildMarker: root + "/xcodebuild-ran",
      xcodebuildArgumentsLog: root + "/xcodebuild-args.log",
      xcodebuildEnvironmentLog: root + "/xcodebuild-env.log")
    try writeCheckout(paths: paths, manager: manager)
    try writeFakes(binDir: paths.binDir)

    let savedCwd = manager.currentDirectoryPath
    let saved = Environment.snapshot([
      "PATH", "SWIFT_FORMAT", "SWIFTLINT", "PERIPHERY", "OSV_SCANNER",
      "SWIFTCHECK_EXTRA_BIN", "SWIFTCHECK_EXTRA_FLAGS", "SWIFTCHECK_EXTRA_BUILD_REPO",
      "FAKE_XCODEBUILD_MARKER", "FAKE_XCODEBUILD_ARGS_LOG", "FAKE_XCODEBUILD_ENV_LOG",
      "FAKE_XCODEBUILD_FAIL_SCHEME", "FAKE_XCODEBUILD_FAIL_STATUS",
      "FAKE_SWIFTLINT_FAIL", "SWIFT_MK_ROOT",
      "SWIFT_MK_XCODE_BUILD", "SWIFT_BUILD_CMD",
      "SWIFT_MK_SIGN_TEAM", "DEVELOPMENT_TEAM", "XCODE_XCCONFIG_FILE",
      "LINT_GATES", "LINT_FILES", "SWIFTLINT_TARGETS", "BYPASS_LINT",
    ])
    defer {
      saved.restore()
      manager.changeCurrentDirectoryPath(savedCwd)
      removeTemporary(root)
    }

    let priorPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    configureEnvironment(
      paths: paths,
      priorPath: priorPath,
      failSwiftlint: failSwiftlint,
      signingTeam: signingTeam)

    manager.changeCurrentDirectoryPath(root)
    let runGit = Shell.run("git", ["-C", root, "init", "-q"])
    if runGit.status != 0 {
      Output.error("test: git init failed in \(root): \(runGit.combined)")
    }
    _ = Shell.run("git", ["-C", root, "add", "-A"])

    try body(
      Setup(
        root: root,
        xcodebuildMarker: paths.xcodebuildMarker,
        xcodebuildArgumentsLog: paths.xcodebuildArgumentsLog,
        xcodebuildEnvironmentLog: paths.xcodebuildEnvironmentLog))
  }

  private static func writeCheckout(paths: Paths, manager: FileManager) throws {
    try manager.createDirectory(
      atPath: paths.root + "/Sources", withIntermediateDirectories: true)
    try manager.createDirectory(atPath: paths.binDir, withIntermediateDirectories: true)
    try "// fake source\nlet appValue = 1\n".write(
      toFile: paths.root + "/Sources/App.swift", atomically: true, encoding: .utf8)
    // packageManifest declares a target covering Sources so the coverage gate sees
    // App.swift as package-scanned, the way a real consumer's package covers its
    // sources; a degenerate no-target package would read as an unscanned-own-code bypass.
    try packageManifest.write(
      toFile: paths.root + "/Package.swift", atomically: true, encoding: .utf8)
  }

  private static func configureEnvironment(
    paths: Paths,
    priorPath: String,
    failSwiftlint: Bool,
    signingTeam: String?
  ) {
    Output.debug("test: configuring fake build environment")
    setenv("PATH", paths.binDir + ":" + priorPath, 1)
    setenv("SWIFT_FORMAT", "swift-format", 1)
    setenv("SWIFTLINT", "swiftlint", 1)
    setenv("PERIPHERY", "periphery", 1)
    setenv("OSV_SCANNER", "osv-scanner", 1)
    setenv("SWIFTCHECK_EXTRA_BIN", paths.binDir + "/swiftcheck-extra", 1)
    setenv("SWIFTCHECK_EXTRA_FLAGS", "", 1)
    setenv("FAKE_XCODEBUILD_MARKER", paths.xcodebuildMarker, 1)
    setenv("FAKE_XCODEBUILD_ARGS_LOG", paths.xcodebuildArgumentsLog, 1)
    setenv("FAKE_XCODEBUILD_ENV_LOG", paths.xcodebuildEnvironmentLog, 1)
    setenv("SWIFT_MK_ROOT", paths.root, 1)
    unsetenv("SWIFT_MK_XCODE_BUILD")
    unsetenv("SWIFT_BUILD_CMD")
    unsetenv("XCODE_XCCONFIG_FILE")
    configureOptionalEnvironment(failSwiftlint: failSwiftlint, signingTeam: signingTeam)
  }

  private static func configureOptionalEnvironment(failSwiftlint: Bool, signingTeam: String?) {
    if failSwiftlint {
      setenv("FAKE_SWIFTLINT_FAIL", "1", 1)
    } else {
      unsetenv("FAKE_SWIFTLINT_FAIL")
    }
    if let signingTeam {
      setenv("SWIFT_MK_SIGN_TEAM", signingTeam, 1)
    } else {
      unsetenv("SWIFT_MK_SIGN_TEAM")
      unsetenv("DEVELOPMENT_TEAM")
    }
  }

  /// A `Toolchain.Request` whose container is named, so the fake xcodebuild gets a
  /// real-looking argument vector rather than the `-version` degrade.
  static func compileRequest() -> Toolchain.Request {
    Toolchain.Request(
      generator: .tuist,
      scheme: "App",
      configuration: "Debug",
      workspace: "App.xcworkspace")
  }

  // MARK: Fakes

  private static func writeFakes(binDir: String) throws {
    Output.debug("test: writing fake build tools to \(binDir)")
    let swiftlint = """
      #!/bin/sh
      if [ -n "$FAKE_SWIFTLINT_FAIL" ]; then
        printf '[{"rule_id":"fake_rule","reason":"fake violation",'
        printf '"file":"%s/FakeViolation.swift",' "$PWD"
        printf '"line":1,"character":1,"severity":"warning"}]'
        exit 2
      fi
      printf '[]'
      exit 0
      """
    let passthrough = """
      #!/bin/sh
      exit 0
      """
    let xcodebuild = """
      #!/bin/sh
      scheme=""
      previous=""
      for arg in "$@"; do
        if [ "$previous" = "-scheme" ]; then
          scheme="$arg"
        fi
        previous="$arg"
      done
      if [ -n "$FAKE_XCODEBUILD_MARKER" ]; then
        : > "$FAKE_XCODEBUILD_MARKER"
      fi
      if [ -n "$FAKE_XCODEBUILD_ARGS_LOG" ]; then
        {
          printf 'BEGIN\\n'
          for arg in "$@"; do
            printf '%s\\n' "$arg"
          done
          printf 'END\\n'
        } >> "$FAKE_XCODEBUILD_ARGS_LOG"
      fi
      if [ -n "$FAKE_XCODEBUILD_ENV_LOG" ]; then
        printf '%s\\n' "$SWIFT_MK_RESULT_BUNDLE_DIR" >> "$FAKE_XCODEBUILD_ENV_LOG"
      fi
      printf 'fake xcodebuild scheme=%s\\n' "$scheme"
      if [ -n "$FAKE_XCODEBUILD_FAIL_SCHEME" ] \\
        && [ "$scheme" = "$FAKE_XCODEBUILD_FAIL_SCHEME" ]; then
        exit "${FAKE_XCODEBUILD_FAIL_STATUS:-42}"
      fi
      exit 0
      """
    try writeExecutable(swiftlint, to: binDir + "/swiftlint")
    try writeExecutable(passthrough, to: binDir + "/swift-format")
    try writeExecutable(passthrough, to: binDir + "/periphery")
    try writeExecutable(passthrough, to: binDir + "/osv-scanner")
    try writeExecutable(passthrough, to: binDir + "/swiftcheck-extra")
    try writeExecutable(xcodebuild, to: binDir + "/xcodebuild")
  }

  private static func writeExecutable(_ body: String, to path: String) throws {
    try body.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: Int16(0o755)], ofItemAtPath: path)
  }
}

// MARK: - Box

/// A locked reference cell so a `@Sendable` test closure can record what it observed
/// and the test body can read it back. The closures run synchronously, so the lock
/// only satisfies the Sendable checker.
final class Box<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) {
    stored = value
  }

  var value: Value {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      stored = newValue
    }
  }
}

// MARK: - Environment snapshot

/// Save and restore a set of environment variables around a test that mutates them.
enum Environment {
  struct Snapshot {
    let values: [String: String?]

    func restore() {
      for (name, value) in values {
        if let value {
          setenv(name, value, 1)
        } else {
          unsetenv(name)
        }
      }
    }
  }

  static func snapshot(_ names: [String]) -> Snapshot {
    var values: [String: String?] = [:]
    for name in names {
      values[name] = ProcessInfo.processInfo.environment[name]
    }
    return Snapshot(values: values)
  }
}
