import Foundation

/// An advisory lock on a file (`flock`), held across processes: the app, its
/// App Intents and widgets all open the same store in the App Group. Each
/// call opens its own descriptor, so two holders in one process exclude each
/// other too.
enum FileLock {
    /// Holds the lock for a short, synchronous critical section.
    static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let fd = try open(url)
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw lockError(url) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Holds the lock across suspension points (a whole sync), waiting
    /// without blocking a thread.
    static func withLock<T>(at url: URL, _ body: () async throws -> T) async throws -> T {
        let fd = try open(url)
        defer { close(fd) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw lockError(url) }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    private static func open(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw lockError(url) }
        return fd
    }

    private static func lockError(_ url: URL) -> NoteStoreError {
        .invalid("Can't lock \(url.lastPathComponent): \(String(cString: strerror(errno)))")
    }
}
