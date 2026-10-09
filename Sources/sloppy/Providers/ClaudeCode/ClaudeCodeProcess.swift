import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Protocols

/// A request-owned process group. Cancellation also kills CLI helper processes.
final class ClaudeCodeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var inputFD: Int32 = -1

    func start(executable: String, arguments: [String], environment: [String: String], cwd: URL, singleJSON: Bool = false) throws -> AsyncThrowingStream<JSONValue, Error> {
        let output = Pipe()
        var input = [Int32](repeating: -1, count: 2)
#if canImport(Darwin)
        let socketType = SOCK_STREAM
#else
        let socketType = Int32(SOCK_STREAM.rawValue)
#endif
        guard socketpair(AF_UNIX, socketType, 0, &input) == 0 else { throw posixError() }
        for fd in input + [output.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        defer { close(input[1]) }
#if canImport(Darwin)
        var noSignal: Int32 = 1
        _ = setsockopt(input[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
#endif
#if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
#else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
#endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, input[1], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, input[0])
        posix_spawn_file_actions_addclose(&actions, input[1])
        posix_spawn_file_actions_addclose(&actions, output.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, output.fileHandleForWriting.fileDescriptor)
        // chdir is part of spawn; never change the Core process's working directory.
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
#if canImport(Darwin)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
#else
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
#endif
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + envp).forEach { free($0) } }
        var args = argv + [nil]
        var env = envp + [nil]
        var child: pid_t = 0
        let status = lock.withLock { () -> Int32 in
            if cancelled { return ECANCELED }
            let result = posix_spawn(&child, executable, &actions, &attributes, &args, &env)
            if result == 0 { pid = child; inputFD = input[0] }
            return result
        }
        guard status == 0 else { close(input[0]); throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        let spawnedPID = child
        try output.fileHandleForWriting.close()
        return AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                var buffer = Data()
                do {
                    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        // FileHandle's counted reads can wait for a full buffer on
                        // a pipe. A single POSIX read delivers replay ACKs promptly.
                        let count = read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                        if count < 0 && errno == EINTR { continue }
                        guard count >= 0 else { throw posixError() }
                        if count == 0 { break }
                        buffer.append(contentsOf: bytes.prefix(count))
                        guard buffer.count <= 32 * 1024 * 1024 else { throw ClaudeCodeError.invalidStream }
                        while !singleJSON, let end = buffer.firstIndex(of: 10) {
                            let line = Data(buffer[..<end])
                            buffer.removeSubrange(...end)
                            if !line.isEmpty { continuation.yield(try JSONDecoder().decode(JSONValue.self, from: line)) }
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(try JSONDecoder().decode(JSONValue.self, from: buffer)) }
                    var waitStatus: Int32 = 0
                    while waitpid(spawnedPID, &waitStatus, 0) == -1 && errno == EINTR {}
                    lock.withLock { pid = 0 }
                    // A native exit without a complete admitted response is always a failure.
                    continuation.finish()
                } catch {
                    cancel()
                    var waitStatus: Int32 = 0
                    while waitpid(spawnedPID, &waitStatus, 0) == -1 && errno == EINTR {}
                    lock.withLock { pid = 0 }
                    continuation.finish(throwing: error)
                }
                try? output.fileHandleForReading.close()
            }
            continuation.onTermination = { [self] _ in cancel() }
        }
    }

    func write(_ frame: JSONValue) async throws {
        var data = try JSONEncoder().encode(frame)
        data.append(10)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async { [self, data] in
                do {
                    // Duplicate under the lock so cancellation cannot recycle the descriptor.
                    let fd = lock.withLock { () -> Int32 in
                        guard inputFD >= 0 else { return -1 }
                        let duplicate = dup(inputFD)
                        if duplicate >= 0 { _ = fcntl(duplicate, F_SETFD, FD_CLOEXEC) }
                        return duplicate
                    }
                    guard fd >= 0 else { throw CancellationError() }
                    defer { close(fd) }
                    try data.withUnsafeBytes { bytes in
                        guard let pointer = bytes.baseAddress else { return }
                        var offset = 0
                        while offset < bytes.count {
#if canImport(Darwin)
                            let count = send(fd, pointer.advanced(by: offset), bytes.count - offset, 0)
#else
                            let count = send(fd, pointer.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
#endif
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { throw posixError() }
                            offset += count
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func closeInput() {
        lock.withLock {
            if inputFD >= 0 { shutdown(inputFD, Int32(SHUT_WR)); close(inputFD); inputFD = -1 }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if pid > 0 { _ = kill(-pid, SIGKILL) }
            if inputFD >= 0 { shutdown(inputFD, Int32(SHUT_RDWR)); close(inputFD); inputFD = -1 }
        }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    deinit { cancel() }
}
