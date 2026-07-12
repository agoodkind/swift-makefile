//
//  BuildFreshnessTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-11.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BuildFreshnessTests

enum BuildFreshnessTests {}

// MARK: freshness decisions

@Test
func freshWhenNothingChanged() {
  let context = makeFreshnessTree(files: ["Sources/App/Main.swift": "let a = 1\n"])
  defer { removeFreshnessTree(context) }
  let product = makeProduct(context, name: "App")
  BuildFreshness.record(context: context, configKey: "cfg", productPaths: [product])
  #expect(BuildFreshness.isFresh(context: context, configKey: "cfg", productPaths: [product]))
}

@Test
func staleWhenSourceContentChanges() {
  let context = makeFreshnessTree(files: ["Sources/App/Main.swift": "let a = 1\n"])
  defer { removeFreshnessTree(context) }
  let product = makeProduct(context, name: "App")
  BuildFreshness.record(context: context, configKey: "cfg", productPaths: [product])
  writeFile(context, relative: "Sources/App/Main.swift", body: "let a = 2\n")
  #expect(!BuildFreshness.isFresh(context: context, configKey: "cfg", productPaths: [product]))
}

@Test
func freshWhenOnlyMtimeChurns() {
  let context = makeFreshnessTree(files: ["Sources/App/Main.swift": "let a = 1\n"])
  defer { removeFreshnessTree(context) }
  let product = makeProduct(context, name: "App")
  BuildFreshness.record(context: context, configKey: "cfg", productPaths: [product])
  // Push the modification date forward without changing the bytes, so the mtime
  // digest differs but the content digest still matches. The content fallback
  // must judge this fresh.
  touchForward(context, relative: "Sources/App/Main.swift")
  #expect(BuildFreshness.isFresh(context: context, configKey: "cfg", productPaths: [product]))
}

@Test
func staleWhenProductMissing() {
  let context = makeFreshnessTree(files: ["Sources/App/Main.swift": "let a = 1\n"])
  defer { removeFreshnessTree(context) }
  let product = makeProduct(context, name: "App")
  BuildFreshness.record(context: context, configKey: "cfg", productPaths: [product])
  removeFile(product)
  #expect(!BuildFreshness.isFresh(context: context, configKey: "cfg", productPaths: [product]))
}

@Test
func staleWhenConfigKeyChanges() {
  let context = makeFreshnessTree(files: ["Sources/App/Main.swift": "let a = 1\n"])
  defer { removeFreshnessTree(context) }
  let product = makeProduct(context, name: "App")
  BuildFreshness.record(context: context, configKey: "A", productPaths: [product])
  #expect(!BuildFreshness.isFresh(context: context, configKey: "B", productPaths: [product]))
}

@Test
func staleWhenProductSetChanges() {
  let context = makeFreshnessTree(files: ["Sources/App/Main.swift": "let a = 1\n"])
  defer { removeFreshnessTree(context) }
  let product = makeProduct(context, name: "App")
  let extra = makeProduct(context, name: "Helper")
  BuildFreshness.record(context: context, configKey: "cfg", productPaths: [product])
  #expect(
    !BuildFreshness.isFresh(context: context, configKey: "cfg", productPaths: [product, extra]))
}

@Test
func staleWhenNoRecordExists() {
  let context = makeFreshnessTree(files: ["Sources/App/Main.swift": "let a = 1\n"])
  defer { removeFreshnessTree(context) }
  let product = makeProduct(context, name: "App")
  #expect(!BuildFreshness.isFresh(context: context, configKey: "cfg", productPaths: [product]))
}

// MARK: record model

@Test
func recordRoundTripsWithMultipleProducts() {
  let record = BuildFreshness.Record(
    mtimeDigest: "aaaa",
    contentDigest: "bbbb",
    configKey: "cfg",
    productPaths: ["/one", "/two"])
  #expect(BuildFreshness.Record.parse(record.serialized()) == record)
}

@Test
func recordParseRejectsMissingDigest() {
  // contentDigest is absent, so the record cannot prove a prior build.
  let text = "mtimeDigest=aaaa\nconfigKey=cfg\nproduct=/one\n"
  #expect(BuildFreshness.Record.parse(text) == nil)
}

// MARK: helpers

private func makeFreshnessTree(files: [String: String]) -> PathContext {
  let root = NSTemporaryDirectory() + "build-freshness-" + UUID().uuidString + "/"
  let context = PathContext(pwd: root, cwd: root)
  do {
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  } catch {
    Output.error("test: could not create freshness tree root: \(error)")
  }
  for (relative, body) in files {
    writeFile(context, relative: relative, body: body)
  }
  return context
}

private func writeFile(_ context: PathContext, relative: String, body: String) {
  let url = URL(fileURLWithPath: context.cwd).appendingPathComponent(relative)
  do {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try body.write(to: url, atomically: true, encoding: .utf8)
  } catch {
    Output.error("test: could not write \(relative): \(error)")
  }
}

/// Create a product file under the repo root and return its absolute path, so a
/// freshness check can assert its existence.
private func makeProduct(_ context: PathContext, name: String) -> String {
  let url = URL(fileURLWithPath: context.cwd)
    .appendingPathComponent(".build/products/\(name)")
  do {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "product\n".write(to: url, atomically: true, encoding: .utf8)
  } catch {
    Output.error("test: could not write product \(name): \(error)")
  }
  return url.path
}

/// How far forward a churn test pushes a file's modification date. One hour is
/// far past any filesystem mtime resolution, so the mtime digest is guaranteed to
/// differ while the bytes stay identical.
private let mtimeChurnSeconds: TimeInterval = 3_600

private func touchForward(_ context: PathContext, relative: String) {
  let url = URL(fileURLWithPath: context.cwd).appendingPathComponent(relative)
  let future = Date().addingTimeInterval(mtimeChurnSeconds)
  do {
    try FileManager.default.setAttributes(
      [.modificationDate: future], ofItemAtPath: url.path)
  } catch {
    Output.error("test: could not touch \(relative): \(error)")
  }
}

private func removeFile(_ path: String) {
  do {
    try FileManager.default.removeItem(atPath: path)
  } catch {
    Output.error("test: could not remove \(path): \(error)")
  }
}

private func removeFreshnessTree(_ context: PathContext) {
  do {
    try FileManager.default.removeItem(atPath: context.cwd)
  } catch {
    Output.error("test: freshness tree cleanup failed: \(error)")
  }
}
