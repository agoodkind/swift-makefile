//
//  PackageResolvedStabilityTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-13.
//  Copyright © 2026, all rights reserved.
//

#if os(macOS)

  import Foundation
  import Testing

  @testable import SwiftMkCore

  // MARK: - PackageResolvedStabilityTests

  enum PackageResolvedStabilityTests {}

  private struct ResolvedPackageFile: Decodable {
    struct Pin: Decodable {
      let identity: String
    }

    let pins: [Pin]
  }

  private func pinIdentities(at resolvedURL: URL) throws -> [String] {
    let data = try Data(contentsOf: resolvedURL)
    let decoded = try JSONDecoder().decode(ResolvedPackageFile.self, from: data)
    return decoded.pins.map(\.identity).sorted()
  }

  @Test
  func packageResolveKeepsLockfilePinIdentities() throws {
    let root = URL(fileURLWithPath: BootstrapHelperRunner.repositoryRoot(), isDirectory: true)
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("swift-mk-lock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { removeTemporary(temp.path) }

    for name in ["Package.swift", "Package.resolved"] {
      try FileManager.default.copyItem(
        at: root.appendingPathComponent(name),
        to: temp.appendingPathComponent(name))
    }

    let resolvedURL = temp.appendingPathComponent("Package.resolved")
    let before = try pinIdentities(at: resolvedURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = ["package", "resolve"]
    process.currentDirectoryURL = temp
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = Output.decodeCapturedUTF8(pipe.fileHandleForReading.readDataToEndOfFile())
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "swift package resolve failed: \(output)")

    let after = try pinIdentities(at: resolvedURL)
    #expect(before == after)
  }

#endif
