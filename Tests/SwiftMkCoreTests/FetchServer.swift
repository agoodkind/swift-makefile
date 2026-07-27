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

@testable import SwiftMkCore

// MARK: - FetchRecord

/// One served request, so a test can assert how many times the helper reached
/// the network, which path it asked for, and what each call returned.
struct FetchRecord: Sendable {
  let path: String
  let method: String
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
  private var forcedStatus: Int?
  private var etagEnabled = true

  /// Install an already-built archive. The build itself spawns `tar` and blocks
  /// waiting for it, so callers run it through `OffPoolWork` and hand the bytes here.
  /// The fingerprint digests the file set, not the archive bytes: gzip stamps a
  /// timestamp into its header, so identical content would otherwise produce a new
  /// ETag on every rebuild and no request would ever validate as unchanged.
  func setArchive(_ archive: [UInt8], fingerprint: String) {
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

  func setForcedStatus(_ status: Int?) {
    lock.lock()
    defer { lock.unlock() }
    forcedStatus = status
  }

  func setETagEnabled(_ enabled: Bool) {
    lock.lock()
    defer { lock.unlock() }
    etagEnabled = enabled
  }

  func snapshot() -> (
    tarball: [UInt8], etag: String, stall: Double, forcedStatus: Int?, etagEnabled: Bool
  ) {
    lock.lock()
    defer { lock.unlock() }
    return (tarball, etagValue, stallSeconds, forcedStatus, etagEnabled)
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
  private let state: FetchState

  /// The base URL to pass as `SWIFT_MK_CODELOAD_BASE`.
  var codeloadBase: String {
    "http://127.0.0.1:\(channel.localAddress?.port ?? 0)"
  }

  /// Every wait here suspends rather than blocking. Swift Testing runs test bodies on
  /// its cooperative pool, and NIO marks the blocking forms unavailable from an async
  /// context for that reason; see `OffPoolWork` for what blocking one of those threads
  /// costs.
  init(files: [String: String]) async throws {
    let handlerState = FetchState()
    state = handlerState
    await Self.installArchive(files, into: handlerState)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    self.group = group
    do {
      channel = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
          channel.pipeline.configureHTTPServerPipeline().flatMap {
            channel.pipeline.addHandler(FetchHandler(state: handlerState))
          }
        }
        .bind(host: "127.0.0.1", port: 0)
        .get()
    } catch {
      // The group owns a thread and traps if it is deinited without a shutdown, so a
      // failed bind has to release it before the error leaves this initializer.
      try? await group.shutdownGracefully()
      throw error
    }
  }

  /// Run a scoped server, shutting it down on every exit path. `shutdown` has to be
  /// awaited, and `defer` cannot await, so this is what guarantees the group is
  /// released when the body throws.
  static func withServer<Value>(
    files: [String: String],
    _ body: (FetchServer) async throws -> Value
  ) async throws -> Value {
    let server = try await FetchServer(files: files)
    do {
      let value = try await body(server)
      await server.shutdown()
      return value
    } catch {
      await server.shutdown()
      throw error
    }
  }

  /// Replace the served tree, which changes the ETag and simulates upstream
  /// moving.
  func setFiles(_ files: [String: String]) async {
    await Self.installArchive(files, into: state)
  }

  /// Build the archive off the cooperative pool (it spawns `tar` and waits for it),
  /// then install it.
  private static func installArchive(_ files: [String: String], into state: FetchState) async {
    let archive = await OffPoolWork.run { TarballBuilder.build(files) }
    state.setArchive(archive, fingerprint: TarballBuilder.fingerprint(files))
  }

  /// Make every later request sleep before responding, so a test can drive the
  /// helper's validation timeout.
  func stall(_ seconds: Double) {
    state.stall(seconds)
  }

  /// Force every later response to the given status (for example 404 or 500)
  /// with an empty body, bypassing the normal ETag-based 200/304 choice. Pass
  /// nil to restore normal behavior. Lets a test drive the helper's handling
  /// of an upstream error response.
  func forceStatus(_ status: Int?) {
    state.setForcedStatus(status)
  }

  /// Stop sending the ETag header on every later response, so a test can
  /// drive the path where no conditional validation is possible.
  func setETagEnabled(_ enabled: Bool) {
    state.setETagEnabled(enabled)
  }

  func requests() -> [FetchRecord] {
    state.requests()
  }

  /// Close the listener and release the event-loop group.
  ///
  /// `syncShutdownGracefully` stood here and is what wedged the suite. NIO delivers its
  /// completion on `DispatchQueue.global()` and then blocks the caller on a semaphore
  /// until that block runs, which is why NIO marks it `noasync`. Called from enough test
  /// bodies at once it holds every cooperative thread, the completion block can no
  /// longer be scheduled, and nothing can ever signal the semaphore. The async form
  /// suspends instead, so the thread is free and the completion always gets one.
  func shutdown() async {
    try? await channel.close().get()
    try? await group.shutdownGracefully()
  }
}

// MARK: - FetchHandler

/// Unchecked because the handler's per-request fields are only ever touched from the
/// channel's own event loop, which NIO guarantees is a single thread. The bootstrap now
/// runs from an async context, so the closure that constructs the handler is checked
/// for sendability where it was not before.
private final class FetchHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let state: FetchState
  private var requestPath = ""
  private var requestMethod: HTTPMethod = .GET
  private var ifNoneMatch = ""

  init(state: FetchState) {
    self.state = state
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      requestPath = head.uri
      requestMethod = head.method
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

    let status: HTTPResponseStatus
    let contentBytes: [UInt8]
    if let forcedStatus = current.forcedStatus {
      status = HTTPResponseStatus(statusCode: forcedStatus)
      contentBytes = []
    } else {
      let matched = current.etagEnabled && ifNoneMatch == current.etag
      status = matched ? .notModified : .ok
      contentBytes = matched ? [] : current.tarball
    }
    // A HEAD response reports the same status and content length a GET would,
    // but never actually transmits a body, matching real codeload.github.com.
    let transmittedBytes = requestMethod == .HEAD ? [] : contentBytes

    var headers = HTTPHeaders()
    if current.etagEnabled {
      headers.add(name: "ETag", value: current.etag)
    }
    headers.add(name: "Content-Length", value: String(contentBytes.count))

    let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    if !transmittedBytes.isEmpty {
      var buffer = context.channel.allocator.buffer(capacity: transmittedBytes.count)
      buffer.writeBytes(transmittedBytes)
      context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

    state.record(
      FetchRecord(
        path: requestPath, method: requestMethod.rawValue, ifNoneMatch: ifNoneMatch,
        status: Int(status.code), bytes: transmittedBytes.count))
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
      // An explicit, minimal environment instead of the ambient default: this
      // runs on every FetchServer init (once per test in this file), and
      // reading ProcessInfo.processInfo.environment races any concurrently
      // running suite's setenv/unsetenv the same way runHelper's read did
      // before it was moved under TestGlobalLock.
      process.environment = TestGlobalLock.withLock {
        [
          "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
          "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "",
        ]
      }
      // A child inherits the process working directory when none is set, and several
      // suites in this target chdir into a temporary tree and then delete it. A spawn
      // that lands in that window fails with ENOENT on a directory it never asked for.
      // Naming the directory explicitly takes this tar off that shared global entirely.
      process.currentDirectoryURL = root
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        Output.error("test: tarball tar exited \(process.terminationStatus)")
        return []
      }
      return [UInt8](try Data(contentsOf: archive))
    } catch {
      // Returning an empty archive silently made every downstream failure read as a
      // fetch problem, so the real cause has to reach the log.
      Output.error("test: could not build the served tarball: \(error)")
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
