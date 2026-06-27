//
//  GeneratedFilesTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - GeneratedFilesTests

/// `GeneratedFiles.render` substitutes `[[KEY]]` placeholders, writes the output
/// creating parent directories, and fails when a template is missing or a value is
/// absent.
enum GeneratedFilesTests {}

@Test
func generatedFilesRenderWritesSubstitutedOutput() throws {
  let manager = FileManager.default
  let dir = NSTemporaryDirectory() + "swiftmk-generate-" + UUID().uuidString
  try manager.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { removeTemporary(dir) }

  let templatePath = dir + "/Project.swift.template"
  try "let bundleId = \"[[BUNDLE_ID]]\"\n".write(
    toFile: templatePath, atomically: true, encoding: .utf8)
  let outputPath = dir + "/Generated/Project.swift"

  let ok = GeneratedFiles.render([
    GeneratedFiles.Plan(
      templatePath: templatePath,
      outputPath: outputPath,
      values: ["BUNDLE_ID": "io.goodkind.celltunnel.agent"])
  ])
  #expect(ok)
  let rendered = try String(contentsOfFile: outputPath, encoding: .utf8)
  #expect(rendered == "let bundleId = \"io.goodkind.celltunnel.agent\"\n")
}

@Test
func generatedFilesRenderFailsOnMissingValue() throws {
  let manager = FileManager.default
  let dir = NSTemporaryDirectory() + "swiftmk-generate-" + UUID().uuidString
  try manager.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { removeTemporary(dir) }

  let templatePath = dir + "/T.template"
  try "[[MISSING]]\n".write(toFile: templatePath, atomically: true, encoding: .utf8)
  let ok = GeneratedFiles.render([
    GeneratedFiles.Plan(templatePath: templatePath, outputPath: dir + "/out", values: [:])
  ])
  #expect(!ok)
}

@Test
func generatedFilesRenderFailsOnMissingTemplate() {
  let ok = GeneratedFiles.render([
    GeneratedFiles.Plan(
      templatePath: "/nonexistent/T.template", outputPath: "/tmp/out", values: [:])
  ])
  #expect(!ok)
}
