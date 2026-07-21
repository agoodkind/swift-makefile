//
//  GeneratedFiles.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkRenderCore

// MARK: - GeneratedFiles

/// Render a consumer's project-generation templates in-process, so the decoupled
/// build path produces the generated Swift (a rendered manifest, a config file)
/// before discovery without a `make xcconfig-generate-project` step.
///
/// The make path renders templates through the `swift-mk-render` CLI; this is the
/// library entry a dev tool's `generateProject` calls instead, after which it runs
/// `Toolchain.generate(.tuist)`. Generation must run before `LintSourceSet.resolve`
/// so the generated sources exist when discovery walks the tree.
public enum GeneratedFiles {
  /// One template render: the template to read, the file to write, and the values
  /// substituted into the template's `[[KEY]]` placeholders.
  public struct Plan: Sendable {
    public let templatePath: String
    public let outputPath: String
    public let values: [String: String]

    public init(templatePath: String, outputPath: String, values: [String: String]) {
      self.templatePath = templatePath
      self.outputPath = outputPath
      self.values = values
    }
  }

  /// Render each plan and write its output, creating parent directories as needed.
  /// Returns true only when every plan rendered and wrote; a read, render, or
  /// write failure is reported and makes the call return false, so a consumer's
  /// `generateProject` can fail loud before it runs the generator on a partial
  /// render.
  @discardableResult
  public static func render(_ plans: [Plan]) -> Bool {
    var allRendered = true
    for plan in plans where !render(plan) {
      allRendered = false
    }
    return allRendered
  }

  private static func render(_ plan: Plan) -> Bool {
    let templateText: String
    do {
      templateText = try String(contentsOfFile: plan.templatePath, encoding: .utf8)
    } catch {
      Output.error("generate: could not read template \(plan.templatePath): \(error)")
      return false
    }
    let rendered: String
    do {
      rendered = try TemplateRenderer.render(templateText: templateText, values: plan.values)
    } catch {
      Output.error("generate: could not render \(plan.templatePath): \(error)")
      return false
    }
    let outputURL = URL(fileURLWithPath: plan.outputPath)
    let wrote: Bool
    do {
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      // Write only when the rendered content differs, so a re-render of unchanged
      // inputs does not churn the file's mtime and force a downstream recompile.
      wrote = try Text.writeIfChanged(rendered, toFile: plan.outputPath)
    } catch {
      Output.error("generate: could not write \(plan.outputPath): \(error)")
      return false
    }
    if wrote {
      Output.info("generate: rendered \(plan.outputPath)")
    } else {
      Output.debug("generate: unchanged \(plan.outputPath)")
    }
    return true
  }
}
