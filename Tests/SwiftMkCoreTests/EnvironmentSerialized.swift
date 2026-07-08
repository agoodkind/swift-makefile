//
//  EnvironmentSerialized.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-08.
//  Copyright © 2026, all rights reserved.
//

import Testing

// MARK: - EnvironmentSerialized

/// The shared serialized parent for every suite that mutates the process
/// environment (the trace keys). Swift Testing runs separate top-level suites in
/// parallel, so suites that each set and restore the same env vars can still race;
/// nesting them under this one `.serialized` parent makes the trait apply
/// recursively, so they run one at a time and never clobber each other's env.
@Suite(.serialized)
enum EnvironmentSerialized {}
