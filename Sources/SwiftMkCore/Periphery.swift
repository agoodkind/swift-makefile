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
  static let revision = "e5b4cd24b314467a2b6252f0336c298760d39e80"
  static let releaseTag = "3.8.0-agoodkind.6"
  static let assetName = "periphery-3.8.0-agoodkind.6-macos-arm64.zip"
  static let assetSHA256 = "7e08e9cea2aa7abf71a2813b129ea84f6e5bd161ab5f22a52745e909f739ddfb"
  static let binarySHA256 = "e8dcc97a0b3f358ebeb477e4c10e7c87bf6c7dbe00fafa9384d2e2b63aa26c69"
  private static let expectedVersion = "3.8.0-agoodkind.6"

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

  private static func supportsPinnedRelease() -> Bool {
    #if os(macOS)
      var arm64 = Int32(0)
      var size = MemoryLayout<Int32>.size
      return sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
    #else
      return false
    #endif
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
    guard supportsPinnedRelease() else {
      Output.error("periphery: \(releaseTag) supports arm64 macOS only")
      return nil
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
    let extractedDirectory = "\(stage)/periphery-\(releaseTag)"
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
    let stagedBinary = "\(extractedDirectory)/periphery"
    guard verifyBinary(stagedBinary) else { return nil }

    do {
      try manager.removeItem(atPath: archive)
      try manager.moveItem(atPath: extractedDirectory, toPath: cacheDirectory())
    } catch {
      Output.error("periphery: could not publish cache entry: \(error)")
      return nil
    }
    return useBinary(outputPath())
  }
}
