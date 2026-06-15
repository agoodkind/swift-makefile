//
//  GateProofTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-14.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - GateProofTests

enum GateProofTests {}

// MARK: digest

@Test
func fnv1aHexIsDeterministic() {
  let first = GateProof.fnv1aHex("hello")
  let second = GateProof.fnv1aHex("hello")
  #expect(first == second)
}

@Test
func fnv1aHexSeparatesDistinctInput() {
  #expect(GateProof.fnv1aHex("a") != GateProof.fnv1aHex("b"))
}

@Test
func fnv1aHexEmptyIsOffsetBasis() {
  // The FNV-1a empty digest is the offset basis, a fixed value.
  #expect(GateProof.fnv1aHex("") == "cbf29ce484222325")
}

@Test
func sourceDigestIsDeterministicForUnchangedTree() {
  let context = makeTemporarySourceTree(files: ["A.swift": "let a = 1\n"])
  defer { removeTree(context) }
  let first = GateProof.sourceDigest(context: context)
  let second = GateProof.sourceDigest(context: context)
  #expect(first == second)
}

@Test
func sourceDigestChangesWhenASourceIsAdded() {
  let context = makeTemporarySourceTree(files: ["A.swift": "let a = 1\n"])
  defer { removeTree(context) }
  let before = GateProof.sourceDigest(context: context)
  let added = URL(fileURLWithPath: context.cwd).appendingPathComponent("B.swift")
  do {
    try "let b = 2\n".write(to: added, atomically: true, encoding: .utf8)
  } catch {
    Output.error("test: could not write added source: \(error)")
  }
  #expect(GateProof.sourceDigest(context: context) != before)
}

// MARK: stamp

@Test
func stampRoundTripsThroughSerialization() {
  let stamp = GateProof.Stamp(
    nonce: "abc123",
    sourceHash: "deadbeef",
    gatePid: 999,
    gateStartTime: 100.5,
    createdAt: 200.25)
  #expect(GateProof.Stamp.parse(stamp.serialized()) == stamp)
}

@Test
func stampParseRejectsMissingField() {
  // gatePid is missing, so the stamp cannot authorize.
  let text = "nonce=x\nsourceHash=y\ngateStartTime=1.0\ncreatedAt=2.0\n"
  #expect(GateProof.Stamp.parse(text) == nil)
}

@Test
func stampParseRejectsGarbage() {
  #expect(GateProof.Stamp.parse("not a stamp at all") == nil)
}

// MARK: ancestry and verdict

@Test
func ancestorPidsIncludesThisProcess() {
  let chain = GateProof.ancestorPids()
  #expect(chain.contains(getpid()))
  #expect(!chain.isEmpty)
}

@Test
func isGatedFalseWithoutStamp() {
  let context = emptyContext()
  #expect(!GateProof.isGated(context: context))
}

@Test
func probeReportNamesMissingStamp() {
  let context = emptyContext()
  #expect(GateProof.probeReport(context: context) == "gated=false reason=no-stamp")
}

@Test
func refusalReturnsStatusWithoutStamp() {
  let context = emptyContext()
  let status = GateProof.refusal(entry: "test", context: context)
  #expect(status == GateProof.refusedExitStatus)
}

@Test
func helperBuildAcceptsFreshStampWithoutLiveAncestor() {
  // A secondary/helper build (a Metal compile, an install/deploy step) runs after
  // the gated build process exits. A fresh stamp with a now-dead gate pid must
  // pass the lenient check but fail the strict product-leaf check.
  let context = makeTemporarySourceTree(files: [:])
  defer { removeTree(context) }
  let stamp = GateProof.Stamp(
    nonce: "n",
    sourceHash: "h",
    gatePid: 999_999,
    gateStartTime: 0,
    createdAt: Date().timeIntervalSince1970)
  writeStamp(stamp, to: context)
  #expect(GateProof.isGated(context: context, requireLiveAncestor: false))
  #expect(!GateProof.isGated(context: context, requireLiveAncestor: true))
}

@Test
func helperBuildStillRefusedWithoutAnyStamp() {
  let context = emptyContext()
  #expect(!GateProof.isGated(context: context, requireLiveAncestor: false))
}

// MARK: helpers

private func writeStamp(_ stamp: GateProof.Stamp, to context: PathContext) {
  let url = GateProof.stampURL(context: context)
  do {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try stamp.serialized().write(to: url, atomically: true, encoding: .utf8)
  } catch {
    Output.error("test: could not write stamp: \(error)")
  }
}

private func emptyContext() -> PathContext {
  let path = NSTemporaryDirectory() + "gate-proof-empty-" + UUID().uuidString + "/"
  return PathContext(pwd: path, cwd: path)
}

private func makeTemporarySourceTree(files: [String: String]) -> PathContext {
  let root = NSTemporaryDirectory() + "gate-proof-tree-" + UUID().uuidString + "/"
  do {
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: true)
    for (name, body) in files {
      try body.write(toFile: root + name, atomically: true, encoding: .utf8)
    }
  } catch {
    Output.error("test: could not build temporary source tree: \(error)")
  }
  return PathContext(pwd: root, cwd: root)
}

private func removeTree(_ context: PathContext) {
  do {
    try FileManager.default.removeItem(atPath: context.cwd)
  } catch {
    Output.error("test: temporary tree cleanup failed: \(error)")
  }
}
