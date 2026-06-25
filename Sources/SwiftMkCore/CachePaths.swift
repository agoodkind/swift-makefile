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
    /// Extra cacheable paths a consumer appends (EXTRA_CACHE_PATHS).
    public var extraPaths: [String]

    public init(
      home: String,
      derivedDataPath: String,
      spmCachePath: String?,
      moduleCachePath: String?,
      extraPaths: [String]
    ) {
      self.home = home
      self.derivedDataPath = derivedDataPath
      self.spmCachePath = spmCachePath
      self.moduleCachePath = moduleCachePath
      self.extraPaths = extraPaths
    }
  }

  public struct Resolved: Equatable {
    public var dependency: [String]
    public var build: [String]
  }

  /// The DerivedData subdirectories worth caching: the incremental build database,
  /// the Swift index store, the resolved SPM checkouts, and the LLVM CAS Swift
  /// compilation cache.
  static let derivedDataSubdirectories = [
    "Build/Intermediates.noindex",
    "Index.noindex",
    "SourcePackages",
    "CompilationCache.noindex",
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
    build.append(contentsOf: inputs.extraPaths)

    return Resolved(dependency: dependency, build: build)
  }
}
