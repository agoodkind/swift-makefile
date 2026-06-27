//
//  LintResources.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - LintResources

/// The gate configuration files swift-mk owns, shipped as SwiftPM resources and
/// materialized into a checkout on demand.
///
/// The make path lands these in `.make/` (and the mise file under
/// `.config/mise/conf.d/`) through `swift.mk`'s fetch. The decoupled in-process
/// API has no make to fetch them, so it writes the same bundled bytes itself,
/// which also makes a fresh checkout that has never run `make` work. Shipping the
/// configs as engine-owned resources is what makes CI, make, and the API converge
/// on byte-identical configs rather than each carrying its own copy.
public enum LintResources {
  /// One shipped config: the bundle resource that carries it and the
  /// checkout-relative path it is written to.
  struct Resource {
    let resourceName: String
    let resourceExtension: String
    let destinationComponents: [String]
  }

  /// Every shipped gate config and where it lands in a checkout. The destinations
  /// mirror the `swift.mk` fetch targets exactly (`.make/swiftlint.yml`,
  /// `.make/swift-format.json`, `.make/periphery.yml`, `.make/osv-scanner.toml`,
  /// and the additive mise location), so the in-process path produces the same
  /// files the make path does.
  static let resources: [Resource] = [
    Resource(
      resourceName: "swiftlint",
      resourceExtension: "yml",
      destinationComponents: [".make", "swiftlint.yml"]),
    Resource(
      resourceName: "swift-format",
      resourceExtension: "json",
      destinationComponents: [".make", "swift-format.json"]),
    Resource(
      resourceName: "periphery",
      resourceExtension: "yml",
      destinationComponents: [".make", "periphery.yml"]),
    Resource(
      resourceName: "osv-scanner",
      resourceExtension: "toml",
      destinationComponents: [".make", "osv-scanner.toml"]),
    Resource(
      resourceName: "mise",
      resourceExtension: "toml",
      destinationComponents: [".config", "mise", "conf.d", "swift-mk.toml"]),
  ]

  // MARK: Bundled bytes

  /// The bundled bytes of a shipped config, or nil when the resource is missing
  /// from the bundle. Exposed so the drift test can compare them to the repo's
  /// root config files.
  public static func bundledData(resourceName: String, resourceExtension: String) -> Data? {
    guard
      let url = Bundle.module.url(
        forResource: resourceName, withExtension: resourceExtension)
    else {
      return nil
    }
    do {
      return try Data(contentsOf: url)
    } catch {
      Output.error(
        "lint-resources: could not read bundled \(resourceName).\(resourceExtension): \(error)")
      return nil
    }
  }

  // MARK: Materialize

  /// Write every shipped config into the checkout rooted at `context.cwd` when it
  /// is missing or its bytes differ from the bundled copy, so a stale local file
  /// is replaced with the engine-owned version. Best-effort per file: a write
  /// failure is reported and skipped rather than aborting the rest, so one
  /// unwritable path does not block the others. Returns true when every shipped
  /// config is present and current after the call.
  @discardableResult
  public static func ensure(context: PathContext = .current()) -> Bool {
    let root = URL(fileURLWithPath: context.cwd, isDirectory: true)
    var allPresent = true
    for resource in resources {
      guard
        let data = bundledData(
          resourceName: resource.resourceName,
          resourceExtension: resource.resourceExtension)
      else {
        Output.error(
          "lint-resources: bundled \(resource.resourceName).\(resource.resourceExtension) "
            + "is unavailable")
        allPresent = false
        continue
      }
      var destination = root
      for component in resource.destinationComponents {
        destination = destination.appendingPathComponent(component)
      }
      if !writeIfChanged(data, to: destination) {
        allPresent = false
      }
    }
    return allPresent
  }

  /// Write `data` to `destination` only when the file is absent or its bytes
  /// differ, so an unchanged config is not rewritten on every run. Returns true
  /// when the file holds the bundled bytes after the call.
  private static func writeIfChanged(_ data: Data, to destination: URL) -> Bool {
    if existingData(at: destination) == data {
      return true
    }
    let directory = destination.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      try data.write(to: destination, options: .atomic)
      return true
    } catch {
      Output.error(
        "lint-resources: could not write \(destination.path): \(error)")
      return false
    }
  }

  /// The bytes already at `destination`, or nil when the file is absent or
  /// unreadable, so a fresh checkout simply gets the bundled copy written.
  private static func existingData(at destination: URL) -> Data? {
    do {
      return try Data(contentsOf: destination)
    } catch {
      return nil
    }
  }
}
