//
//  FetchServer.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//
//  A local stand-in for codeload.github.com, so the fetch tests exercise real
//  conditional requests rather than a mocked transport. It serves a real
//  gzipped tarball, returns an ETag, and answers If-None-Match with 304 and an
//  empty body, which is the behavior the bootstrap helper depends on.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

// MARK: - FetchRecord

/// One served request, so a test can assert how many times the helper reached
/// the network and what each call returned.
struct FetchRecord: Sendable {
  let ifNoneMatch: String
  let status: Int
  let bytes: Int
}

// MARK: - FetchState

/// The mutable server state. One lock guards it because the NIO event loop and
/// the test thread both touch it.
final class FetchState: @unchecked Sendable {
  private let lock = NSLock()
  private var tarball: [UInt8] = []
  private var etagValue = ""
  private var stallSeconds: Double = 0
  private var records: [FetchRecord] = []

  func setFiles(_ files: [String: String]) {
    let archive = TarballBuilder.build(files)
    // Digest the file set, not the archive bytes: gzip stamps a timestamp into
    // its header, so identical content would otherwise produce a new ETag on
    // every rebuild and no request would ever validate as unchanged.
    let fingerprint = TarballBuilder.fingerprint(files)
    lock.lock()
    defer { lock.unlock() }
    tarball = archive
    etagValue = "\"" + fingerprint + "\""
  }

  func stall(_ seconds: Double) {
    lock.lock()
    defer { lock.unlock() }
    stallSeconds = seconds
  }

  func snapshot() -> (tarball: [UInt8], etag: String, stall: Double) {
    lock.lock()
    defer { lock.unlock() }
    return (tarball, etagValue, stallSeconds)
  }

  func record(_ entry: FetchRecord) {
    lock.lock()
    defer { lock.unlock() }
    records.append(entry)
  }

  func requests() -> [FetchRecord] {
    lock.lock()
    defer { lock.unlock() }
    return records
  }
}

// MARK: - FetchServer

/// Serves the engine tarball over HTTP on a loopback port.
final class FetchServer: @unchecked Sendable {
  private let group: MultiThreadedEventLoopGroup
  private let channel: Channel
  private let state = FetchState()

  /// The base URL to pass as `SWIFT_MK_CODELOAD_BASE`.
  var codeloadBase: String {
    "http://127.0.0.1:\(channel.localAddress?.port ?? 0)"
  }

  init(files: [String: String]) throws {
    state.setFiles(files)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    self.group = group
    let handlerState = state
    channel = try ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 16)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(FetchHandler(state: handlerState))
        }
      }
      .bind(host: "127.0.0.1", port: 0)
      .wait()
  }

  /// Replace the served tree, which changes the ETag and simulates upstream
  /// moving.
  func setFiles(_ files: [String: String]) {
    state.setFiles(files)
  }

  /// Make every later request sleep before responding, so a test can drive the
  /// helper's validation timeout.
  func stall(_ seconds: Double) {
    state.stall(seconds)
  }

  func requests() -> [FetchRecord] {
    state.requests()
  }

  func shutdown() {
    try? channel.close().wait()
    try? group.syncShutdownGracefully()
  }
}

// MARK: - FetchHandler

private final class FetchHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let state: FetchState
  private var ifNoneMatch = ""

  init(state: FetchState) {
    self.state = state
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
      case .head(let head):
        ifNoneMatch = head.headers.first(name: "If-None-Match") ?? ""
      case .body:
        break
      case .end:
        respond(context: context)
    }
  }

  private func respond(context: ChannelHandlerContext) {
    let current = state.snapshot()
    if current.stall > 0 {
      Thread.sleep(forTimeInterval: current.stall)
    }

    let matched = ifNoneMatch == current.etag
    let status: HTTPResponseStatus = matched ? .notModified : .ok
    let bodyBytes = matched ? [] : current.tarball

    var headers = HTTPHeaders()
    headers.add(name: "ETag", value: current.etag)
    headers.add(name: "Content-Length", value: String(bodyBytes.count))

    let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    if !bodyBytes.isEmpty {
      var buffer = context.channel.allocator.buffer(capacity: bodyBytes.count)
      buffer.writeBytes(bodyBytes)
      context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

    state.record(
      FetchRecord(ifNoneMatch: ifNoneMatch, status: Int(status.code), bytes: bodyBytes.count))
  }
}

// MARK: - TarballBuilder

/// Builds the archive the server serves. It shells out to the system `tar`
/// rather than emitting the format by hand, so the bytes under test are
/// produced by the same tool the helper extracts them with.
enum TarballBuilder {
  static func build(_ files: [String: String]) -> [UInt8] {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
      "swift-mk-tarball-" + UUID().uuidString, isDirectory: true)
    // One top-level directory, matching a GitHub source archive that
    // `tar --strip-components=1` flattens.
    let treeRoot = root.appendingPathComponent("swift-makefile-test", isDirectory: true)
    defer { try? manager.removeItem(at: root) }

    do {
      try manager.createDirectory(at: treeRoot, withIntermediateDirectories: true)
      for name in files.keys.sorted() {
        let target = treeRoot.appendingPathComponent(name)
        try manager.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files[name]!.write(to: target, atomically: true, encoding: .utf8)
      }

      let archive = root.appendingPathComponent("snapshot.tar.gz")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      // Sorted names and a fixed mtime keep the bytes stable for one file set,
      // so an unchanged tree keeps its ETag.
      process.arguments = [
        "tar", "-czf", archive.path, "-C", root.path, "swift-makefile-test",
      ]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        return []
      }
      return [UInt8](try Data(contentsOf: archive))
    } catch {
      return []
    }
  }

  /// A digest of the served file set, used as the ETag. It changes when a name
  /// or a body changes, and not otherwise.
  static func fingerprint(_ files: [String: String]) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for name in files.keys.sorted() {
      for byte in Array(name.utf8) + [0] + Array(files[name]!.utf8) + [0] {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
      }
    }
    return String(hash, radix: 16)
  }
}
