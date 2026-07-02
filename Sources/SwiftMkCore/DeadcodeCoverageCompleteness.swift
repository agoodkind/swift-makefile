//
//  DeadcodeCoverageCompleteness.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-30.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - DeadcodeCoverageCompleteness

/// Asserts that every owned Swift source is covered by at least one dead-code scan.
///
/// The gate runs two scans: a SwiftPM package scan over the package targets, and an
/// Xcode scan over a built index store. A consumer whose own Swift lives only in
/// Xcode targets, with no Xcode scan, would have that code scanned by neither, which
/// is a silent bypass. This compares the owned source set against the union of what
/// the two scans covered, and fails the gate, naming the files, when any owned source
/// is unscanned. The result is a pure set difference with no env knob, so a consumer
/// cannot shrink what the gate checks.
enum DeadcodeCoverageCompleteness {
  /// How many uncovered paths to print inline before deferring to the full log.
  private static let inlineLimit = 20

  /// The `#!` byte prefix that marks a directly-run script.
  private static let shebangPrefix = Array("#!".utf8)

  /// Owned Swift sources that no scan covered, sorted. The core comparison.
  static func uncovered(
    owned: Set<String>, packageCovered: Set<String>, xcodeCovered: Set<String>
  ) -> [String] {
    owned.subtracting(packageCovered).subtracting(xcodeCovered).sorted()
  }

  /// Run the assertion. `xcodeIndexStorePath` is the store the Xcode scan built, or
  /// nil when no Xcode scan ran (a SwiftPM consumer or a stray on-disk project).
  /// Returns an `IndexCompleteness.Outcome`: `.complete` lets the gate proceed,
  /// `.incomplete` fails it loud with the uncovered files and the remediation.
  static func assert(
    xcodeIndexStorePath: String?, context: PathContext
  ) -> IndexCompleteness.Outcome {
    let owned = ownedSwiftFiles(context: context)
    if owned.isEmpty {
      return .complete("deadcode: coverage complete, no owned Swift sources")
    }
    let packageCovered = packageCoveredFiles(context: context, owned: owned)
    let xcodeCovered: Set<String>
    do {
      xcodeCovered = try indexedFiles(xcodeIndexStorePath)
    } catch {
      // A non-nil store path that cannot be read is a real error, not a missing
      // coverage build, so report it as itself rather than as unscanned own code.
      return .incomplete(
        "lint-deadcode: could not read the Xcode index store at "
          + "\(xcodeIndexStorePath ?? "(none)"): \(error)")
    }
    let missing = uncovered(
      owned: owned, packageCovered: packageCovered, xcodeCovered: xcodeCovered)
    if missing.isEmpty {
      return .complete(
        "deadcode: coverage complete, \(owned.count) owned Swift sources scanned")
    }
    return .incomplete(incompleteMessage(missing: missing, context: context))
  }

  // MARK: Owned set

  /// The owned Swift sources the gate must see scanned: every `.swift` file in the
  /// hard-gate source set, minus the project manifests (which are not dead-code
  /// scanned), resolved to absolute symlink-resolved paths so they compare against the
  /// indexed and package sets. Reuses `LintSourceSet`, so a consumer cannot narrow it.
  static func ownedSwiftFiles(context: PathContext) -> Set<String> {
    var files: Set<String> = []
    for path in LintSourceSet.resolve(context: context) where path.hasSuffix(".swift") {
      if isManifestOrConfig(path) {
        continue
      }
      let onDisk = absolute(path, in: context)
      // A `#!`-prefixed Swift file is a standalone script run by the interpreter, not a
      // source compiled into any build target, so no index store ever records it and no
      // scan can cover it. App code in an Xcode target carries no shebang, so excluding
      // shebang scripts never hides the bypass this check exists to catch.
      if isShebangScript(onDisk) {
        continue
      }
      files.insert(IndexCompleteness.standardize(onDisk))
    }
    return files
  }

  /// True when a working-directory-relative path is a build-system manifest or Tuist
  /// configuration rather than a target source. SwiftPM and Xcode manifests
  /// (`Package.swift`, `Project.swift`, `Workspace.swift`, `project.yml`) plus Tuist's
  /// `Tuist.swift` and the `Tuist/` manifest-loader directory are compiled by the build
  /// system, not by any app or library target, so no index store ever records them.
  static func isManifestOrConfig(_ relativePath: String) -> Bool {
    let name = (relativePath as NSString).lastPathComponent
    if LintSourceSet.manifestNames.contains(name) || name == "Tuist.swift" {
      return true
    }
    return relativePath == "Tuist" || relativePath.hasPrefix("Tuist/")
  }

  /// True when the file begins with a `#!` shebang, marking a directly-run script.
  /// Memory-maps the file so only the first page is touched, not the whole source,
  /// since this runs over every owned file.
  static func isShebangScript(_ path: String) -> Bool {
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
      return data.starts(with: shebangPrefix)
    } catch {
      return false
    }
  }

  // MARK: Package-covered set

  /// The Swift sources the package scan covers: every source the root SwiftPM package
  /// describes, plus every owned source under a nested package (a directory with its
  /// own `Package.swift` that is not the repo root). A nested package is built and
  /// linted on its own, so the root describe does not list it and the Xcode index does
  /// not record it; the subtree rule keeps such dev-tool packages from reading as
  /// unscanned without resolving each one.
  static func packageCoveredFiles(context: PathContext, owned: Set<String>) -> Set<String> {
    var covered: Set<String> = []
    if let json = SwiftPM.describePackageJSON() {
      covered.formUnion(packageSourceFiles(json: json))
    }
    let nestedRoots = nestedPackageRoots(context: context)
    if !nestedRoots.isEmpty {
      for file in owned where isUnder(file, anyOf: nestedRoots) {
        covered.insert(file)
      }
    }
    return covered
  }

  /// The absolute `.swift` source paths a `swift package describe --type json` output
  /// names: each target's `sources` joined onto the target `path` and the package
  /// `path`, standardized so they compare against the owned set.
  static func packageSourceFiles(json: String) -> Set<String> {
    let description: PackageDescription
    do {
      description = try JSONDecoder().decode(
        PackageDescription.self, from: DeadcodeScan.jsonData(json))
    } catch {
      Output.error("deadcode: could not parse swift package describe json: \(error)")
      return []
    }
    guard let packagePath = description.path else {
      return []
    }
    var files: Set<String> = []
    for target in description.targets {
      guard let targetPath = target.path, let sources = target.sources else {
        continue
      }
      let targetRoot = (packagePath as NSString).appendingPathComponent(targetPath)
      for source in sources where source.hasSuffix(".swift") {
        let full = (targetRoot as NSString).appendingPathComponent(source)
        files.insert(IndexCompleteness.standardize(full))
      }
    }
    return files
  }

  /// The absolute, standardized directories of nested `Package.swift` manifests, every
  /// manifest the hard-gate source set lists except the one at the repo root.
  static func nestedPackageRoots(context: PathContext) -> [String] {
    var roots: [String] = []
    for path in LintSourceSet.resolve(context: context)
    where (path as NSString).lastPathComponent == "Package.swift" {
      let directory = (path as NSString).deletingLastPathComponent
      if directory.isEmpty || directory == "." {
        continue
      }
      roots.append(IndexCompleteness.standardize(absolute(directory, in: context)))
    }
    return roots
  }

  // MARK: Xcode-covered set

  /// The Swift sources the Xcode index recorded. Empty when no Xcode scan ran (a nil
  /// path); a non-nil path that cannot be read throws, so the caller reports the real
  /// error instead of treating it as unscanned own code.
  static func indexedFiles(_ indexStorePath: String?) throws -> Set<String> {
    guard let indexStorePath else {
      return []
    }
    return try IndexCompleteness.indexedSwiftFiles(indexStorePath: indexStorePath)
  }

  // MARK: Helpers

  /// Resolve a working-directory-relative path against the context's working
  /// directory; an already-absolute path is returned unchanged.
  static func absolute(_ path: String, in context: PathContext) -> String {
    if path.hasPrefix("/") {
      return path
    }
    let base = context.cwd.hasSuffix("/") ? String(context.cwd.dropLast()) : context.cwd
    return base + "/" + path
  }

  /// True when `path` is one of `roots` or sits under one of them.
  static func isUnder(_ path: String, anyOf roots: [String]) -> Bool {
    for root in roots where path == root || path.hasPrefix(root + "/") {
      return true
    }
    return false
  }

  /// The failure message: the count, the first several uncovered paths relative to the
  /// working directory, the full list in a trace-scoped log, and the remediation.
  static func incompleteMessage(missing: [String], context: PathContext) -> String {
    let logPath = BuildFailureLog.write(
      output: missing.joined(separator: "\n"),
      logDirectory: Logging.logDirectory,
      traceID: Logging.correlation.traceID,
      name: "deadcode-coverage-incomplete")
    let shown = missing.prefix(inlineLimit).map { relative($0, in: context) }
    var lines = shown.map { "  " + $0 }
    if missing.count > inlineLimit {
      lines.append("  ... and \(missing.count - inlineLimit) more")
    }
    // Built from named parts so the compiler type-checks each in reasonable time; one
    // long `+` chain with interpolation can exceed the type-check budget on CI.
    let header =
      "lint-deadcode: \(missing.count) owned Swift source(s) are scanned by no "
      + "dead-code scan, so unused code in them is never caught:"
    let body = lines.joined(separator: "\n")
    let fullList = logPath ?? "(log unavailable)"
    let remediation =
      "  Cover each file by adding it to a SwiftPM target, or configure the Xcode "
      + "coverage build by setting SWIFT_XCODE_SCHEME and the matching "
      + "SWIFT_XCODE_WORKSPACE or SWIFT_XCODE_PROJECT. Full list: \(fullList)"
    return [header, body, remediation].joined(separator: "\n")
  }

  /// Display a path relative to the working directory when it sits under it.
  static func relative(_ path: String, in context: PathContext) -> String {
    let base = context.cwd.hasSuffix("/") ? String(context.cwd.dropLast()) : context.cwd
    let resolvedBase = IndexCompleteness.standardize(base)
    if path.hasPrefix(resolvedBase + "/") {
      return String(path.dropFirst(resolvedBase.count + 1))
    }
    return path
  }
}
