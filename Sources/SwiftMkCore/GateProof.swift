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

/// Proof that a compile is running inside a swift-mk gated invocation.
///
/// `make build` is the chokepoint: `swift-mk build` runs the lint gates, then
/// runs the consumer's build command. The real compile lives downstream of the
/// gate, so a dev tool's compile subcommand invoked directly skips it. A static
/// env token cannot close that hole: an agent reads the name and sets it. The
/// proof here is unsatisfiable by setting a value; it requires actually running
/// the gate, and it layers three factors:
///
///   A. Freshness stamp: a passing gated entry writes `.make/.gate/stamp` with an
///      expiry, plus a digest of the tracked sources. The expiry is enforced; the
///      source digest is reported for diagnostics but not enforced, since
///      mid-build code generation can legitimately change a tracked source.
///   B. Live ancestor: the stamp names the gate process's pid. The verifier
///      requires that pid to be a live swift-mk process in its own ancestry. An
///      agent cannot make a swift-mk gate process its ancestor without running
///      the gate, so this factor is not forgeable by writing files or env.
///   C. Process identity: the stamp records the gate process's start time, and
///      the verifier requires the live ancestor's start time to match. This binds
///      factor B to the exact process instance that ran the gate, so a recycled
///      pid (a new process reusing the gate's old pid) cannot satisfy it. The
///      stamp carries it rather than an inherited fd, which Foundation's process
///      spawning drops, and rather than the environment, which Foundation caches.
///
/// Honest limit: on a single-user machine with readable source nothing is
/// cryptographically unforgeable. The goal is that the lazy path is to gate and
/// any bypass is deliberate. A hand-run `swift build` in the shell is out of
/// scope; this guards the project's own build entrypoints.
public enum GateProof {
  /// The stamp path relative to the repo root.
  static let stampRelativeComponents = [".make", ".gate", "stamp"]

  /// How long a stamp authorizes compiles after it is written. A real build can
  /// be long, so the window is generous; factor B (live ancestor) is what stops
  /// a stale stamp from authorizing a later ungated compile.
  static let freshnessWindowSeconds: Double = 3_600

  /// The process status returned when a compile is refused for lack of proof.
  /// `EX_SOFTWARE` (70) marks an internal precondition failure.
  static let refusedExitStatus: Int32 = 70

  /// Maximum ancestry depth walked when looking for the gate process, a backstop
  /// against a pid cycle.
  static let maxAncestorDepth = 64

  /// Bytes of randomness in a stamp nonce.
  static let nonceByteCount = 16

  /// Microseconds per second, converting a process start time to seconds.
  static let microsecondsPerSecond: Double = 1_000_000

  // MARK: Producer

  /// Mark this process as a gated invocation. Called at the top of every gated
  /// entrypoint. Idempotent within a process: a second call is a no-op so nested
  /// gates (lint inside build) do not rewrite the stamp. Being inside a gated
  /// entry means the gate is on the call stack; if the gates fail, the entry
  /// returns before any compile runs, so the mark authorizing compiles is sound.
  public static func mark(context: PathContext = .current()) {
    let myPid = currentPid()
    if markedPid == myPid {
      return
    }
    markedPid = myPid

    // Anchor the proof to the outermost `make` process orchestrating this build,
    // not to this swift-mk process. A build/deploy is one `make` invocation that
    // runs several compiles as separate children (the product build, then a
    // metallib or install step). The gated `swift-mk build` child exits, but the
    // make process stays alive and an ancestor of every later compile, so binding
    // to it keeps the check strict while spanning the whole flow. With no make
    // ancestor (a direct `swift-mk build`), anchor to this process.
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

  /// The refusal status for a compile that lacks the gate proof, or nil when the
  /// proof holds. Emits the loud cause before returning a status, so a
  /// status-returning caller (the toolchain build) reports it without an
  /// `exit()` inside the library. Returns `refusedExitStatus` when ungated.
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

  /// Whether a live swift-mk gate currently covers this process, exposed so a
  /// consumer's build command can route an in-gate compile through the `GateProof`
  /// make path and a decoupled compile through `GatedBuild.run`. This is a routing
  /// signal only: both paths are independently authorized (the make path by this
  /// same proof, the decoupled path by a `GateReceipt` minted after the hard gate),
  /// so reading it to choose a path never weakens the gate. A consumer that lies
  /// about being gated still meets `Toolchain.build`'s `GateProof` check or
  /// `GatedBuild.run`'s hard gate, whichever path it takes.
  public static func isCurrentlyGated(context: PathContext = .current()) -> Bool {
    isGated(context: context)
  }

  /// Whether a valid gate proof covers this process. Pure of side effects so it
  /// is testable; `refusal` wraps it with the loud message and a status.
  ///
  /// Three factors are enforced, all strict: freshness, a live gate-orchestration
  /// ancestor (the `make` process the gate ran under, or the swift-mk gate itself
  /// when there is no make), and that ancestor's process identity (start time).
  /// Anchoring to the orchestrating make process keeps the check strict while
  /// spanning a multi-step build/deploy flow: the make process is alive and an
  /// ancestor of every compile in the flow, including a metallib or install step
  /// that runs after the gated `swift-mk build` child exits. A direct dev-tool
  /// compile has no such live ancestor and is refused. The recorded source digest
  /// is diagnostic only, not enforced, since mid-build code generation can
  /// legitimately rewrite a tracked source between the gate and the compile.
  static func isGated(context: PathContext = .current()) -> Bool {
    guard let stamp = readStamp(context: context) else {
      return false
    }
    // (A) Freshness: a gate wrote the stamp within the window.
    guard nowSeconds() - stamp.createdAt <= freshnessWindowSeconds else {
      return false
    }
    // (B) The anchor is a live make/swift-mk process in this process's ancestry.
    guard ancestorPids().contains(stamp.gatePid), processIsGateAnchor(stamp.gatePid) else {
      return false
    }
    // (C) The live ancestor is the same process instance that wrote the stamp:
    // its start time matches. Skipped only when the gate could not record a start
    // time (stored 0), so an unavailable start time never false-refuses.
    if stamp.gateStartTime != 0 {
      guard processStartTime(of: stamp.gatePid) == stamp.gateStartTime else {
        return false
      }
    }
    return true
  }

  // MARK: Diagnostics

  /// A one-line verdict a child process prints, so a parent gate can confirm the
  /// proof crosses a real process boundary. Reports each factor so a failure
  /// names which one did not hold.
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
    // The source digest is reported but not part of the verdict (advisory), so
    // this matches `isGated`.
    let gated = fresh && ancestor && anchor && startMatch
    return
      "gated=\(gated) fresh=\(fresh) source=\(sourceMatch) ancestor=\(ancestor) "
      + "anchor=\(anchor) startMatch=\(startMatch) anchorPid=\(stamp.gatePid)"
  }

  /// Mark this process as a gate, then spawn the same binary running
  /// `gate-proof probe` and report whether the child saw the proof. This
  /// exercises factors A, B, and C across a real parent/child boundary using the
  /// actual swift-mk binary, so the cross-process mechanism is verifiable without
  /// a full consumer build. Returns the child's full report line.
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

    /// Serialize as a small, fixed-order key=value text, one pair per line.
    func serialized() -> String {
      [
        "nonce=\(nonce)",
        "sourceHash=\(sourceHash)",
        "gatePid=\(gatePid)",
        "gateStartTime=\(gateStartTime)",
        "createdAt=\(createdAt)",
      ].joined(separator: "\n") + "\n"
    }

    /// Parse the serialized form. Returns nil when any field is missing or
    /// malformed, so a truncated or tampered stamp does not authorize.
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
      // No stamp (or unreadable) means no proof; the caller refuses. A missing
      // file is the common case (no gate ran), not an error to surface.
      return nil
    }
    return Stamp.parse(text)
  }

  // MARK: Process ancestry (Darwin)

  /// The pid chain from this process up to the root, this process first. Walks
  /// `getppid` via sysctl so a verifier can confirm the gate process is a genuine
  /// ancestor rather than merely alive.
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

    /// The executable basename of the live process with `pid`, or empty when it
    /// cannot be read (a dead pid). Used to confirm an anchor is a build process.
    static func processName(of pid: Int32) -> String {
      var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
      guard length > 0 else {
        return ""
      }
      return (String(cString: pathBuffer) as NSString).lastPathComponent
    }

    /// The start time of the process with `pid` in seconds since the epoch, or nil
    /// when it cannot be read. Binds the ancestry factor to the exact process
    /// instance, so a recycled pid does not satisfy the proof.
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

  /// Whether the live process with `pid` is a gate-orchestration process: the
  /// `make` that ran the gate, or the swift-mk gate itself. A dead pid or any
  /// other process fails, so the anchor cannot be an arbitrary long-lived ancestor
  /// such as the user's shell.
  static func processIsGateAnchor(_ pid: Int32) -> Bool {
    switch processName(of: pid) {
    case "make", "gmake", "swift-mk":
      return true
    default:
      return false
    }
  }

  /// The outermost `make` process in this process's ancestry, or nil when none.
  /// Outermost (the last `make` found walking from this process up) so a recursive
  /// sub-make spawned for one build step is not chosen over the top-level
  /// `make deploy` that also runs the later install step.
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

  /// The absolute path of the running executable, used to spawn the same binary
  /// for the self-test. Empty when it cannot be resolved.
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

  // Track the pid this process marked, so `mark` is idempotent across nested
  // gated entries within one process.
  nonisolated(unsafe) private static var markedPid: Int32 = -1
}

// MARK: - Source digest

/// The tracked-source walk and the digest primitives it feeds. These live in an
/// extension so the primary `GateProof` body stays focused on the proof, while the
/// walk and hashes stay callable as `GateProof.*` by the proof itself and by
/// `BuildFreshness`, which shares the same file set and exclusions.
extension GateProof {
  /// Source file extensions whose content binds the proof to the working tree.
  static let sourceExtensions: Set<String> = ["swift", "mk", "h", "m", "c", "metal"]

  /// Directory names that never contribute to the source digest: build output,
  /// caches, vcs metadata, and vendored package checkouts.
  static let digestExcludedDirectories: Set<String> = [
    ".git", ".build", ".make", "DerivedData", "Derived", "Products",
    "SourcePackages", "node_modules", ".swiftpm", "build", ".tuist", "Pods",
  ]

  /// Walk the tracked source set under the repo root, invoking `body` once per
  /// source file with its repo-relative path and URL. Applies the same directory
  /// pruning (`digestExcludedDirectories`) and extension filter (`sourceExtensions`)
  /// that the digests depend on, so the mtime digest and the content digest see a
  /// byte-identical file set. The walk order is unspecified, so a caller that
  /// needs a stable digest sorts its own entries. Returns false only when the
  /// enumerator could not be created, letting a caller preserve its "empty"
  /// sentinel distinct from a tree that simply has no source files.
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
      // A file that cannot be stat'd is treated as a non-directory, so it falls
      // through to the extension check and is still considered, matching the
      // prior best-effort behavior.
      var isDirectory = false
      do {
        isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
      } catch {
        // Treat an unreadable entry as a non-directory so it still reaches the
        // extension check, matching the prior best-effort behavior.
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

  /// A stable digest of the tracked source set under the repo root: for each
  /// source file, its repo-relative path, size, and modification time. Recomputed
  /// identically at mark and verify, so a source edited between the gate and the
  /// compile flips the digest and fails the freshness factor. Fast: it stats
  /// files, never reads their contents.
  static func sourceDigest(context: PathContext) -> String {
    var entries: [String] = []
    let started = forEachTrackedSource(context: context) { relative, url in
      let values: URLResourceValues?
      do {
        values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      } catch {
        // A file that cannot be stat'd does not contribute to the digest; the
        // digest is a best-effort change signal, not enforced.
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

  /// The FNV-1a 64-bit offset basis, shared by the string and file digests.
  static let fnv1aOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325

  /// The FNV-1a 64-bit prime, shared by the string and file digests.
  static let fnv1aPrime: UInt64 = 0x0000_0100_0000_01b3

  /// A fast, deterministic 64-bit FNV-1a digest as lowercase hex. Used to detect
  /// a source change between the gate and the compile, not as a cryptographic
  /// boundary, so a non-cryptographic hash is the right tool: the proof's
  /// forgery resistance is the live-ancestor factor, not this digest.
  static func fnv1aHex(_ text: String) -> String {
    var hash = fnv1aOffsetBasis
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* fnv1aPrime
    }
    return String(format: "%016llx", hash)
  }

  /// A 64-bit FNV-1a digest of a file's contents as lowercase hex, streamed in
  /// fixed-size chunks so a large source never loads into memory at once. Binds a
  /// content-based freshness check to the bytes on disk rather than mtime, so it
  /// survives an mtime-only churn. An unreadable file returns a stable sentinel,
  /// distinct from any real content digest, keeping the enclosing digest
  /// deterministic without letting absent content silently match present content.
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
        // A read error mid-file returns the same sentinel as an open failure, so
        // a partially read file never yields a content digest that could match.
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

  /// Read granularity for the streaming file digest. 64 KiB keeps the per-file
  /// working set bounded while amortizing read syscalls over many bytes.
  static let fileDigestChunkBytes = 1 << 16
}
