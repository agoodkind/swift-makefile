//
//  Periphery.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-15.
//  Copyright © 2026, all rights reserved.
//

import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

// MARK: - Periphery

/// Resolves the pinned free, offline Periphery fork into the shared engine cache.
enum Periphery {
  static let repository = "agoodkind/periphery"
  static let revision = "fbf5d84ce1383e6afa05c35dd9a76be7a26b48d8"
  static let releaseTag = "3.8.0-agoodkind.1"
  static let assetName = "periphery-3.8.0.zip"
  static let assetSHA256 = "07d4e286e31dd79164df39097e0b59f533c94badbe18158464a455ea88a166d7"
  static let binarySHA256 = "043b2c2ff7589b87f2b30c6c9b91e8d9b8e5c6c3cd03d2e3395960e00d53e9b5"
  private static let expectedVersion = "3.8.0"

  static func cacheBaseDirectory() -> String {
    let home = Env.get("HOME", FileManager.default.homeDirectoryForCurrentUser.path)
    let cacheRoot = Env.get("SWIFT_MK_CACHE_ROOT", "\(home)/Library/Caches/swift-mk")
    return "\(cacheRoot)/Periphery"
  }

  private static func cacheDirectory() -> String {
    "\(cacheBaseDirectory())/\(releaseTag)"
  }

  private static func outputPath() -> String {
    "\(cacheDirectory())/periphery"
  }

  private static func configuredBin() -> String? {
    let configured = Env.get("PERIPHERY")
    if configured.isEmpty || configured == "periphery" {
      return nil
    }
    return configured
  }

  private static func sha256(_ path: String) -> String? {
    let result = Shell.run("shasum", ["-a", "256", path])
    guard result.status == 0 else {
      Output.error("periphery: checksum failed: \(result.combined)")
      return nil
    }
    return result.stdout.split(whereSeparator: \.isWhitespace).first.map(String.init)
  }

  private static func verifyBinary(_ path: String) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: path) else {
      Output.error("periphery: cached binary is not executable at \(path)")
      return false
    }
    guard let actual = sha256(path), actual.caseInsensitiveCompare(binarySHA256) == .orderedSame
    else {
      Output.error("periphery: binary checksum mismatch at \(path)")
      return false
    }
    let version = Shell.run(path, ["version"])
    guard version.status == 0,
      version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expectedVersion
    else {
      Output.error("periphery: version probe failed for \(path): \(version.combined)")
      return false
    }
    return true
  }

  private static func useBinary(_ path: String) -> String? {
    guard verifyBinary(path) else { return nil }
    setenv("PERIPHERY", path, 1)
    return path
  }

  static func preparedBin() -> String? {
    if let configured = configuredBin() {
      guard FileManager.default.isExecutableFile(atPath: configured) else {
        Output.error("periphery: PERIPHERY is not executable at \(configured)")
        return nil
      }
      return configured
    }

    let output = outputPath()
    if FileManager.default.fileExists(atPath: cacheDirectory()) {
      return useBinary(output)
    }
    return fetchAndPrepare()
  }

  @discardableResult
  static func resolveBin() -> Bool {
    preparedBin() != nil
  }

  private static func fetchAndPrepare() -> String? {
    let manager = FileManager.default
    let base = cacheBaseDirectory()
    let stage = "\(base)/.\(releaseTag).\(UUID().uuidString)"
    let archive = "\(stage)/\(assetName)"
    let url =
      "https://github.com/\(repository)/releases/download/\(releaseTag)/\(assetName)"

    do {
      try manager.createDirectory(atPath: stage, withIntermediateDirectories: true)
    } catch {
      Output.error("periphery: could not create cache stage \(stage): \(error)")
      return nil
    }
    defer {
      if manager.fileExists(atPath: stage) {
        do {
          try manager.removeItem(atPath: stage)
        } catch {
          Output.error("periphery: could not remove cache stage \(stage): \(error)")
        }
      }
    }

    Output.info("periphery: fetching \(repository)@\(revision)")
    let download = Shell.run(
      "curl", ["-fL", "--connect-timeout", "10", "--max-time", "120", "-o", archive, url])
    guard download.status == 0 else {
      Output.error("periphery: fetch failed: \(download.combined)")
      return nil
    }
    guard let actual = sha256(archive),
      actual.caseInsensitiveCompare(assetSHA256) == .orderedSame
    else {
      Output.error("periphery: asset checksum mismatch for \(assetName)")
      return nil
    }

    let extract = Shell.run("ditto", ["-x", "-k", archive, stage])
    guard extract.status == 0 else {
      Output.error("periphery: extraction failed: \(extract.combined)")
      return nil
    }
    let stagedBinary = "\(stage)/periphery"
    guard verifyBinary(stagedBinary) else { return nil }

    do {
      try manager.moveItem(atPath: stage, toPath: cacheDirectory())
    } catch {
      Output.error("periphery: could not publish cache entry: \(error)")
      return nil
    }
    return useBinary(outputPath())
  }
}
