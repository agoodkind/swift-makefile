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
    let binDir = root + "/fakebin"
    try manager.createDirectory(atPath: root + "/Sources", withIntermediateDirectories: true)
    try manager.createDirectory(atPath: binDir, withIntermediateDirectories: true)
    try "// fake source\nlet appValue = 1\n".write(
      toFile: root + "/Sources/App.swift", atomically: true, encoding: .utf8)
    // packageManifest declares a target covering Sources so the coverage gate sees
    // App.swift as package-scanned, the way a real consumer's package covers its
    // sources; a degenerate no-target package would read as an unscanned-own-code bypass.
    try packageManifest.write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)

    let xcodebuildMarker = root + "/xcodebuild-ran"
    try writeFakes(binDir: binDir)

    let savedCwd = manager.currentDirectoryPath
    let saved = Environment.snapshot([
      "PATH", "SWIFT_FORMAT", "SWIFTLINT", "PERIPHERY", "OSV_SCANNER",
      "SWIFTCHECK_EXTRA_BIN", "SWIFTCHECK_EXTRA_FLAGS", "SWIFTCHECK_EXTRA_BUILD_REPO",
      "FAKE_XCODEBUILD_MARKER", "FAKE_SWIFTLINT_FAIL", "SWIFT_MK_ROOT",
      "SWIFT_MK_XCODE_BUILD", "SWIFT_DEADCODE_BUILD_CMD", "SWIFT_BUILD_CMD",
      "SWIFT_MK_SIGN_TEAM", "DEVELOPMENT_TEAM", "XCODE_XCCONFIG_FILE",
      "LINT_GATES", "LINT_FILES", "SWIFTLINT_TARGETS", "BYPASS_LINT",
    ])
    defer {
      saved.restore()
      manager.changeCurrentDirectoryPath(savedCwd)
      removeTemporary(root)
    }

    let priorPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    setenv("PATH", binDir + ":" + priorPath, 1)
    setenv("SWIFT_FORMAT", "swift-format", 1)
    setenv("SWIFTLINT", "swiftlint", 1)
    setenv("PERIPHERY", "periphery", 1)
    setenv("OSV_SCANNER", "osv-scanner", 1)
    setenv("SWIFTCHECK_EXTRA_BIN", binDir + "/swiftcheck-extra", 1)
    setenv("SWIFTCHECK_EXTRA_FLAGS", "", 1)
    setenv("FAKE_XCODEBUILD_MARKER", xcodebuildMarker, 1)
    setenv("SWIFT_MK_ROOT", root, 1)
    // A pure SwiftPM checkout: no Xcode coverage build, so the dead-code gate runs
    // the periphery package scan only.
    unsetenv("SWIFT_MK_XCODE_BUILD")
    unsetenv("SWIFT_DEADCODE_BUILD_CMD")
    unsetenv("SWIFT_BUILD_CMD")
    unsetenv("XCODE_XCCONFIG_FILE")
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

    manager.changeCurrentDirectoryPath(root)
    let runGit = Shell.run("git", ["-C", root, "init", "-q"])
    if runGit.status != 0 {
      Output.error("test: git init failed in \(root): \(runGit.combined)")
    }
    _ = Shell.run("git", ["-C", root, "add", "-A"])

    try body(Setup(root: root, xcodebuildMarker: xcodebuildMarker))
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
      if [ -n "$FAKE_XCODEBUILD_MARKER" ]; then
        : > "$FAKE_XCODEBUILD_MARKER"
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
