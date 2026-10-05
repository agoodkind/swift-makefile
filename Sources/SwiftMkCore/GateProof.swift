//
//  GateProof.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-14.
//  Copyright © 2026, all rights reserved.
//

import Foundation

#if canImport(Darwin)
  import Darwin
#endif

// MARK: - GateProof

/// Proof that a compile runs inside a swift-mk gated invocation.
///
/// `swift-mk build` runs the lint gates, then the build command of the consumer.
/// A compile subcommand run directly does not run the gates. An environment
/// variable cannot serve as the proof, because any process can set it. The proof
/// has three factors:
///
///   A. Freshness: a gated entry writes `.make/.gate/stamp` with its creation
///      time, and the verifier rejects a stamp older than the window. The stamp
///      also records a source digest. The verifier does not check the digest,
///      because code generation during a build can change a tracked source.
///   B. Live ancestor: the stamp records the pid of the anchor process. The
///      verifier requires that pid in its own ancestry, and requires the process
///      to be `make`, `gmake`, or `swift-mk`.
///   C. Process identity: the stamp records the start time of the anchor, and the
///      verifier requires the live ancestor to have that start time. A new process
///      that reuses the pid does not match. The stamp records the start time
///      because Foundation process spawning does not pass an inherited file
///      descriptor, and Foundation caches the environment.
///
/// The proof does not resist a deliberate bypass on a single-user machine. It does
/// not cover a `swift build` run by hand in a shell.
public enum GateProof {
  static let stampRelativeComponents = [".make", ".gate", "stamp"]

  /// The window is long because a build can run for a long time. Factor B rejects
  /// a stamp after its anchor process exits.
  static let freshnessWindowSeconds: Double = 3_600

  /// `EX_SOFTWARE` in sysexits.h.
  static let refusedExitStatus: Int32 = 70

  /// The ancestry walk stops at this depth on a pid cycle.
  static let maxAncestorDepth = 64

  static let nonceByteCount = 16

  static let microsecondsPerSecond: Double = 1_000_000

  // MARK: Producer

  /// Each gated entry calls mark at its start. A second call in the same process
  /// returns without writing, and a nested gate does not rewrite the stamp. A gated
  /// entry returns before the compile when a gate fails.
  public static func mark(context: PathContext = .current()) {
    let myPid = currentPid()
    if markedPid == myPid {
      return
    }
    markedPid = myPid

    // One `make` invocation runs several compiles as separate children, and the
    // gated `swift-mk build` child exits before a later metallib or install step.
    // The outermost `make` stays alive and is an ancestor of each of those
    // compiles. Without a `make` ancestor, the anchor is this process.
    let anchor = outermostMakeAncestor() ?? myPid
    let stamp = Stamp(
      nonce: randomNonce(),
      sourceHash: sourceDigest(context: context),
      gatePid: anchor,
      gateStartTime: processStartTime(of: anchor) ?? 0,
      createdAt: nowSeconds())
    writeStamp(stamp, context: context)
  }

  // MARK: Verifier

  /// Prints the cause and returns `refusedExitStatus` when no gate proof covers this
  /// process. Returns nil otherwise. The caller exits with the returned status.
  public static func refusal(entry: String, context: PathContext = .current()) -> Int32? {
    if isGated(context: context) {
      return nil
    }
    Output.error(
      "\(entry): refused. This compile did not run inside the swift-mk lint gate, "
        + "so it would produce an ungated artifact. Run `make build` (it runs "
        + "log-audit, swift-format, swiftlint, complexity, periphery, then this "
        + "compile). Invoking the dev tool's compile subcommand directly, or "
        + "`swift-mk toolchain build` outside `make build`, bypasses the gate and "
        + "is refused.")
    return refusedExitStatus
  }

  /// A consumer build command reads this value to choose a path: the make path,
  /// which `Toolchain.build` checks with this proof, or `GatedBuild.run`, which runs
  /// the hard gate. Each path checks its own authorization.
  public static func isCurrentlyGated(context: PathContext = .current()) -> Bool {
    isGated(context: context)
  }

  /// Checks factors A, B, and C. `refusal` adds the message and the status.
  static func isGated(context: PathContext = .current()) -> Bool {
    guard let stamp = readStamp(context: context) else {
      return false
    }
    // (A) Freshness.
    guard nowSeconds() - stamp.createdAt <= freshnessWindowSeconds else {
      return false
    }
    // (B) Live anchor in the ancestry of this process.
    guard ancestorPids().contains(stamp.gatePid), processIsGateAnchor(stamp.gatePid) else {
      return false
    }
    // (C) Start time. A stored start time of 0 means the gate could not read it,
    // and the check is skipped.
    if stamp.gateStartTime != 0 {
      guard processStartTime(of: stamp.gatePid) == stamp.gateStartTime else {
        return false
      }
    }
    return true
  }

  // MARK: Diagnostics

  /// `gate-proof probe` prints this line, with one field for each factor.
  public static func probeReport(context: PathContext = .current()) -> String {
    guard let stamp = readStamp(context: context) else {
      return "gated=false reason=no-stamp"
    }
    let fresh = nowSeconds() - stamp.createdAt <= freshnessWindowSeconds
    let sourceMatch = stamp.sourceHash == sourceDigest(context: context)
    let ancestor = ancestorPids().contains(stamp.gatePid)
    let anchor = processIsGateAnchor(stamp.gatePid)
    let startMatch =
      stamp.gateStartTime == 0
      || processStartTime(of: stamp.gatePid) == stamp.gateStartTime
    // The verdict does not include the source digest, as in `isGated`.
    let gated = fresh && ancestor && anchor && startMatch
    return
      "gated=\(gated) fresh=\(fresh) source=\(sourceMatch) ancestor=\(ancestor) "
      + "anchor=\(anchor) startMatch=\(startMatch) anchorPid=\(stamp.gatePid)"
  }

  /// Marks this process, runs `gate-proof probe` in a child process of the same
  /// binary, and returns the report line of the child.
  public static func selftest(context: PathContext = .current()) -> String {
    mark(context: context)
    let selfPath = currentExecutablePath()
    guard !selfPath.isEmpty else {
      return "gated=false reason=no-self-path"
    }
    Output.debug("gate-proof: selftest spawning probe child at \(selfPath)")
    let result = Shell.run(selfPath, ["gate-proof", "probe"])
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Stamp model

  struct Stamp: Equatable {
    let nonce: String
    let sourceHash: String
    let gatePid: Int32
    let gateStartTime: Double
    let createdAt: Double

    func serialized() -> String {
      [
        "nonce=\(nonce)",
        "sourceHash=\(sourceHash)",
        "gatePid=\(gatePid)",
        "gateStartTime=\(gateStartTime)",
        "createdAt=\(createdAt)",
      ].joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String) -> Stamp? {
      var fields: [String: String] = [:]
      for line in text.split(separator: "\n") {
        guard let equals = line.firstIndex(of: "=") else {
          continue
        }
        let key = String(line[..<equals])
        let value = String(line[line.index(after: equals)...])
        fields[key] = value
      }
      guard let parsedNonce = fields["nonce"], !parsedNonce.isEmpty,
        let parsedHash = fields["sourceHash"], !parsedHash.isEmpty,
        let pidText = fields["gatePid"], let parsedPid = Int32(pidText),
        let startText = fields["gateStartTime"], let parsedStart = Double(startText),
        let createdText = fields["createdAt"], let parsedCreated = Double(createdText)
      else {
        return nil
      }
      return Stamp(
        nonce: parsedNonce,
        sourceHash: parsedHash,
        gatePid: parsedPid,
        gateStartTime: parsedStart,
        createdAt: parsedCreated)
    }
  }

  static func stampURL(context: PathContext) -> URL {
    var url = URL(fileURLWithPath: context.cwd, isDirectory: true)
    for component in stampRelativeComponents {
      url = url.appendingPathComponent(component)
    }
    return url
  }

  private static func writeStamp(_ stamp: Stamp, context: PathContext) {
    let url = stampURL(context: context)
    let directory = url.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      try stamp.serialized().write(to: url, atomically: true, encoding: .utf8)
    } catch {
      Output.error("gate-proof: could not write stamp at \(url.path): \(error)")
    }
  }

  static func readStamp(context: PathContext) -> Stamp? {
    let url = stampURL(context: context)
    let text: String
    do {
      text = try String(contentsOf: url, encoding: .utf8)
    } catch {
      // A missing stamp is the usual case when no gate ran.
      return nil
    }
    return Stamp.parse(text)
  }

  // MARK: Process ancestry (Darwin)

  static func ancestorPids() -> [Int32] {
    var chain: [Int32] = []
    var pid = currentPid()
    var guardCount = 0
    while pid > 1, guardCount < maxAncestorDepth {
      chain.append(pid)
      let parent = parentPid(of: pid)
      if parent <= 0 || parent == pid {
        break
      }
      pid = parent
      guardCount += 1
    }
    return chain
  }

  #if canImport(Darwin)
    static func parentPid(of pid: Int32) -> Int32 {
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
      guard result == 0, size > 0 else {
        return -1
      }
      return info.kp_eproc.e_ppid
    }

    /// Returns an empty string for a dead pid.
    static func processName(of pid: Int32) -> String {
      var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
      guard length > 0 else {
        return ""
      }
      return (String(cString: pathBuffer) as NSString).lastPathComponent
    }

    static func processStartTime(of pid: Int32) -> Double? {
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
        return nil
      }
      let started = info.kp_proc.p_un.__p_starttime
      return Double(started.tv_sec) + Double(started.tv_usec) / microsecondsPerSecond
    }
  #else
    static func parentPid(of _: Int32) -> Int32 { -1 }
    static func processName(of _: Int32) -> String { "" }
    static func processStartTime(of _: Int32) -> Double? { nil }
  #endif

  /// A long-lived ancestor such as the login shell is not an anchor.
  static func processIsGateAnchor(_ pid: Int32) -> Bool {
    switch processName(of: pid) {
    case "make", "gmake", "swift-mk":
      return true
    default:
      return false
    }
  }

  /// A recursive sub-make for one build step exits before the later install step
  /// of the top-level `make deploy`. The anchor is the outermost `make`.
  static func outermostMakeAncestor() -> Int32? {
    var result: Int32?
    for pid in ancestorPids() {
      let name = processName(of: pid)
      if name == "make" || name == "gmake" {
        result = pid
      }
    }
    return result
  }

  // MARK: Primitives

  private static func currentPid() -> Int32 {
    getpid()
  }

  static func currentExecutablePath() -> String {
    #if canImport(Darwin)
      var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      let length = proc_pidpath(getpid(), &pathBuffer, UInt32(pathBuffer.count))
      if length > 0 {
        return String(cString: pathBuffer)
      }
    #endif
    return CommandLine.arguments.first ?? ""
  }

  private static func nowSeconds() -> Double {
    Date().timeIntervalSince1970
  }

  private static func randomNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: nonceByteCount)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  nonisolated(unsafe) private static var markedPid: Int32 = -1
}

// MARK: - Source digest

/// `BuildFreshness` calls these functions and uses the same file set.
extension GateProof {
  static let sourceExtensions: Set<String> = ["swift", "mk", "h", "m", "c", "metal"]

  /// `.derived-data` is the default DerivedData path of the engine. Excluding it
  /// keeps the Swift files a build generates under DerivedSources out of the digest.
  /// Keep this set equal to the prune list of the freshness inputs in swift-build.mk.
  static let digestExcludedDirectories: Set<String> = [
    ".git", ".build", ".make", ".derived-data", "DerivedData", "Derived",
    "Products", "SourcePackages", "node_modules", ".swiftpm", "build", ".tuist",
    "Pods",
  ]

  /// The walk order is unspecified; a caller sorts its own entries. Returns false
  /// when the enumerator cannot be created, and the caller then returns "empty".
  @discardableResult
  static func forEachTrackedSource(
    context: PathContext,
    _ body: (_ relativePath: String, _ url: URL) -> Void
  ) -> Bool {
    let root = URL(fileURLWithPath: context.cwd, isDirectory: true)
    let rootPath = root.standardizedFileURL.path
    let manager = FileManager.default
    guard
      let enumerator = manager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else {
      return false
    }
    for case let item as URL in enumerator {
      var isDirectory = false
      do {
        isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
      } catch {
        // An entry that cannot be read is treated as a file.
        Output.warning("gate-proof: could not stat \(item.path) for directory check: \(error)")
      }
      if isDirectory {
        if digestExcludedDirectories.contains(item.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }
      guard sourceExtensions.contains(item.pathExtension) else {
        continue
      }
      let path = item.standardizedFileURL.path
      let relative =
        path.hasPrefix(rootPath + "/")
        ? String(path.dropFirst(rootPath.count + 1)) : path
      body(relative, item)
    }
    return true
  }

  /// Digest of the path, size, and modification time of each tracked source file.
  /// The function does not read file contents. `isGated` does not check this digest.
  static func sourceDigest(context: PathContext) -> String {
    var entries: [String] = []
    let started = forEachTrackedSource(context: context) { relative, url in
      let values: URLResourceValues?
      do {
        values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      } catch {
        // An unreadable file adds an entry with size 0 and time 0.
        Output.warning("gate-proof: skipping unreadable source \(url.path): \(error)")
        values = nil
      }
      let size = values?.fileSize ?? 0
      let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
      entries.append("\(relative)\u{0}\(size)\u{0}\(mtime)")
    }
    guard started else {
      return "empty"
    }
    entries.sort()
    return fnv1aHex(entries.joined(separator: "\n"))
  }

  static let fnv1aOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325

  static let fnv1aPrime: UInt64 = 0x0000_0100_0000_01b3

  /// FNV-1a is not a cryptographic hash. The digest detects a source change and is
  /// not a security boundary.
  static func fnv1aHex(_ text: String) -> String {
    var hash = fnv1aOffsetBasis
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* fnv1aPrime
    }
    return String(format: "%016llx", hash)
  }

  /// Reads the file in chunks of `fileDigestChunkBytes`. Returns "unreadable" when
  /// the file cannot be opened or read. No hex digest equals that string.
  static func fnv1aHexOfFile(at url: URL) -> String {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      return "unreadable"
    }
    defer {
      do {
        try handle.close()
      } catch {
        Output.warning("gate-proof: could not close \(url.path): \(error)")
      }
    }
    var hash = fnv1aOffsetBasis
    while true {
      let chunk: Data?
      do {
        chunk = try handle.read(upToCount: fileDigestChunkBytes)
      } catch {
        return "unreadable"
      }
      guard let chunk, !chunk.isEmpty else {
        break
      }
      for byte in chunk {
        hash ^= UInt64(byte)
        hash = hash &* fnv1aPrime
      }
    }
    return String(format: "%016llx", hash)
  }

  static let fileDigestChunkBytes = 1 << 16
}
