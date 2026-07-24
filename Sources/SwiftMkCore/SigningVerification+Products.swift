//
//  SigningVerification+Products.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-24.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Products (post-build, discover and verify runnable apps)

extension SigningVerification {
  /// Directory names never descended during product discovery: intermediate and
  /// derived build output that holds no shippable product but many nested bundles.
  static let productDiscoverySkipDirectories: Set<String> = [
    "Intermediates.noindex", "DerivedData", ".build", "SourcePackages", "checkouts",
  ]

  /// Bound on discovery recursion so a deep or cyclic tree cannot hang the walk.
  /// Xcode drops products at `Products/<config><platform>/Name.app`, well within
  /// this depth.
  static let productDiscoveryMaxDepth = 5

  /// Xcode configuration-build-directory suffixes for the simulator platforms.
  /// A product under a directory named `<config>-iphonesimulator` and the like is
  /// signed ad-hoc by design and is not a shippable product.
  static let simulatorProductSuffixes = [
    "-iphonesimulator", "-appletvsimulator", "-watchsimulator", "-xrsimulator",
  ]

  /// Discover the runnable `.app` bundles under each root and verify each is a
  /// correctly signed runnable product. For each non-simulator app a strict
  /// `codesign --verify --deep` validates the whole bundle including its embedded
  /// extensions and frameworks, and a `codesign` display check confirms the team
  /// and rejects an ad-hoc signature. The signing identity itself is enforced
  /// before the build by `verifySettings`, whose `XCODE_XCCONFIG_FILE` override
  /// applies to every target, so every product carries the verified identity and is
  /// not re-checked per product here. Simulator products are ad-hoc by design and
  /// do not ship, so they are logged and skipped. Fails when signing is expected but
  /// no signed runnable product is found, or when a declared directory is missing or
  /// unreadable.
  @discardableResult
  public static func verifyProducts(
    roots: [String], localXcconfigPaths: [String] = []
  ) -> Bool {
    let expected = SigningBuildConfig.resolvedInputs(localXcconfigPaths: localXcconfigPaths)
    let identity = expected.identity.trimmingCharacters(in: .whitespaces)
    let team = expected.team.trimmingCharacters(in: .whitespaces)
    if identity.isEmpty, team.isEmpty {
      Output.info("verify-signing: no signing values set; skipping product check")
      return true
    }
    let expectAdHoc = identity == adHocIdentity
    let discovered = discoverProducts(under: roots)
    var allPass = true
    for directory in discovered.unreadable {
      // A product directory that cannot be read may hide a product that should be
      // verified, so a build claiming these roots must not pass while one is
      // missing or unreadable.
      Output.error("verify-signing: product directory \(directory) is missing or unreadable")
      allPass = false
    }
    var verifiedRunnable = 0
    for app in discovered.apps {
      if isSimulatorProduct(path: app) {
        Output.info(
          "verify-signing: \(app) is a simulator product (ad-hoc by design); skipping")
        continue
      }
      verifiedRunnable += 1
      if !verifyRunnableApp(path: app, expectAdHoc: expectAdHoc, expectedTeam: team) {
        allPass = false
      }
    }
    if verifiedRunnable == 0 {
      Output.error(
        "verify-signing: no signed runnable .app found under "
          + "\(roots.joined(separator: ", ")); expected at least one signed product")
      return false
    }
    return allPass
  }

  /// Strictly verify one runnable app, then confirm its team and reject ad-hoc. The
  /// `--deep` pass recurses into nested code, so a broken embedded extension or
  /// framework fails here even when the top-level signature reads correctly.
  private static func verifyRunnableApp(
    path: String, expectAdHoc: Bool, expectedTeam: String
  ) -> Bool {
    Output.info("verify-signing: strict codesign \(path)")
    let strict = Shell.run("codesign", ["--verify", "--deep", "--strict", "--verbose=2", path])
    if strict.status != 0 {
      Output.error("verify-signing: strict verification failed for \(path)")
      Output.emitStandardError(strict.combined)
      return false
    }
    let display = Shell.run("codesign", ["-dvvv", path])
    let teamOk = artifactSignatureSatisfies(
      output: display.combined,
      status: display.status,
      expectAdHoc: expectAdHoc,
      expectedTeam: expectedTeam)
    if !teamOk {
      let teamValue = firstValue(in: display.combined, prefix: "TeamIdentifier=")
      Output.error(
        "verify-signing: \(path) failed; status=\(display.status) "
          + "TeamIdentifier=\(teamValue ?? "not set") expectedTeam=\(expectedTeam)")
      return false
    }
    return true
  }

  /// Every top-level `.app` bundle under the roots, sorted and de-duplicated. The
  /// walk records an `.app` without descending into it, so a nested helper `.app`
  /// inside another app is not returned, and skips build-output directories that
  /// hold no shippable product.
  static func discoverAppBundles(under roots: [String]) -> [String] {
    discoverProducts(under: roots).apps
  }

  /// The runnable `.app` bundles under the roots plus every directory that could not
  /// be read. The apps are the top-level bundles the walk records without descending
  /// into them; the unreadable list lets the caller fail rather than silently miss
  /// products under a directory it could not open, including a missing root.
  static func discoverProducts(
    under roots: [String]
  ) -> (apps: [String], unreadable: [String]) {
    var found: Set<String> = []
    var unreadable: Set<String> = []
    for root in roots {
      collectAppBundles(in: root, depth: 0, into: &found, unreadable: &unreadable)
    }
    return (found.sorted(), unreadable.sorted())
  }

  private static func collectAppBundles(
    in directory: String,
    depth: Int,
    into found: inout Set<String>,
    unreadable: inout Set<String>
  ) {
    guard depth <= productDiscoveryMaxDepth else {
      return
    }
    let fileManager = FileManager.default
    let entries: [String]
    do {
      entries = try fileManager.contentsOfDirectory(atPath: directory)
    } catch {
      // Record the directory so verifyProducts fails: a missing or unreadable
      // directory could hide a product that should have been verified.
      Output.warning("verify-signing: could not read directory \(directory)")
      unreadable.insert(directory)
      return
    }
    for entry in entries {
      let path = (directory as NSString).appendingPathComponent(entry)
      var isDirectory: ObjCBool = false
      guard
        fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
      else {
        continue
      }
      if entry.hasSuffix(".app") {
        found.insert(path)
        continue
      }
      if productDiscoverySkipDirectories.contains(entry) {
        continue
      }
      collectAppBundles(in: path, depth: depth + 1, into: &found, unreadable: &unreadable)
    }
  }

  /// Whether a discovered product sits in a simulator configuration-build
  /// directory, so it is skipped from the real-identity assertion. Only the app's
  /// immediate enclosing directory is examined, which is the Xcode
  /// `<configuration><platform>` product directory, so an unrelated ancestor
  /// directory that happens to end in a simulator suffix does not misclassify a
  /// device, Mac, or Catalyst app. Pure string logic so it is unit-tested.
  static func isSimulatorProduct(path: String) -> Bool {
    let configurationDirectory =
      ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    return simulatorProductSuffixes.contains { configurationDirectory.hasSuffix($0) }
  }
}
