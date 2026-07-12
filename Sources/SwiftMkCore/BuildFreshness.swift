//
//  BuildFreshness.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-11.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - BuildFreshness

/// Records the last successful build and decides whether a rebuild is needed, so
/// `make build` can no-op when the tracked inputs and the built product are
/// unchanged.
///
/// The record lives at `.make/.build/last-success` as fixed-order `key=value`
/// text, mirroring `GateProof.Stamp`. Freshness layers four checks, cheapest
/// first: the caller's opaque config key, the exact set of product paths, that
/// every product still exists on disk, then a source-change digest.
///
/// The digest is two-tier on purpose. The mtime digest (`GateProof.sourceDigest`)
/// is a fast path that stats files without reading them, so an untouched tree is
/// judged fresh with no I/O over file bodies. When mtimes have churned but the
/// bytes are identical (a checkout, a touch, a no-op formatter pass), the mtime
/// digest differs, so a second content digest reads the bytes and still reports
/// fresh. This makes the check immune to mtime churn while staying fast in the
/// common untouched case.
public enum BuildFreshness {
  /// The record path relative to the repo root.
  static let recordRelativeComponents = [".make", ".build", "last-success"]

  // MARK: Producer

  /// Write the success record after a build completes, capturing the current
  /// mtime and content digests, the caller's config key, and the product paths.
  /// Creates `.make/.build` as needed. A write failure is reported but not
  /// raised, since a missing record only forces the next build to run.
  public static func record(context: PathContext, configKey: String, productPaths: [String]) {
    let record = Record(
      mtimeDigest: GateProof.sourceDigest(context: context),
      contentDigest: contentDigest(context: context),
      configKey: configKey,
      productPaths: productPaths)
    let url = recordURL(context: context)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try record.serialized().write(to: url, atomically: true, encoding: .utf8)
    } catch {
      Output.error("build-freshness: could not write record at \(url.path): \(error)")
    }
  }

  // MARK: Verifier

  /// Whether the last recorded build still covers the current inputs and outputs,
  /// so the build can be skipped. Any of these makes it stale, checked cheapest
  /// first: a missing or unparseable record, a different config key, a different
  /// set of product paths, a product that no longer exists, or a changed source
  /// set. The source check tries the mtime digest first (no file bodies read) and
  /// falls back to the content digest only when mtimes differ, so an mtime-only
  /// churn with identical bytes is still fresh.
  public static func isFresh(context: PathContext, configKey: String, productPaths: [String])
    -> Bool
  {
    guard let record = readRecord(context: context) else {
      return false
    }
    guard record.configKey == configKey else {
      return false
    }
    guard Set(record.productPaths) == Set(productPaths) else {
      return false
    }
    let manager = FileManager.default
    for path in productPaths {
      guard manager.fileExists(atPath: path) else {
        return false
      }
    }
    if GateProof.sourceDigest(context: context) == record.mtimeDigest {
      return true
    }
    return contentDigest(context: context) == record.contentDigest
  }

  // MARK: Content digest

  /// Radix for the per-file size in a content-digest entry, so a size renders as
  /// compact lowercase hex rather than decimal.
  static let hexadecimalRadix = 16

  /// A stable digest of the tracked source set bound to file contents rather than
  /// mtime, over the same file set and exclusions as `GateProof.sourceDigest`.
  /// Streams each file through a per-file content hash and folds the sorted
  /// `path\u{0}sizeHex\u{0}contentHex` entries, so no file is fully resident and
  /// the whole set never loads at once. Returns the same "empty" sentinel as
  /// `sourceDigest` when the tree cannot be enumerated, so the two digests agree
  /// on that boundary.
  static func contentDigest(context: PathContext) -> String {
    var entries: [String] = []
    let started = GateProof.forEachTrackedSource(context: context) { relative, url in
      var size = 0
      do {
        size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      } catch {
        // A file that cannot be stat'd contributes a zero size; its content hash
        // below still binds the entry, so the digest stays a change signal.
        Output.warning("build-freshness: could not stat \(url.path) for size: \(error)")
      }
      let sizeHex = String(size, radix: hexadecimalRadix)
      let contentHex = GateProof.fnv1aHexOfFile(at: url)
      entries.append("\(relative)\u{0}\(sizeHex)\u{0}\(contentHex)")
    }
    guard started else {
      return "empty"
    }
    entries.sort()
    return GateProof.fnv1aHex(entries.joined(separator: "\n"))
  }

  // MARK: Record model

  struct Record: Equatable {
    let mtimeDigest: String
    let contentDigest: String
    let configKey: String
    let productPaths: [String]

    /// Serialize as fixed-order `key=value` text, one pair per line, with the
    /// product paths as repeated `product=` lines so any count round-trips.
    func serialized() -> String {
      var lines: [String] = [
        "mtimeDigest=\(mtimeDigest)",
        "contentDigest=\(contentDigest)",
        "configKey=\(configKey)",
      ]
      for path in productPaths {
        lines.append("product=\(path)")
      }
      return lines.joined(separator: "\n") + "\n"
    }

    /// Parse the serialized form. Returns nil when a required digest or the config
    /// key is missing, so a truncated or tampered record forces a rebuild rather
    /// than a false-fresh skip. Every `product=` line is collected in order; the
    /// config key value may be empty and is compared verbatim.
    static func parse(_ text: String) -> Record? {
      var single: [String: String] = [:]
      var products: [String] = []
      for line in text.split(separator: "\n") {
        guard let equals = line.firstIndex(of: "=") else {
          continue
        }
        let key = String(line[..<equals])
        let value = String(line[line.index(after: equals)...])
        if key == "product" {
          products.append(value)
        } else {
          single[key] = value
        }
      }
      guard let mtime = single["mtimeDigest"], !mtime.isEmpty,
        let content = single["contentDigest"], !content.isEmpty,
        let config = single["configKey"]
      else {
        return nil
      }
      return Record(
        mtimeDigest: mtime,
        contentDigest: content,
        configKey: config,
        productPaths: products)
    }
  }

  static func recordURL(context: PathContext) -> URL {
    var url = URL(fileURLWithPath: context.cwd, isDirectory: true)
    for component in recordRelativeComponents {
      url = url.appendingPathComponent(component)
    }
    return url
  }

  static func readRecord(context: PathContext) -> Record? {
    let url = recordURL(context: context)
    let text: String
    do {
      text = try String(contentsOf: url, encoding: .utf8)
    } catch {
      // A missing or unreadable record means no proof of a prior build, so the
      // caller rebuilds. This is the common first-build case, not an error.
      return nil
    }
    return Record.parse(text)
  }
}
