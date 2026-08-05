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

/// Removes a path a test no longer needs, tolerating its absence.
///
/// A removal that fails for any other reason is surfaced rather than dropped: a
/// cleanup that silently failed would leave the next assertion reading a stale
/// file and reporting a confusing mismatch instead of the real cause.
func removeIfPresent(_ path: String) {
  guard FileManager.default.fileExists(atPath: path) else {
    return
  }
  do {
    try FileManager.default.removeItem(atPath: path)
  } catch {
    Output.warning("test: could not remove \(path): \(error)")
  }
}

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

/// Chunks per second the trickle path emits, and the matching gap between them.
/// Ten a second is fine-grained enough that curl sees steady progress well inside
/// its own speed-time window, which is the property the slow-transfer test needs.
private let trickleChunksPerSecond = 10
private let trickleChunkIntervalMilliseconds: Int64 = 100

/// The server binds loopback on an ephemeral port, so nothing it serves is reachable
/// off the machine and concurrent tests never contend for a fixed port.
private let loopbackHost = "127.0.0.1"
private let listenBacklog: Int32 = 16

// MARK: - FetchStateSnapshot

/// One consistent read of the server state, taken under the lock so the handler
/// sees a single coherent view rather than fields that could change between
/// individual reads.
struct FetchStateSnapshot: Sendable {
  let tarball: [UInt8]
  let etag: String
  let stall: Double
  let forcedStatus: Int?
  let etagEnabled: Bool
  let trickleBytesPerSecond: Int?
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
  private var trickleBytesPerSecond: Int?

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

  func setTrickle(_ bytesPerSecond: Int?) {
    lock.lock()
    defer { lock.unlock() }
    trickleBytesPerSecond = bytesPerSecond
  }

  func snapshot() -> FetchStateSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return FetchStateSnapshot(
      tarball: tarball,
      etag: etagValue,
      stall: stallSeconds,
      forcedStatus: forcedStatus,
      etagEnabled: etagEnabled,
      trickleBytesPerSecond: trickleBytesPerSecond
    )
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
    "http://\(loopbackHost):\(channel.localAddress?.port ?? 0)"
  }

  /// Every wait here suspends rather than blocking. Swift Testing runs test bodies on
  /// its cooperative pool, and NIO marks the blocking forms unavailable from an async
  /// context for that reason; see `OffPoolWork` for what blocking one of those threads
  /// costs.
  init(files: [String: String]) async throws {
    let handlerState = FetchState()
    state = handlerState
    await Self.installArchive(files, into: handlerState)
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    group = eventLoopGroup
    do {
      channel = try await ServerBootstrap(group: eventLoopGroup)
        .serverChannelOption(ChannelOptions.backlog, value: listenBacklog)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { childChannel in
          childChannel.pipeline.configureHTTPServerPipeline().flatMap {
            childChannel.pipeline.addHandler(FetchHandler(state: handlerState))
          }
        }
        .bind(host: loopbackHost, port: 0)
        .get()
    } catch {
      // The group owns a thread and traps if it is deinited without a shutdown, so a
      // failed bind has to release it before the error leaves this initializer. The
      // bind failure is the one worth propagating, so a shutdown failure on top of it
      // is reported rather than thrown and never replaces the original cause.
      do {
        try await eventLoopGroup.shutdownGracefully()
      } catch {
        Output.warning("FetchServer: releasing the group after a failed bind failed: \(error)")
      }
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

  /// Pace every later body-carrying response at bytesPerSecond, delivered in small
  /// chunks via the event loop's own scheduler rather than a dead pre-response
  /// delay, so a test can drive a transfer that is slow but genuinely progressing.
  /// Distinct from `stall`, which delays the whole response including one with no
  /// body at all (a HEAD, a 304, a forced status): a trickle rate silences that
  /// dead delay for exactly the responses it applies to (a real body), since a
  /// request that will carry a body needs to start delivering it immediately to
  /// avoid tripping a speed-limit-style abort, while a bodyless response still
  /// experiences `stall` untouched, simulating a lightweight check upstream has
  /// not answered at all. Pass nil to restore instant delivery.
  func trickle(bytesPerSecond: Int?) {
    state.setTrickle(bytesPerSecond)
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
    // Both failures are reported rather than dropped. A close that fails still
    // has to be followed by the group shutdown, or the group's thread leaks and
    // deinit traps, so neither is allowed to abort the other.
    do {
      try await channel.close().get()
    } catch {
      Output.warning("FetchServer: closing the listener failed: \(error)")
    }
    do {
      try await group.shutdownGracefully()
    } catch {
      Output.warning("FetchServer: releasing the event-loop group failed: \(error)")
    }
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

    let head = responseHead(
      status: status,
      etagEnabled: current.etagEnabled,
      etag: current.etag,
      contentLength: contentBytes.count
    )

    if let bytesPerSecond = current.trickleBytesPerSecond, !transmittedBytes.isEmpty {
      sendTrickled(
        head: head,
        bytes: transmittedBytes,
        bytesPerSecond: bytesPerSecond,
        context: context
      )
      return
    }

    if current.stall > 0 {
      Thread.sleep(forTimeInterval: current.stall)
    }

    context.write(wrapOutboundOut(.head(head)), promise: nil)
    if !transmittedBytes.isEmpty {
      var buffer = context.channel.allocator.buffer(capacity: transmittedBytes.count)
      buffer.writeBytes(transmittedBytes)
      context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

    recordRequest(status: status, bytes: transmittedBytes.count)
  }

  /// The response head a GET and a HEAD both report, so the two paths cannot drift
  /// in status, ETag, or declared length.
  private func responseHead(
    status: HTTPResponseStatus,
    etagEnabled: Bool,
    etag: String,
    contentLength: Int
  ) -> HTTPResponseHead {
    var headers = HTTPHeaders()
    if etagEnabled {
      headers.add(name: "ETag", value: etag)
    }
    headers.add(name: "Content-Length", value: String(contentLength))
    return HTTPResponseHead(version: .http1_1, status: status, headers: headers)
  }

  private func recordRequest(status: HTTPResponseStatus, bytes: Int) {
    state.record(
      FetchRecord(
        path: requestPath,
        method: requestMethod.rawValue,
        ifNoneMatch: ifNoneMatch,
        status: Int(status.code),
        bytes: bytes
      )
    )
  }

  /// Delivers `bytes` as small chunks paced at bytesPerSecond, ten chunks per
  /// second, via the event loop's own `scheduleTask` rather than Thread.sleep, so
  /// pacing a slow transfer never blocks the single-threaded event loop the way
  /// `stall`'s sleep does. The head is flushed immediately, so the first byte of
  /// progress is visible right away, exactly the property that distinguishes a
  /// slow-but-progressing transfer from a dead stall.
  private func sendTrickled(
    head: HTTPResponseHead,
    bytes: [UInt8],
    bytesPerSecond: Int,
    context: ChannelHandlerContext
  ) {
    context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
    writeNextTrickleChunk(
      bytes: bytes,
      offset: 0,
      bytesPerSecond: bytesPerSecond,
      status: head.status,
      context: context
    )
  }

  private func writeNextTrickleChunk(
    bytes: [UInt8],
    offset: Int,
    bytesPerSecond: Int,
    status: HTTPResponseStatus,
    context: ChannelHandlerContext
  ) {
    if offset >= bytes.count {
      context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
      recordRequest(status: status, bytes: bytes.count)
      return
    }
    let chunkSize = max(1, bytesPerSecond / trickleChunksPerSecond)
    let end = min(offset + chunkSize, bytes.count)
    var buffer = context.channel.allocator.buffer(capacity: end - offset)
    buffer.writeBytes(bytes[offset..<end])
    context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    // ChannelHandlerContext is not Sendable, but this closure only ever runs on
    // the same event loop that scheduled it, the same guarantee that already
    // makes FetchHandler itself @unchecked Sendable; nonisolated(unsafe) states
    // that explicitly instead of leaving a real capture warning unaddressed.
    nonisolated(unsafe) let scheduledContext = context
    context.eventLoop.scheduleTask(in: .milliseconds(trickleChunkIntervalMilliseconds)) {
      self.writeNextTrickleChunk(
        bytes: bytes,
        offset: end,
        bytesPerSecond: bytesPerSecond,
        status: status,
        context: scheduledContext
      )
    }
  }
}

// MARK: - TarballBuilder

/// Builds the archive the server serves. It shells out to the system `tar`
/// rather than emitting the format by hand, so the bytes under test are
/// produced by the same tool the helper extracts them with.
enum TarballBuilder {
  /// FNV-1a 64-bit parameters. Any stable content hash would do here; the ETag only
  /// has to change when the file set changes and stay identical when it does not.
  private static let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
  private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3
  private static let hexRadix = 16

  static func build(_ files: [String: String]) -> [UInt8] {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
      "swift-mk-tarball-" + UUID().uuidString, isDirectory: true)
    // One top-level directory, matching a GitHub source archive that
    // `tar --strip-components=1` flattens.
    let treeRoot = root.appendingPathComponent("swift-makefile-test", isDirectory: true)
    defer { removeIfPresent(root.path) }

    do {
      try manager.createDirectory(at: treeRoot, withIntermediateDirectories: true)
      for name in files.keys.sorted() {
        guard let body = files[name] else {
          continue
        }
        let target = treeRoot.appendingPathComponent(name)
        try manager.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: target, atomically: true, encoding: .utf8)
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
    var hash = fnvOffsetBasis
    for name in files.keys.sorted() {
      let body = files[name] ?? ""
      for byte in Array(name.utf8) + [0] + Array(body.utf8) + [0] {
        hash ^= UInt64(byte)
        hash = hash &* fnvPrime
      }
    }
    return String(hash, radix: hexRadix)
  }
}
