//
//  FileLock.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - FileLock

/// An advisory exclusive lock on a file, used to serialize the dead-code coverage
/// build so two gate runs never build at the same time.
public final class FileLock {
    private static let lockFileMode: mode_t = 0o644

    private let descriptor: Int32

    /// Open (creating if needed) the lock file. Returns nil when it cannot open.
    public init?(path: String) {
        let fd = open(path, O_CREAT | O_RDWR, FileLock.lockFileMode)
        if fd < 0 {
            return nil
        }
        descriptor = fd
    }

    /// Take the exclusive lock, blocking until it is free. `onWait` runs once if the
    /// lock is already held, before this blocks. Returns false on error.
    @discardableResult
    public func acquire(onWait: () -> Void) -> Bool {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return true
        }
        onWait()
        return flock(descriptor, LOCK_EX) == 0
    }

    /// Release the lock and close the file.
    public func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
