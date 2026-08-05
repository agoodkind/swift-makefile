# Validated Snapshot Reuse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a swift-makefile consumer track upstream again, reuse its `.make` snapshot when upstream has not moved, parse offline within a bounded window, and stop refetching five config files it already has.

**Architecture:** A new shell helper, `scripts/swift-mk-bootstrap.sh`, owns provisioning. It sends one conditional `GET` to codeload carrying `If-None-Match`; a `304` proves the extracted tree is byte-identical so nothing is touched, and a `200` is staged and swapped in after verification. `swift.mk` delegates to the helper once it exists, and `bootstrap.mk` shrinks to variables, the trace header, helper acquisition, and the include.

**Tech Stack:** GNU Make, Bash, curl, Swift 6 with Swift Testing, SwiftNIO for the test server.

## Global Constraints

- Validation request bound: `--connect-timeout 2 --max-time 3`. Measured `304` is 0.88s median on a 201ms RTT link.
- Reuse window after a failed validation: 3600 seconds (1 hour), a hardcoded constant, not a variable. The clock runs from the last completed download and a successful `304` never resets it, so the window is fixed rather than sliding. Offline reuse is therefore available only within an hour of a real download, which is the intended strictness.
- CI test: `GITHUB_ACTIONS` equals `true` AND `GITHUB_RUN_ID` is non-empty, matching `Build.runsInlineGates` in `Sources/SwiftMkCore/Build.swift:29`. `GITHUB_ACTIONS` alone is not CI.
- In CI: never read state, never write state, never send a conditional request, never serve disk on failure.
- No new user-facing variable. `SWIFT_MK_SKIP_FETCH` stays the only knob. `SWIFT_MK_CODELOAD_BASE` is internal and test-only, in the same category as the existing `SWIFT_MK_API_REPO` and `SWIFT_MK_API_REF` overrides.
- Marker path stays `.make/.swift-mk-snapshot-ref` so `snapshot_clear_engine` keeps preserving it by name. Its new format is three lines: `ref=`, `etag=`, `timestamp=`.
- A `dev-<sha>` marker keeps its current meaning and is never validated against upstream.
- A `304` must touch no file under `.make`, including mtimes, because the tool-binary staleness guard would otherwise force a rebuild.
- Shell rules: `#!/usr/bin/env bash`, `set -euo pipefail`, `[[ ]]` tests, 4-space indent, `local` inside functions, snake_case functions and locals, UPPER_CASE constants, full `if / then / fi` blocks.
- Spec: `docs/superpowers/specs/2026-07-26-end-fetch-cache-moratorium-design.md`.

---

## File Structure

**Created:**

- `scripts/swift-mk-bootstrap.sh` is the helper. It owns the decision table, staged provisioning, marker read and write, the self-replacement guard, and the CI rule.
- `Tests/SwiftMkCoreTests/FetchServer.swift` is the shared test server. It serves a real gzipped tarball over NIO HTTP/1, computes an `ETag`, honors `If-None-Match`, counts requests, and can stall or advance its content.
- `Tests/SwiftMkCoreTests/BootstrapFetchTests.swift` holds the tests that invoke the helper directly.
- `Tests/SwiftMkCoreTests/SnapshotReuseTests.swift` holds the snapshot and config-provenance tests.

**Modified:**

- `Package.swift` declares `swift-nio` so the test target can use `NIOHTTP1`. The package is already resolved transitively through grpc-swift, so no new code enters the dependency graph.
- `swift.mk` gains the new marker format and the freeze fix, delegates to the helper once it exists, and stops refetching the configs and modules.
- `scripts/swift-mk-sync.sh` writes the marker's new format in `snapshot_extract`.
- `bootstrap.mk` is reduced to variables, the trace header, helper acquisition, and the include.
- `docs/fetch/overview.md` states the reuse rule as current-state behavior.

---

### Task 1: Tarball test server

**Files:**
- Modify: `Package.swift`
- Create: `Tests/SwiftMkCoreTests/FetchServer.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `final class FetchServer` with `init(files: [String: String]) throws`
  - `var codeloadBase: String` returns the base URL to pass as `SWIFT_MK_CODELOAD_BASE`.
  - `func setFiles(_ files: [String: String])` advances the served content and the `ETag`.
  - `func stall(_ seconds: Double)` makes every later request sleep before responding.
  - `func requests() -> [FetchRecord]` where `struct FetchRecord { let ifNoneMatch: String; let status: Int; let bytes: Int }`
  - `func shutdown()`

- [ ] **Step 1: Write the failing test**

Create `Tests/SwiftMkCoreTests/FetchServer.swift` with the test first. The server follows in Step 4.

```swift
//
//  FetchServer.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

// MARK: - FetchServerTests

enum FetchServerTests {}

@Test
func fetchServerServesTarballAndHonorsIfNoneMatch() async throws {
  let server = try FetchServer(files: ["swift.mk": "SWIFT_MK := 1\n"])
  defer { server.shutdown() }

  let url = URL(string: server.codeloadBase + "/agoodkind/swift-makefile/tar.gz/main")!
  let (firstBody, firstResponse) = try await URLSession.shared.data(from: url)
  let firstHTTP = try #require(firstResponse as? HTTPURLResponse)
  #expect(firstHTTP.statusCode == 200)
  #expect(!firstBody.isEmpty)

  let etag = try #require(firstHTTP.value(forHTTPHeaderField: "ETag"))

  var conditional = URLRequest(url: url)
  conditional.setValue(etag, forHTTPHeaderField: "If-None-Match")
  conditional.cachePolicy = .reloadIgnoringLocalCacheData
  let (_, secondResponse) = try await URLSession.shared.data(for: conditional)
  #expect((secondResponse as? HTTPURLResponse)?.statusCode == 304)

  server.setFiles(["swift.mk": "SWIFT_MK := 2\n"])
  let (_, thirdResponse) = try await URLSession.shared.data(for: conditional)
  #expect((thirdResponse as? HTTPURLResponse)?.statusCode == 200)

  #expect(server.requests().count == 3)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/agoodkind/.worktrees/-Users-agoodkind-Sites-swift-makefile/end-fetch-cache-moratorium && swift test --filter fetchServerServesTarball`

Expected: FAIL to build with `cannot find 'FetchServer' in scope`.

- [ ] **Step 3: Declare the NIO dependency**

In `Package.swift`, add to `dependencies:`:

```swift
    // Already resolved transitively through grpc-swift and pinned in
    // Package.resolved. Declared explicitly so the test target can use
    // NIOHTTP1 for a local server, which keeps the fetch tests real without
    // adding anything to the dependency graph.
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
```

Add to the `SwiftMkCoreTests` target's `dependencies:` array:

```swift
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
```

- [ ] **Step 4: Write minimal implementation**

Append the server to `Tests/SwiftMkCoreTests/FetchServer.swift`, adding the imports `NIOCore`, `NIOHTTP1`, and `NIOPosix`.

```swift
import NIOCore
import NIOHTTP1
import NIOPosix

// MARK: - FetchRecord

/// One served request, so a test can assert how many times the helper hit the
/// network and what each call returned.
struct FetchRecord: Sendable {
  let ifNoneMatch: String
  let status: Int
  let bytes: Int
}

// MARK: - FetchState

/// The mutable server state, guarded by one lock so the NIO event loop and the
/// test thread can both touch it.
final class FetchState: @unchecked Sendable {
  private let lock = NSLock()
  private var tarball: [UInt8] = []
  private var etagValue = ""
  private var stallSeconds: Double = 0
  private var records: [FetchRecord] = []

  func setFiles(_ files: [String: String]) {
    let archive = TarballBuilder.build(files)
    lock.lock()
    defer { lock.unlock() }
    tarball = archive
    etagValue = "\"" + TarballBuilder.digest(archive) + "\""
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

/// Stands in for codeload.github.com. It answers conditional requests the way
/// codeload does: an ETag on 200, and 304 with an empty body when the caller's
/// If-None-Match still matches the current content.
final class FetchServer: @unchecked Sendable {
  private let group: MultiThreadedEventLoopGroup
  private let channel: Channel
  private let state = FetchState()

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

  func setFiles(_ files: [String: String]) {
    state.setFiles(files)
  }

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

    var headers = HTTPHeaders()
    headers.add(name: "ETag", value: current.etag)

    let matched = ifNoneMatch == current.etag
    let status: HTTPResponseStatus = matched ? .notModified : .ok
    let bodyBytes = matched ? [] : current.tarball

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
```

- [ ] **Step 5: Add the tarball builder**

Append to the same file. It emits an uncompressed-payload gzip member so no compression library is needed, which `tar -xzf` accepts.

```swift
// MARK: - TarballBuilder

/// Builds a gzipped tar whose entries all sit under one top-level directory,
/// matching a GitHub source archive that `tar --strip-components=1` flattens.
/// Entries are sorted so the same file set always produces the same bytes, and
/// therefore the same ETag.
enum TarballBuilder {
  static func build(_ files: [String: String]) -> [UInt8] {
    var tar: [UInt8] = []
    for name in files.keys.sorted() {
      let body = Array(files[name]!.utf8)
      tar.append(contentsOf: header(name: "swift-makefile-test/" + name, size: body.count))
      tar.append(contentsOf: body)
      let padding = (512 - body.count % 512) % 512
      tar.append(contentsOf: [UInt8](repeating: 0, count: padding))
    }
    // Two zero blocks end the archive.
    tar.append(contentsOf: [UInt8](repeating: 0, count: 1024))
    return gzipStored(tar)
  }

  static func digest(_ bytes: [UInt8]) -> String {
    // FNV-1a is enough here: the ETag only has to change when the content does.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
      hash ^= UInt64(byte)
      hash = hash &* 0x1000_0000_01b3
    }
    return String(hash, radix: 16)
  }

  private static func header(name: String, size: Int) -> [UInt8] {
    var block = [UInt8](repeating: 0, count: 512)
    write(&block, Array(name.utf8), at: 0, width: 100)
    write(&block, Array(octal(0o644, width: 7).utf8), at: 100, width: 8)
    write(&block, Array(octal(0, width: 7).utf8), at: 108, width: 8)
    write(&block, Array(octal(0, width: 7).utf8), at: 116, width: 8)
    write(&block, Array(octal(size, width: 11).utf8), at: 124, width: 12)
    write(&block, Array(octal(0, width: 11).utf8), at: 136, width: 12)
    // Checksum field is spaces while the checksum is computed.
    for index in 148..<156 {
      block[index] = 0x20
    }
    block[156] = UInt8(ascii: "0")
    write(&block, Array("ustar\0".utf8), at: 257, width: 6)
    write(&block, Array("00".utf8), at: 263, width: 2)

    let checksum = block.reduce(0) { $0 + Int($1) }
    write(&block, Array(octal(checksum, width: 6).utf8), at: 148, width: 7)
    block[154] = 0
    block[155] = 0x20
    return block
  }

  private static func write(_ block: inout [UInt8], _ bytes: [UInt8], at offset: Int, width: Int) {
    for (index, byte) in bytes.prefix(width).enumerated() {
      block[offset + index] = byte
    }
  }

  private static func octal(_ value: Int, width: Int) -> String {
    let digits = String(value, radix: 8)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }

  /// Wrap the payload in a gzip member using stored (uncompressed) deflate
  /// blocks, so no compression library is required and gzip still accepts it.
  private static func gzipStored(_ payload: [UInt8]) -> [UInt8] {
    var output: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]
    var offset = 0
    if payload.isEmpty {
      output.append(contentsOf: [0x01, 0x00, 0x00, 0xff, 0xff])
    }
    while offset < payload.count {
      let chunk = min(65535, payload.count - offset)
      let isFinal: UInt8 = (offset + chunk >= payload.count) ? 1 : 0
      output.append(isFinal)
      output.append(UInt8(chunk & 0xff))
      output.append(UInt8((chunk >> 8) & 0xff))
      output.append(UInt8(~chunk & 0xff))
      output.append(UInt8((~chunk >> 8) & 0xff))
      output.append(contentsOf: payload[offset..<(offset + chunk)])
      offset += chunk
    }
    var crc = crc32(payload)
    var size = UInt32(truncatingIfNeeded: payload.count)
    for _ in 0..<4 {
      output.append(UInt8(crc & 0xff))
      crc >>= 8
    }
    for _ in 0..<4 {
      output.append(UInt8(size & 0xff))
      size >>= 8
    }
    return output
  }

  private static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
      var value = UInt32(index)
      for _ in 0..<8 {
        value = (value & 1 == 1) ? (0xedb8_8320 ^ (value >> 1)) : (value >> 1)
      }
      table[index] = value
    }
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes {
      crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
    }
    return crc ^ 0xffff_ffff
  }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter fetchServerServesTarball`
Expected: PASS.

Then prove the archive is real by extracting it with the system `tar`, which is what the helper uses:

Run: `swift test --filter fetchServerServesTarball 2>&1 && echo harness-ok`
Expected: `harness-ok`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved Tests/SwiftMkCoreTests/FetchServer.swift
git commit -S -m "Add NIO-backed tarball test server for fetch tests

Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 2: Helper cold provision with a self-replacement guard

**Files:**
- Create: `scripts/swift-mk-bootstrap.sh`
- Create: `Tests/SwiftMkCoreTests/BootstrapFetchTests.swift`

**Interfaces:**
- Consumes: `FetchServer` from Task 1.
- Produces:
  - The helper's contract. Run `bash scripts/swift-mk-bootstrap.sh` with the working directory at the consumer root. It reads `SWIFT_MK_API_REPO`, `SWIFT_MK_API_REF`, `SWIFT_MK_CODELOAD_BASE`, `SWIFT_MK_DEV_DIR`, `SWIFT_MK_MODULES`, and `SWIFT_MK_SKIP_FETCH`. It exits 0 with a complete `.make`, or non-zero with a message on stderr.
  - `func runHelper(directory: String, environment: [String: String]) -> (stdout: String, stderr: String, status: Int32)` in `BootstrapFetchTests.swift`.
  - `func engineFiles() -> [String: String]` in `BootstrapFetchTests.swift`.
  - `func makePath(_ directory: String, _ relative: String) -> String` in `BootstrapFetchTests.swift`.
  - `func writeMakeFile(_ directory: String, _ relative: String, _ body: String) throws` in `BootstrapFetchTests.swift`.
  - `func readMakeFile(_ directory: String, _ relative: String) -> String?` in `BootstrapFetchTests.swift`.
  - `func temporaryConsumer() throws -> String` in `BootstrapFetchTests.swift`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SwiftMkCoreTests/BootstrapFetchTests.swift`.

```swift
//
//  BootstrapFetchTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BootstrapFetchTests

enum BootstrapFetchTests {}

/// The engine tree the test server serves. It carries every asset the helper
/// must provision, so a cold run has a complete source.
func engineFiles() -> [String: String] {
  [
    "swift.mk": "# swift.mk v1\n",
    "Package.swift": "// swift-tools-version: 6.0\n",
    "scripts/swift-mk-build.sh": "#!/usr/bin/env bash\nexit 0\n",
    "scripts/swift-mk-fetch-one.sh": "#!/usr/bin/env bash\nexit 0\n",
    "scripts/swift-mk-sync.sh": "#!/usr/bin/env bash\nexit 0\n",
    "scripts/swift-mk-bootstrap.sh": "#!/usr/bin/env bash\nexit 0\n",
    ".swiftlint.yml": "# swiftlint v1\n",
    ".swift-format": "{}\n",
    ".periphery.yml": "# periphery v1\n",
    "osv-scanner.toml": "# osv v1\n",
    "mise.toml": "# mise v1\n",
  ]
}

func temporaryConsumer() throws -> String {
  let path = NSTemporaryDirectory() + "swift-mk-consumer-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

func makePath(_ directory: String, _ relative: String) -> String {
  (directory as NSString).appendingPathComponent(".make/" + relative)
}

func writeMakeFile(_ directory: String, _ relative: String, _ body: String) throws {
  let path = makePath(directory, relative)
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try body.write(toFile: path, atomically: true, encoding: .utf8)
}

func readMakeFile(_ directory: String, _ relative: String) -> String? {
  try? String(contentsOfFile: makePath(directory, relative), encoding: .utf8)
}

/// Runs the helper with the working directory at `directory` and an environment
/// that never inherits a real CI context.
func runHelper(directory: String, environment: [String: String]) -> (
  stdout: String, stderr: String, status: Int32
) {
  let helper = repositoryRoot() + "/scripts/swift-mk-bootstrap.sh"
  var merged: [String: String] = [
    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
    "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "",
    "SWIFT_MK_API_REPO": "agoodkind/swift-makefile",
    "SWIFT_MK_API_REF": "main",
    "SWIFT_MK_DEV_DIR": "",
    "SWIFT_MK_MODULES": "",
    "GITHUB_ACTIONS": "",
    "GITHUB_RUN_ID": "",
  ]
  for (key, value) in environment {
    merged[key] = value
  }

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/bash")
  process.arguments = [helper]
  process.currentDirectoryURL = URL(fileURLWithPath: directory)
  process.environment = merged
  let outPipe = Pipe()
  let errPipe = Pipe()
  process.standardOutput = outPipe
  process.standardError = errPipe
  try? process.run()
  let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
  let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (
    String(decoding: outData, as: UTF8.self),
    String(decoding: errData, as: UTF8.self),
    process.terminationStatus
  )
}

func repositoryRoot() -> String {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .path
}

@Test
func helperColdProvisionWritesEveryAsset() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status == 0, "helper failed: \(result.stderr)")

  #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v1\n")
  #expect(readMakeFile(directory, "Package.swift") != nil)
  #expect(readMakeFile(directory, "scripts/swift-mk-build.sh") != nil)
  #expect(server.requests().count == 1)
}

@Test
func helperLeavesSnapshotIntactWhenUpstreamIsUnreachable() throws {
  let directory = try temporaryConsumer()
  try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
  try writeMakeFile(directory, "Package.swift", "// warm\n")
  try writeMakeFile(directory, "scripts/swift-mk-build.sh", "#!/usr/bin/env bash\nexit 0\n")

  // A port nothing listens on, so every request fails at connect.
  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": "http://127.0.0.1:9"])
  #expect(result.status != 0)

  // The point of the task: a failed fetch must not remove what was there.
  #expect(readMakeFile(directory, "swift.mk") == "# warm swift.mk\n")
  #expect(readMakeFile(directory, "Package.swift") == "// warm\n")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter helperColdProvision`
Expected: FAIL, because `scripts/swift-mk-bootstrap.sh` does not exist so bash exits 127.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/swift-mk-bootstrap.sh`.

```bash
#!/usr/bin/env bash
# swift-mk-bootstrap.sh: provision the swift-makefile engine snapshot into .make.
#
# bootstrap.mk delegates here so fetch policy lives in a fetched file rather
# than in the copy each consumer commits. A policy change therefore ships to
# every consumer on its next parse, with no consumer pull request.
#
# Provisioning is staged: one tarball extracts into a temp directory, the
# required assets are verified there, and only then is the tree under .make
# replaced. Nothing is removed before its replacement exists.
#
# This script lives inside the tree it replaces, so it re-executes from a
# temporary copy before touching .make. A running bash script whose file is
# rewritten underneath it can misread its own remaining bytes.

set -euo pipefail

SWIFT_MK_API_REPO="${SWIFT_MK_API_REPO:-agoodkind/swift-makefile}"
SWIFT_MK_API_REF="${SWIFT_MK_API_REF:-main}"
# Internal override, in the same category as SWIFT_MK_API_REPO and
# SWIFT_MK_API_REF. Tests point it at a local server; consumers never set it.
SWIFT_MK_CODELOAD_BASE="${SWIFT_MK_CODELOAD_BASE:-https://codeload.github.com}"
SWIFT_MK_DEV_DIR="${SWIFT_MK_DEV_DIR:-}"
SWIFT_MK_MODULES="${SWIFT_MK_MODULES:-}"

MAKE_DIR=".make"
FETCH_MAX_TIME=60

# Re-execute from a temp copy so replacing this file mid-run is safe. The guard
# variable stops the copy from re-executing itself.
reexec_from_temp_copy() {
    local temp_copy
    if [[ -n "${SWIFT_MK_BOOTSTRAP_REEXEC:-}" ]]; then
        return 0
    fi
    temp_copy=$(mktemp "${TMPDIR:-/tmp}/swift-mk-bootstrap.XXXXXXXX") || return 1
    cp "$0" "${temp_copy}"
    chmod +x "${temp_copy}"
    SWIFT_MK_BOOTSTRAP_REEXEC=1 exec bash "${temp_copy}" "$@"
}

required_assets() {
    printf '%s\n' "swift.mk"
    printf '%s\n' "Package.swift"
    printf '%s\n' "scripts/swift-mk-build.sh"
    local module_name
    for module_name in ${SWIFT_MK_MODULES}; do
        printf '%s\n' "${module_name}"
    done
}

assets_complete() {
    local base_dir="$1"
    local asset_name
    while IFS= read -r asset_name; do
        if [[ ! -s "${base_dir}/${asset_name}" ]]; then
            return 1
        fi
    done < <(required_assets)
    return 0
}

# install_from_stage replaces the engine tree under .make with the verified
# staged tree, preserving the generated runtime files a build depends on. It
# mirrors snapshot_clear_engine's preserve list in scripts/swift-mk-sync.sh.
install_from_stage() {
    local stage_dir="$1"
    find "${MAKE_DIR}" -mindepth 1 -maxdepth 1 \
        ! -name logs \
        ! -name build.lock \
        ! -name swift-mk \
        ! -name swift-mk.key \
        ! -name swift-mk-build \
        ! -name dev \
        ! -name .swift-mk-snapshot-ref \
        ! -name '*.log' \
        -exec rm -rf {} +
    cp -R "${stage_dir}/." "${MAKE_DIR}/"
    find "${MAKE_DIR}/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
}

provision() {
    local stage_root
    local stage_dir
    local status_code

    stage_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-mk-stage.XXXXXXXX") || return 1
    trap 'rm -rf "${stage_root}"' RETURN

    if ! status_code=$(curl -sS --connect-timeout 5 --max-time "${FETCH_MAX_TIME}" \
        -o "${stage_root}/snapshot.tar.gz" -w '%{http_code}' \
        "${SWIFT_MK_CODELOAD_BASE}/${SWIFT_MK_API_REPO}/tar.gz/${SWIFT_MK_API_REF}" 2>/dev/null); then
        return 1
    fi
    if [[ "${status_code}" != "200" ]]; then
        return 1
    fi

    stage_dir="${stage_root}/tree"
    mkdir -p "${stage_dir}"
    if ! tar -xzf "${stage_root}/snapshot.tar.gz" -C "${stage_dir}" --strip-components 1 2>/dev/null; then
        return 1
    fi
    if ! assets_complete "${stage_dir}"; then
        return 1
    fi
    install_from_stage "${stage_dir}"
    return 0
}

main() {
    mkdir -p "${MAKE_DIR}"

    if [[ -n "${SWIFT_MK_DEV_DIR}" ]]; then
        return 0
    fi

    if [[ "${SWIFT_MK_SKIP_FETCH:-}" == "1" ]]; then
        if assets_complete "${MAKE_DIR}"; then
            return 0
        fi
        printf '%s\n' "error: SWIFT_MK_SKIP_FETCH=1 but .make is missing a required asset" >&2
        return 1
    fi

    if provision; then
        return 0
    fi

    printf '%s\n' "error: could not provision the swift-makefile engine snapshot. Set SWIFT_MK_DEV_DIR, or check network access to ${SWIFT_MK_CODELOAD_BASE}" >&2
    return 1
}

reexec_from_temp_copy "$@"
main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter helperColdProvision && swift test --filter helperLeavesSnapshotIntact`
Expected: PASS, both.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/swift-mk-bootstrap.sh
git add scripts/swift-mk-bootstrap.sh Tests/SwiftMkCoreTests/BootstrapFetchTests.swift
git commit -S -m "Add swift-mk-bootstrap.sh with staged provisioning and a self-replacement guard

Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 3: Conditional validation, marker state, bounded reuse, and the CI rule

**Files:**
- Modify: `scripts/swift-mk-bootstrap.sh`
- Modify: `Tests/SwiftMkCoreTests/BootstrapFetchTests.swift`

**Interfaces:**
- Consumes: everything from Task 2.
- Produces:
  - `.make/.swift-mk-snapshot-ref` with exactly three lines: `ref=<value>`, `etag=<value>`, `timestamp=<unix seconds>`.
  - Shell functions `current_epoch_seconds`, `read_marker_field`, `write_marker`, `validate_upstream`, `marker_is_recent`, `format_age`, `serve_from_disk_with_warning`, and `running_in_ci`.
  - A warning on stderr containing the exact phrase `serving the .make snapshot validated`.
  - `func readMarker(_ directory: String) -> [String: String]` and `func writeMarker(_ directory: String, ref: String, etag: String, timestamp: Int) throws` in `BootstrapFetchTests.swift`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SwiftMkCoreTests/BootstrapFetchTests.swift`.

```swift
func readMarker(_ directory: String) -> [String: String] {
  guard let body = readMakeFile(directory, ".swift-mk-snapshot-ref") else {
    return [:]
  }
  var fields: [String: String] = [:]
  for line in body.split(separator: "\n") {
    let parts = line.split(separator: "=", maxSplits: 1)
    if parts.count == 2 {
      fields[String(parts[0])] = String(parts[1])
    }
  }
  return fields
}

func writeMarker(_ directory: String, ref: String, etag: String, timestamp: Int) throws {
  try writeMakeFile(
    directory, ".swift-mk-snapshot-ref", "ref=\(ref)\netag=\(etag)\ntimestamp=\(timestamp)\n")
}

/// Populates .make with a complete engine tree so only the validation decision
/// is under test.
func warmSnapshot(_ directory: String) throws {
  for (name, body) in engineFiles() where name != "scripts/swift-mk-bootstrap.sh" {
    try writeMakeFile(directory, name, body)
  }
}

@Test
func helperRecordsMarkerWithEtagOnColdProvision() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status == 0, result.stderr)

  let marker = readMarker(directory)
  #expect(marker["ref"] == "main")
  #expect(marker["etag"]?.isEmpty == false)
  #expect(Int(marker["timestamp"] ?? "") != nil)
}

@Test
func helperTouchesNothingWhenUpstreamReturnsNotModified() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()

  #expect(
    runHelper(directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
      .status == 0)

  let path = makePath(directory, "swift.mk")
  let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
  // A 304 must not re-extract, so the mtime must not move. Sleep past the
  // filesystem timestamp granularity so a re-extract would be detectable.
  Thread.sleep(forTimeInterval: 1.1)

  let second = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(second.status == 0, second.stderr)

  let after = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
  #expect(before == after, "a 304 re-extracted the tree and moved mtimes")

  let requests = server.requests()
  #expect(requests.count == 2)
  #expect(requests[1].status == 304)
  #expect(requests[1].bytes == 0)
}

@Test
func helperUnfreezesAMarkerThatHoldsOnlyARefName() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()
  try warmSnapshot(directory)
  // The format the current engine writes: a bare ref name, no ETag.
  try writeMakeFile(directory, ".swift-mk-snapshot-ref", "main\n")

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status == 0, result.stderr)

  #expect(server.requests().count == 1)
  #expect(server.requests()[0].status == 200, "a bare-ref marker must force a real fetch")
  #expect(readMarker(directory)["etag"]?.isEmpty == false)
}

@Test
func helperServesSnapshotWhenUpstreamStallsAndMarkerIsRecent() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()
  try warmSnapshot(directory)
  try writeMarker(
    directory, ref: "main", etag: "\"cached\"", timestamp: Int(Date().timeIntervalSince1970) - 600)
  server.stall(5)

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status == 0, result.stderr)
  #expect(result.stderr.contains("serving the .make snapshot validated"))
  #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v1\n")
}

@Test
func helperFailsWhenUpstreamStallsAndMarkerIsStale() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()
  try warmSnapshot(directory)
  try writeMarker(
    directory, ref: "main", etag: "\"cached\"", timestamp: Int(Date().timeIntervalSince1970) - 7200)
  server.stall(5)

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status != 0)
  #expect(!result.stderr.contains("serving the .make snapshot validated"))
  // Nothing may be destroyed even on the failing path.
  #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v1\n")
}

@Test
func helperProvisionsUnconditionallyInCI() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()
  try warmSnapshot(directory)
  try writeMarker(
    directory, ref: "main", etag: "\"cached\"", timestamp: Int(Date().timeIntervalSince1970))

  let result = runHelper(
    directory: directory,
    environment: [
      "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
      "GITHUB_ACTIONS": "true",
      "GITHUB_RUN_ID": "1",
    ])
  #expect(result.status == 0, result.stderr)
  #expect(server.requests().count == 1)
  #expect(server.requests()[0].ifNoneMatch.isEmpty, "CI sent a conditional request")
  #expect(server.requests()[0].status == 200)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter helper`
Expected: FAIL on `helperRecordsMarkerWithEtagOnColdProvision` because no marker is written, and on `helperTouchesNothingWhenUpstreamReturnsNotModified` because the helper re-extracts.

- [ ] **Step 3: Write minimal implementation**

Add these constants after `FETCH_MAX_TIME` in `scripts/swift-mk-bootstrap.sh`:

```bash
MARKER_PATH="${MAKE_DIR}/.swift-mk-snapshot-ref"
VALIDATION_CONNECT_TIMEOUT=2
VALIDATION_MAX_TIME=3
REUSE_WINDOW_SECONDS=3600
```

Add these functions above `provision`:

```bash
current_epoch_seconds() {
    if [[ -n "${EPOCHSECONDS:-}" ]]; then
        printf '%s' "${EPOCHSECONDS}"
        return 0
    fi
    date +%s
}

# read_marker_field returns one field of the marker. A marker holding only a
# bare ref name, which the previous engine wrote, has no fields, so every
# lookup fails and the caller takes the cold path. That is what unfreezes a
# consumer exactly once.
read_marker_field() {
    local field_name="$1"
    local line
    if [[ ! -s "${MARKER_PATH}" ]]; then
        return 1
    fi
    while IFS= read -r line; do
        if [[ "${line}" == "${field_name}="* ]]; then
            printf '%s' "${line#"${field_name}="}"
            return 0
        fi
    done < "${MARKER_PATH}"
    return 1
}

write_marker() {
    local etag_value="$1"
    {
        printf 'ref=%s\n' "${SWIFT_MK_API_REF}"
        printf 'etag=%s\n' "${etag_value}"
        printf 'timestamp=%s\n' "$(current_epoch_seconds)"
    } > "${MARKER_PATH}"
}

validate_upstream() {
    local destination_path="$1"
    local known_etag="$2"
    local status_code
    local -a header_args=()
    if [[ -n "${known_etag}" ]]; then
        header_args=(-H "If-None-Match: ${known_etag}")
    fi
    if ! status_code=$(curl -sS \
        --connect-timeout "${VALIDATION_CONNECT_TIMEOUT}" \
        --max-time "${VALIDATION_MAX_TIME}" \
        "${header_args[@]}" \
        -o "${destination_path}" -w '%{http_code}' \
        "${SWIFT_MK_CODELOAD_BASE}/${SWIFT_MK_API_REPO}/tar.gz/${SWIFT_MK_API_REF}" 2>/dev/null); then
        return 1
    fi
    printf '%s' "${status_code}"
}

# marker_is_recent reports whether the recorded validation is inside the reuse
# window. A timestamp in the future, which a backwards clock produces, is not
# recent, so a bad clock forces a real fetch rather than an unbounded serve.
marker_is_recent() {
    local recorded
    local now
    if ! recorded=$(read_marker_field "timestamp"); then
        return 1
    fi
    if [[ ! "${recorded}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    now=$(current_epoch_seconds)
    if (( recorded > now )); then
        return 1
    fi
    (( now - recorded <= REUSE_WINDOW_SECONDS ))
}

format_age() {
    local seconds="$1"
    if (( seconds < 60 )); then
        printf '%ds' "${seconds}"
        return 0
    fi
    printf '%dm' "$(( seconds / 60 ))"
}

serve_from_disk_with_warning() {
    local recorded
    local etag_value
    local now
    recorded=$(read_marker_field "timestamp")
    etag_value=$(read_marker_field "etag" || printf 'unknown')
    now=$(current_epoch_seconds)
    printf '%s\n' "swift-mk: upstream unreachable; serving the .make snapshot validated $(format_age $(( now - recorded ))) ago (etag ${etag_value}). Set SWIFT_MK_SKIP_FETCH=1 to silence, or check network access to ${SWIFT_MK_CODELOAD_BASE}" >&2
}

# running_in_ci matches the test Build.runsInlineGates already uses.
# GITHUB_ACTIONS alone is not a CI run.
running_in_ci() {
    [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${GITHUB_RUN_ID:-}" ]]
}
```

Record the `ETag` in `provision` by adding `-D "${stage_root}/headers"` to its curl call and, after `install_from_stage`, adding:

```bash
    write_marker "$(awk 'tolower($1) == "etag:" { print $2 }' "${stage_root}/headers" | tr -d '\r' | tail -n 1)"
```

Replace `main`'s fetch section with the decision table:

```bash
main() {
    local known_etag=""
    local status_code=""
    local probe_root

    mkdir -p "${MAKE_DIR}"

    if [[ -n "${SWIFT_MK_DEV_DIR}" ]]; then
        return 0
    fi

    if [[ "${SWIFT_MK_SKIP_FETCH:-}" == "1" ]]; then
        if assets_complete "${MAKE_DIR}"; then
            return 0
        fi
        printf '%s\n' "error: SWIFT_MK_SKIP_FETCH=1 but .make is missing a required asset" >&2
        return 1
    fi

    if ! running_in_ci && assets_complete "${MAKE_DIR}"; then
        known_etag=$(read_marker_field "etag" || printf '')
    fi

    if [[ -n "${known_etag}" ]]; then
        probe_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-mk-probe.XXXXXXXX") || return 1
        status_code=$(validate_upstream "${probe_root}/snapshot.tar.gz" "${known_etag}" || printf '')
        rm -rf "${probe_root}"
        if [[ "${status_code}" == "304" ]]; then
            # Deliberately no marker write. The reuse window is a fixed hour
            # from the last real download, not a window a successful check can
            # slide forward, and a 304 must leave .make byte-for-byte alone.
            return 0
        fi
    fi

    if ! running_in_ci && [[ -n "${known_etag}" && -z "${status_code}" ]] && marker_is_recent; then
        serve_from_disk_with_warning
        return 0
    fi

    if provision; then
        return 0
    fi

    printf '%s\n' "error: could not provision the swift-makefile engine snapshot. Set SWIFT_MK_DEV_DIR, or check network access to ${SWIFT_MK_CODELOAD_BASE}" >&2
    return 1
}
```

The `304` path writes nothing at all, which is what keeps the reuse window fixed and the `.make` tree untouched.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter helper`
Expected: PASS, all eight helper tests.

- [ ] **Step 5: Commit**

```bash
git add scripts/swift-mk-bootstrap.sh Tests/SwiftMkCoreTests/BootstrapFetchTests.swift
git commit -S -m "Validate the snapshot with a conditional request and bound offline reuse

Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 4: Fix the snapshot freeze in swift.mk

The free half. This reaches every consumer on its next parse with no pull request.

**Files:**
- Modify: `swift.mk:160-224`
- Modify: `scripts/swift-mk-sync.sh:43-92`
- Create: `Tests/SwiftMkCoreTests/SnapshotReuseTests.swift`

**Interfaces:**
- Consumes: the helper from Tasks 2 and 3, and `FetchServer`, `temporaryConsumer`, `writeMakeFile`, `readMakeFile`, `readMarker`, `engineFiles` from Tasks 1 and 2.
- Produces: `swift.mk` delegates to `.make/scripts/swift-mk-bootstrap.sh` when it exists, and `snapshot_extract` writes the three-line marker.

- [ ] **Step 1: Write the failing test**

Create `Tests/SwiftMkCoreTests/SnapshotReuseTests.swift`.

```swift
//
//  SnapshotReuseTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - SnapshotReuseTests

enum SnapshotReuseTests {}

@Test
func snapshotExtractWritesTheThreeFieldMarker() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()

  let script = repositoryRoot() + "/scripts/swift-mk-sync.sh"
  // cd explicitly rather than setting PWD: snapshot_extract resolves .make
  // relative to the working directory, and exporting PWD does not change it.
  let command = #"cd "${WORK_DIR}"; source "${SCRIPT_PATH}"; snapshot_extract"#
  let result = Shell.run(
    "/bin/bash", ["-c", command],
    environment: [
      "SCRIPT_PATH": script,
      "WORK_DIR": directory,
      "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
      "SWIFT_MK_API_REPO": "agoodkind/swift-makefile",
      "SWIFT_MK_API_REF": "main",
      "SWIFT_MK_DEV_DIR": "",
    ])
  #expect(result.status == 0, result.stderr)

  let marker = readMarker(directory)
  #expect(marker["ref"] == "main", "marker must carry a ref field, not a bare ref name")
  #expect(marker["etag"]?.isEmpty == false, "marker must carry the content ETag")
}

@Test
func snapshotIsNotConsideredCurrentWithoutAnEtag() throws {
  let directory = try temporaryConsumer()
  try writeMakeFile(directory, "Package.swift", "// warm\n")
  // The bare ref name the previous engine wrote. It must not count as current,
  // because a branch ref always equals itself and the consumer would freeze.
  try writeMakeFile(directory, ".swift-mk-snapshot-ref", "main\n")

  let marker = readMarker(directory)
  #expect(marker["etag"] == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter snapshot`
Expected: FAIL on `snapshotExtractWritesTheThreeFieldMarker`, because `snapshot_extract` writes a bare ref name.

- [ ] **Step 3: Write minimal implementation**

In `scripts/swift-mk-sync.sh`, make the codeload base overridable and write the new marker. Replace the curl call and the marker write inside `snapshot_extract`:

```bash
    local codeload_base="${SWIFT_MK_CODELOAD_BASE:-https://codeload.github.com}"
    local etag_value
    if command -v gh >/dev/null 2>&1 \
        && gh api "repos/${SWIFT_MK_API_REPO}/tarball/${SWIFT_MK_API_REF}" > "${temp_dir}/snapshot.tar.gz" 2>/dev/null \
        && [[ -s "${temp_dir}/snapshot.tar.gz" ]]; then
        ok=1
    elif curl -fsSL --connect-timeout 5 --max-time 60 \
        -D "${temp_dir}/headers" \
        "${codeload_base}/${SWIFT_MK_API_REPO}/tar.gz/${SWIFT_MK_API_REF}" \
        -o "${temp_dir}/snapshot.tar.gz" \
        && [[ -s "${temp_dir}/snapshot.tar.gz" ]]; then
        ok=1
    fi
```

and replace the marker write:

```bash
    etag_value=$(awk 'tolower($1) == "etag:" { print $2 }' "${temp_dir}/headers" 2>/dev/null | tr -d '\r' | tail -n 1)
    {
        printf 'ref=%s\n' "${SWIFT_MK_API_REF}"
        printf 'etag=%s\n' "${etag_value}"
        printf 'timestamp=%s\n' "${EPOCHSECONDS:-$(date +%s)}"
    } > "${make_dir}/.swift-mk-snapshot-ref"
```

In `swift.mk`, replace the `SWIFT_MK_SNAPSHOT_CURRENT` computation and the snapshot block at lines 217-224 so the helper owns the decision once it is present:

```makefile
# The engine snapshot is current only when the marker carries the ETag the
# helper recorded and the extracted package is present. The previous check
# compared the marker to SWIFT_MK_API_REF, which for a branch pin is always
# equal, so a consumer never re-fetched and stayed frozen on its first commit.
SWIFT_MK_SNAPSHOT_HELPER := .make/scripts/swift-mk-bootstrap.sh
SWIFT_MK_SNAPSHOT_CURRENT := $(shell if [ -f .make/Package.swift ] && grep -q '^etag=..*' .make/.swift-mk-snapshot-ref 2>/dev/null; then printf 1; fi)

ifeq ($(SWIFT_MK_HELPER_DIR),$(SWIFT_MK_FETCHED_SCRIPT_DIR))
ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
SWIFT_MK_SNAPSHOT := $(call swift-mk-require-one,.make/Package.swift)
else ifneq ($(wildcard $(SWIFT_MK_SNAPSHOT_HELPER)),)
# The helper owns validation, reuse, and failure. It is fetched, so its policy
# reaches every consumer with no consumer-side change.
SWIFT_MK_SNAPSHOT := $(if $(filter ok,$(shell SWIFT_MK_MODULES="$(SWIFT_MK_MODULES)" bash "$(SWIFT_MK_SNAPSHOT_HELPER)" >&2 && printf ok)),,$(error swift-makefile failed to provision the engine snapshot))
else ifneq ($(strip $(SWIFT_MK_SNAPSHOT_CURRENT)),1)
# Cold path for a consumer whose .make predates the helper. It extracts once,
# which lands the helper, and every later parse takes the branch above.
SWIFT_MK_SNAPSHOT := $(call swift_mk_snapshot)
endif
endif
```

Update `_swift_mk_snapshot_commands` at `swift.mk:182` to write the same three-line marker as `snapshot_extract`, so both writers agree:

```makefile
	printf 'ref=%s\netag=%s\ntimestamp=%s\n' "$(SWIFT_MK_API_REF)" "$$(awk 'tolower($$1) == "etag:" { print $$2 }' "$$tmp/headers" 2>/dev/null | tr -d '\r' | tail -n 1)" "$$(date +%s)" > .make/.swift-mk-snapshot-ref; \
```

and add `-D "$$tmp/headers"` to its curl fallback.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter snapshot`
Expected: PASS, both tests.

- [ ] **Step 5: Commit**

```bash
git add swift.mk scripts/swift-mk-sync.sh Tests/SwiftMkCoreTests/SnapshotReuseTests.swift
git commit -S -m "Key the snapshot marker by content ETag so a consumer tracks main again

Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 5: Take the configs and modules from the snapshot

**Files:**
- Modify: `swift.mk:285-312`
- Modify: `Tests/SwiftMkCoreTests/SnapshotReuseTests.swift`

**Interfaces:**
- Consumes: `SWIFT_MK_SNAPSHOT_CURRENT` from Task 4.
- Produces: `swift.mk` copies the five renamed configs from the extracted snapshot rather than fetching them.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SwiftMkCoreTests/SnapshotReuseTests.swift`.

```swift
@Test
func warmParseTakesConfigsFromTheSnapshotWithNoNetwork() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()

  // Cold provision lands the snapshot, including the engine's own dotfile
  // configs, and the helper.
  let cold = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(cold.status == 0, cold.stderr)
  #expect(readMakeFile(directory, ".swiftlint.yml") == "# swiftlint v1\n")

  // The renamed targets must be copies of those snapshot files.
  let mapping = [
    (".swiftlint.yml", "swiftlint.yml"),
    (".swift-format", "swift-format.json"),
    (".periphery.yml", "periphery.yml"),
  ]
  for (source, target) in mapping {
    let sourceBody = readMakeFile(directory, source)
    let targetBody = readMakeFile(directory, target)
    #expect(
      sourceBody == targetBody,
      "\(target) should be a copy of \(source), got \(String(describing: targetBody))")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter warmParseTakesConfigs`
Expected: FAIL, because nothing creates `.make/swiftlint.yml` from `.make/.swiftlint.yml`.

- [ ] **Step 3: Write minimal implementation**

Add the copy step to `scripts/swift-mk-bootstrap.sh`, called at the end of `install_from_stage` and also on the `304` and reuse paths so a warm parse converges. Add above `install_from_stage`:

```bash
# The snapshot already carries the engine's own config dotfiles, so the renamed
# targets swift.mk expects are local copies rather than five network fetches.
install_renamed_configs() {
    local pair
    local source_name
    local target_path
    for pair in \
        ".swiftlint.yml:${MAKE_DIR}/swiftlint.yml" \
        ".swift-format:${MAKE_DIR}/swift-format.json" \
        ".periphery.yml:${MAKE_DIR}/periphery.yml" \
        "osv-scanner.toml:${MAKE_DIR}/osv-scanner.toml" \
        "mise.toml:.config/mise/conf.d/swift-mk.toml"; do
        source_name="${pair%%:*}"
        target_path="${pair#*:}"
        if [[ ! -s "${MAKE_DIR}/${source_name}" ]]; then
            continue
        fi
        mkdir -p "$(dirname "${target_path}")"
        cp "${MAKE_DIR}/${source_name}" "${target_path}"
    done
}
```

Call it at the end of `install_from_stage`, and immediately before each `return 0` in `main` that follows a successful validation or reuse.

In `swift.mk`, take the fetch off the warm path. Replace the config block at lines 285-293:

```makefile
# The snapshot carries these configs, and the helper copies them into their
# renamed targets, so a warm parse performs no per-file fetch. The fetch below
# remains for dev-dir mode and for a snapshot that somehow lacks a file.
ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
SWIFT_MK_FETCHED_SWIFTLINT := $(call swift-mk-require-one,$(SWIFT_MK_SWIFTLINT_CONFIG))
SWIFT_MK_FETCHED_SWIFT_FORMAT := $(call swift-mk-require-one,$(SWIFT_MK_SWIFT_FORMAT_CONFIG))
SWIFT_MK_FETCHED_PERIPHERY := $(call swift-mk-require-one,$(SWIFT_MK_PERIPHERY_CONFIG))
else
SWIFT_MK_FETCHED_SWIFTLINT := $(if $(wildcard $(SWIFT_MK_SWIFTLINT_CONFIG)),,$(call swift-mk-fetch-path,.swiftlint.yml,$(SWIFT_MK_SWIFTLINT_CONFIG)))
SWIFT_MK_FETCHED_SWIFT_FORMAT := $(if $(wildcard $(SWIFT_MK_SWIFT_FORMAT_CONFIG)),,$(call swift-mk-fetch-path,.swift-format,$(SWIFT_MK_SWIFT_FORMAT_CONFIG)))
SWIFT_MK_FETCHED_PERIPHERY := $(if $(wildcard $(SWIFT_MK_PERIPHERY_CONFIG)),,$(call swift-mk-fetch-path,.periphery.yml,$(SWIFT_MK_PERIPHERY_CONFIG)))
endif
```

Apply the same `$(if $(wildcard ...))` guard to `SWIFT_MK_FETCHED_OSV` at lines 294-298 and to `SWIFT_MK_FETCHED_MODULES` at lines 235-239.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter warmParseTakesConfigs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add swift.mk scripts/swift-mk-bootstrap.sh Tests/SwiftMkCoreTests/SnapshotReuseTests.swift
git commit -S -m "Copy the renamed configs from the snapshot instead of refetching them

Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 6: Delegate from bootstrap.mk

**Files:**
- Modify: `bootstrap.mk:16-59`, `bootstrap.mk:152-158`
- Modify: `Tests/SwiftMkCoreTests/SnapshotReuseTests.swift`

**Interfaces:**
- Consumes: the helper contract from Tasks 2, 3, and 5.
- Produces: `bootstrap.mk` obtains `.make/scripts/swift-mk-bootstrap.sh`, runs it, and includes `.make/swift.mk`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SwiftMkCoreTests/SnapshotReuseTests.swift`.

```swift
/// Builds a temp repo shaped like a real consumer: its own Makefile that
/// includes the committed bootstrap.mk.
func consumerWithBootstrap() throws -> String {
  let directory = try temporaryConsumer()
  let bootstrap = try String(
    contentsOfFile: repositoryRoot() + "/bootstrap.mk", encoding: .utf8)
  try bootstrap.write(
    toFile: (directory as NSString).appendingPathComponent("bootstrap.mk"),
    atomically: true, encoding: .utf8)
  try "include bootstrap.mk\n".write(
    toFile: (directory as NSString).appendingPathComponent("Makefile"),
    atomically: true, encoding: .utf8)
  return directory
}

func runMake(directory: String, environment: [String: String]) -> (
  output: String, status: Int32
) {
  var merged: [String: String] = [
    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
    "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "",
    "GITHUB_ACTIONS": "",
    "GITHUB_RUN_ID": "",
    "SWIFT_MK_DEV_DIR": "",
  ]
  for (key, value) in environment {
    merged[key] = value
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/make")
  process.arguments = ["-n", "help"]
  process.currentDirectoryURL = URL(fileURLWithPath: directory)
  process.environment = merged
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try? process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (String(decoding: data, as: UTF8.self), process.terminationStatus)
}

@Test
func warmParseIssuesExactlyOneRequest() throws {
  var files = engineFiles()
  files["swift.mk"] = "help:\n\t@printf 'stub help\\n'\n"
  let server = try FetchServer(files: files)
  defer { server.shutdown() }
  let directory = try consumerWithBootstrap()

  let cold = runMake(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(cold.status == 0, cold.output)
  let coldCount = server.requests().count

  let warm = runMake(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(warm.status == 0, warm.output)

  let warmRequests = Array(server.requests().dropFirst(coldCount))
  #expect(warmRequests.count == 1, "a warm parse issued \(warmRequests.count) requests, want 1")
  #expect(warmRequests[0].status == 304)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter warmParseIssuesExactlyOneRequest`
Expected: FAIL, because today's `bootstrap.mk` fetches `swift.mk` unconditionally, so a warm parse issues at least two requests.

- [ ] **Step 3: Write minimal implementation**

In `bootstrap.mk`, replace the `_swift_mk_fetch` define at lines 16-59 with the helper acquisition, and replace the fetch invocation at lines 152-156.

```makefile
SWIFT_MK_BOOTSTRAP := .make/scripts/swift-mk-bootstrap.sh
# The helper URL follows SWIFT_MK_API_REF so a ref-pinned consumer gets that
# ref's helper. SWIFT_MK_BASE_URL ends in /main and would pin it to main.
SWIFT_MK_BOOTSTRAP_URL := https://raw.githubusercontent.com/$(SWIFT_MK_API_REPO)/$(SWIFT_MK_API_REF)/scripts/swift-mk-bootstrap.sh

# Obtaining the helper is the only fetch rule left in consumer-committed code.
# It never removes an existing helper, so a warm checkout stays usable with no
# network, and only a cold offline start fails here.
define _swift_mk_get_bootstrap
	set -euo pipefail; \
	if [[ -n "$(SWIFT_MK_DEV_DIR)" && -f "$(SWIFT_MK_DEV_DIR)/scripts/swift-mk-bootstrap.sh" ]]; then \
		mkdir -p .make/scripts; \
		cp "$(SWIFT_MK_DEV_DIR)/scripts/swift-mk-bootstrap.sh" "$(SWIFT_MK_BOOTSTRAP)"; \
	elif [[ -s "$(SWIFT_MK_BOOTSTRAP)" ]]; then \
		: ; \
	else \
		mkdir -p .make/scripts; \
		tmp_file=$$(mktemp "$(SWIFT_MK_BOOTSTRAP).tmp.XXXXXX"); \
		trap "rm -f \"$$tmp_file\"" EXIT; \
		if curl -fsSL --connect-timeout 5 --max-time 10 "$(SWIFT_MK_BOOTSTRAP_URL)" -o "$$tmp_file" && [[ -s "$$tmp_file" ]]; then \
			mv "$$tmp_file" "$(SWIFT_MK_BOOTSTRAP)"; \
		else \
			printf "%s\n" "error: could not obtain $(SWIFT_MK_BOOTSTRAP); check network access to raw.githubusercontent.com" >&2; \
			exit 1; \
		fi; \
	fi; \
	chmod +x "$(SWIFT_MK_BOOTSTRAP)"
endef
```

Replace the fetch invocation:

```makefile
ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
$(if $(wildcard $(SWIFT_MK_BOOTSTRAP)),,$(error swift-makefile expected $(SWIFT_MK_BOOTSTRAP); rerun without SWIFT_MK_SKIP_FETCH))
else
$(if $(filter ok,$(shell /usr/bin/env bash -c 'mkdir -p .make && $(call _swift_mk_get_bootstrap) && printf ok')),,$(error swift-makefile failed to obtain $(SWIFT_MK_BOOTSTRAP)))
endif

# The helper provisions the whole engine snapshot and owns validation, reuse,
# and failure.
$(if $(filter ok,$(shell SWIFT_MK_MODULES="$(SWIFT_MK_MODULES)" bash "$(SWIFT_MK_BOOTSTRAP)" >&2 && printf ok)),,$(error swift-makefile failed to provision the engine snapshot))
```

Leave `swift_mk_trace_min` at lines 70-150 untouched. It is self-contained, needs no fetch, and must print before any other work.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter warmParseIssuesExactlyOneRequest`
Expected: PASS.

Then run the whole suite: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.mk Tests/SwiftMkCoreTests/SnapshotReuseTests.swift
git commit -S -m "Delegate fetch policy from bootstrap.mk to swift-mk-bootstrap.sh

Co-authored-by: Claude <noreply@anthropic.com>"
```

---

### Task 7: Document the fetch contract

**Files:**
- Modify: `docs/fetch/overview.md`

**Interfaces:**
- Consumes: the behavior built in Tasks 2 through 6.
- Produces: nothing code depends on.

- [ ] **Step 1: Rewrite the affected sections**

In `docs/fetch/overview.md`, replace the "Bootstrap source" and "The engine snapshot" sections with the current behavior, and add the reuse rule. Keep the "Dev-dir mode" and "Fetch-path smoke test" sections as they are.

```markdown
## Bootstrap source

`bootstrap.mk` obtains one helper script, `.make/scripts/swift-mk-bootstrap.sh`,
runs it, and includes `swift.mk`. It reads `SWIFT_MK_DEV_DIR` first, so a
consumer can test a local engine checkout without changing the committed file.

Fetch policy lives in the helper rather than in `bootstrap.mk`, so a change to
how the snapshot is validated or reused reaches every consumer on its next parse
without a consumer change. Obtaining the helper never removes an existing copy,
so a warm checkout stays usable when the network is gone.

## The engine snapshot

The helper fetches the whole engine as one snapshot and extracts it into `.make`
with `tar --strip-components=1`, so the tree lands flat and becomes a real
SwiftPM package. The extract is staged: it verifies the required assets in a
temporary tree and only then replaces the tree under `.make`, preserving
`.make/logs`, the build lock, the built binary, and the dev symlinks.

The renamed configs (`swiftlint.yml`, `swift-format.json`, `periphery.yml`,
`osv-scanner.toml`, and the mise config) are copied from that same snapshot, so
a warm parse performs no per-file fetch.

## Upstream is consulted on every parse

The helper sends one conditional request carrying the `ETag` it recorded last
time. A `304` means the extracted tree is byte-identical to upstream, so nothing
is transferred and no file under `.make` is touched, which keeps mtimes stable
and the tool-binary staleness guard quiet. A `200` carries a new tree.

The marker at `.make/.swift-mk-snapshot-ref` records the ref, that `ETag`, and
the time of the last successful validation. Keying on content rather than on the
ref name is what lets a consumer tracking `main` pick up an engine change on its
next parse.

## Reuse after a failed validation is bounded

When the conditional request does not complete, the helper serves the existing
snapshot if the last successful validation was within the past hour, and prints
one warning naming the recorded `ETag` and its age. Past that window it forces a
real fetch and fails loudly rather than compiling against engine sources it can
no longer vouch for.

## CI always fetches

Under a real GitHub Actions run, meaning `GITHUB_ACTIONS` is `true` and
`GITHUB_RUN_ID` is set, the helper ignores the marker, sends no conditional
request, and provisions unconditionally.
```

- [ ] **Step 2: Verify the claims against the code**

Run: `make test`
Expected: PASS. Then reread the document beside `scripts/swift-mk-bootstrap.sh` and confirm each stated behavior has a test.

- [ ] **Step 3: Commit**

```bash
git add docs/fetch/overview.md
git commit -S -m "Document the snapshot validation and reuse rules

Co-authored-by: Claude <noreply@anthropic.com>"
```

---

## Rollout after the plan completes

1. Merge. Every consumer picks up the helper, the freeze fix, the validated reuse, and the config copies on its next parse with no pull request, because `swift.mk` and the scripts are fetched.
2. Expect one re-extract per consumer on that first parse, because their markers hold a bare ref name. That is the intended unfreeze and moves each consumer to current `main`, so merge this when the engine is known good rather than alongside other risky changes.
3. Run `update-consumers` so each repo takes the new `bootstrap.mk`, then review and merge those pull requests. This is the round that lets a warm consumer parse offline.
4. Later, once every consumer has migrated, remove the superseded `swift_mk_snapshot` and per-file fetch machinery from `swift.mk`.
