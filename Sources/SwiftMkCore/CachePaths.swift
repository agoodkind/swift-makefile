//
//  CachePaths.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-24.
//  Copyright © 2026, all rights reserved.
//
//  The canonical cacheable directories, split into a dependency bucket
//  (cross-commit, content-addressed) and a build bucket (commit-keyed). This is
//  the single source of truth the CI cache action consumes, derived from the same
//  path resolution the build uses, so the DerivedData root and the shared caches
//  are always the real ones, not a hardcoded guess in a shell script.
//

import Foundation

// MARK: - CachePaths

public enum CachePaths {
  /// Resolved path inputs, injected so the path list is pure and testable. The CLI
  /// wrapper resolves these from the environment via `Toolchain`.
  public struct Inputs {
    public var home: String
    /// The resolved per-checkout DerivedData root (absolute).
    public var derivedDataPath: String
    /// The resolved shared SPM clone dir, or nil when the shared SPM cache is off.
    public var spmCachePath: String?
    /// The resolved shared Clang module cache, or nil when off.
    public var moduleCachePath: String?
    /// The resolved shared LLVM compilation-cache (CAS) store, or nil when off. Kept
    /// outside DerivedData so the dead-code coverage build's `rm -rf` cannot destroy it.
    public var xcodeCachePath: String?
    /// The resolved shared LLVM CAS store for `swift build` compilation caching, or nil
    /// when off. The SwiftPM peer of `xcodeCachePath`, kept outside DerivedData and shared
    /// across worktrees; content-addressed, so one shared copy maximizes cross-run reuse.
    public var swiftpmCachePath: String?
    /// Extra cacheable paths a consumer appends (EXTRA_CACHE_PATHS).
    public var extraPaths: [String]

    public init(
      home: String,
      derivedDataPath: String,
      spmCachePath: String?,
      moduleCachePath: String?,
      xcodeCachePath: String?,
      swiftpmCachePath: String?,
      extraPaths: [String]
    ) {
      self.home = home
      self.derivedDataPath = derivedDataPath
      self.spmCachePath = spmCachePath
      self.moduleCachePath = moduleCachePath
      self.xcodeCachePath = xcodeCachePath
      self.swiftpmCachePath = swiftpmCachePath
      self.extraPaths = extraPaths
    }
  }

  public struct Resolved: Equatable {
    public var dependency: [String]
    public var build: [String]
    /// The compile-cache (CAS) stores. A build product, not a downloaded input, so it
    /// is kept in its own bucket: the CI plan keys it as a rolling per-writer cache so
    /// a non-compiling gate cannot freeze it, unlike the shared dependency bucket.
    public var compile: [String]
  }

  /// The DerivedData subdirectories always worth caching: the incremental build
  /// database, the Swift index store, and the resolved SPM checkouts. The LLVM CAS store
  /// is normally NOT here: it is pinned outside DerivedData (see `Inputs.xcodeCachePath`)
  /// so the dead-code coverage build's `rm -rf` of DerivedData cannot destroy it, and it
  /// is cached in the compile bucket. The one exception is when the shared path is
  /// disabled (`SWIFT_MK_XCODE_CACHE_PATH=off`), where the CAS reverts to Xcode's
  /// in-DerivedData default and `resolve` adds it to the build bucket so it still persists.
  static let derivedDataSubdirectories = [
    "Build/Intermediates.noindex",
    "Index.noindex",
    "SourcePackages",
  ]

  public static func resolve(_ inputs: Inputs) -> Resolved {
    let home = inputs.home
    var dependency = [
      "\(home)/.cache/tuist",
      "\(home)/.local/share/mise/downloads",
      "\(home)/.local/share/mise/installs",
      "\(home)/.local/share/mise/plugins",
      "\(home)/Library/Caches/org.swift.swiftpm",
      "\(home)/Library/Caches/ccache",
      "\(home)/Library/Caches/Mozilla.sccache",
      "\(home)/.cache/sccache",
      "Tuist/.build",
    ]
    // The engine's shared content-addressed caches. These were never persisted by
    // the former shell script, so each CI run rebuilt the module cache and re-cloned
    // the SPM packages. A nil path means the shared cache is disabled.
    if let spm = inputs.spmCachePath {
      dependency.append(spm)
    }
    if let module = inputs.moduleCachePath {
      dependency.append(module)
    }

    // The compile-cache (CAS) stores are build products that only the compiling gates
    // fill, and each gate fills a different amount, so they do NOT belong in the
    // shared dependency bucket: there, every gate saves one fixed name and the first
    // gate to finish (a lint gate that compiles nothing) freezes the cache empty. They
    // get their own bucket, which the CI plan keys as a rolling per-writer cache.
    var compile: [String] = []
    if let xcodeCache = inputs.xcodeCachePath {
      compile.append(xcodeCache)
    }
    if let swiftpmCache = inputs.swiftpmCachePath {
      compile.append(swiftpmCache)
    }

    var build = [
      ".build",
      "swiftcheck/.build",
      "Tools/.build",
      ".make/swift-mk-build",
      ".make/swiftcheck/.build",
    ]
    // The real DerivedData root, resolved from the same SWIFT_MK_DERIVED_DATA the
    // build uses, instead of the four guessed roots the shell script hardcoded.
    let derivedRoot = inputs.derivedDataPath
    for subdirectory in derivedDataSubdirectories {
      build.append("\(derivedRoot)/\(subdirectory)")
    }
    // When the CAS store is not pinned to a shared path (SWIFT_MK_XCODE_CACHE_PATH=off),
    // Xcode keeps it at its default `<derivedDataPath>/CompilationCache.noindex`, so cache
    // it there to preserve cross-run persistence. When it IS pinned, the store lives at the
    // shared dependency path appended above and is never under DerivedData.
    if inputs.xcodeCachePath == nil {
      build.append("\(derivedRoot)/CompilationCache.noindex")
    }
    build.append(contentsOf: inputs.extraPaths)

    return Resolved(dependency: dependency, build: build, compile: compile)
  }
}
