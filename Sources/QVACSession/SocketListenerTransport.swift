import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The class defines its own `close()`, so the syscalls live behind unambiguous
// names — and Linux's Glibc types some constants differently than Darwin.
private func posixClose(_ fd: Int32) { _ = close(fd) }
private func posixShutdown(_ fd: Int32) { _ = shutdown(fd, Int32(SHUT_RDWR)) }
#if canImport(Darwin)
private let sockStream = SOCK_STREAM
#else
private let sockStream = Int32(SOCK_STREAM.rawValue)
#endif

/// The desktop transport, with the direction the SDK actually uses: the
/// *client* listens and the worker dials in. `node-rpc-client.ts` calls
/// `createServer()` + `listen(path)` before spawning the worker and hands the
/// endpoint over via `QVAC_IPC_SOCKET_PATH`; building a connecting client —
/// what a naive reading of the brief suggests — produces something that
/// connects to nothing.
///
/// Supports both endpoint forms `server/rpc/create-server.ts` accepts: a
/// filesystem `AF_UNIX` path and `tcp://host:port` (loopback TCP is what
/// `sdk-python` ships on every OS). Plain POSIX sockets, so the same code
/// tests on Linux CI.
///
/// One worker, one connection: the first accepted peer is the channel, and
/// the listener closes behind it.
public final class SocketListenerTransport: Transport, @unchecked Sendable {

    public enum Endpoint: Sendable {
        case unix(path: String)
        /// Port 0 binds an ephemeral port; read the result off
        /// `workerEndpointString`.
        case tcp(host: String, port: UInt16)
    }

    public enum TransportError: Swift.Error, Equatable {
        case systemCall(String, errno: Int32)
        case pathTooLong(String)
        case closed
    }

    public let inbound: AsyncThrowingStream<Data, Swift.Error>
    private let inboundWriter: AsyncThrowingStream<Data, Swift.Error>.Continuation

    /// The string the worker should be launched with (`QVAC_IPC_SOCKET_PATH`):
    /// the filesystem path for `AF_UNIX`, `tcp://host:port` for TCP — with the
    /// kernel-resolved port when 0 was requested.
    public let workerEndpointString: String

    private let lock = NSLock()
    private var listenerFD: Int32
    private var connectionFD: Int32?
    private var connectionWaiters: [CheckedContinuation<Int32, Swift.Error>] = []
    private var closed = false
    private let unixPath: String?

    // MARK: - Setup

    public init(endpoint: Endpoint) throws {
        switch endpoint {
        case .unix(let path):
            self.unixPath = path
            self.listenerFD = try Self.listenUnix(path: path)
            self.workerEndpointString = path
        case .tcp(let host, let port):
            self.unixPath = nil
            let (fd, boundPort) = try Self.listenTCP(host: host, port: port)
            self.listenerFD = fd
            self.workerEndpointString = "tcp://\(host):\(boundPort)"
        }
        (self.inbound, self.inboundWriter) = AsyncThrowingStream.makeStream(of: Data.self)

        let thread = Thread { [weak self] in self?.acceptThenRead() }
        thread.name = "qvac.socket-transport"
        thread.start()
    }

    private static func listenUnix(path: String) throws -> Int32 {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        let bytes = Array(path.utf8)
        guard bytes.count <= capacity else { throw TransportError.pathTooLong(path) }

        let fd = socket(AF_UNIX, sockStream, 0)
        guard fd >= 0 else { throw TransportError.systemCall("socket", errno: errno) }

        unlink(path)  // a stale socket file from a previous run refuses bind
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let seen = errno; posixClose(fd)
            throw TransportError.systemCall("bind(\(path))", errno: seen)
        }
        guard listen(fd, 1) == 0 else {
            let seen = errno; posixClose(fd)
            throw TransportError.systemCall("listen", errno: seen)
        }
        return fd
    }

    private static func listenTCP(host: String, port: UInt16) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw TransportError.systemCall("socket", errno: errno) }

        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            posixClose(fd)
            throw TransportError.systemCall("inet_pton(\(host))", errno: EINVAL)
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let seen = errno; posixClose(fd)
            throw TransportError.systemCall("bind(\(host):\(port))", errno: seen)
        }
        guard listen(fd, 1) == 0 else {
            let seen = errno; posixClose(fd)
            throw TransportError.systemCall("listen", errno: seen)
        }

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            let seen = errno; posixClose(fd)
            throw TransportError.systemCall("getsockname", errno: seen)
        }
        return (fd, UInt16(bigEndian: resolved.sin_port))
    }

    // MARK: - Accept + read loop (dedicated thread)

    private func acceptThenRead() {
        let peer = accept(listenerFD, nil, nil)
        let acceptErrno = errno

        lock.lock()
        // One connection is all we serve; the listener has done its job
        // (or `close()` raced us — same outcome).
        if listenerFD >= 0 { posixClose(listenerFD); listenerFD = -1 }

        guard peer >= 0, !closed else {
            let wasDeliberate = closed
            closed = true
            let waiters = connectionWaiters
            connectionWaiters = []
            lock.unlock()

            if peer >= 0 { posixClose(peer) }
            for waiter in waiters { waiter.resume(throwing: TransportError.closed) }
            if wasDeliberate {
                inboundWriter.finish()
            } else {
                inboundWriter.finish(throwing: TransportError.systemCall("accept", errno: acceptErrno))
            }
            return
        }

        #if canImport(Darwin)
        var noSigpipe: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        connectionFD = peer
        let waiters = connectionWaiters
        connectionWaiters = []
        lock.unlock()

        for waiter in waiters { waiter.resume(returning: peer) }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(peer, &buffer, buffer.count)
            if count > 0 {
                inboundWriter.yield(Data(buffer[0 ..< count]))
            } else if count == 0 {
                inboundWriter.finish()  // worker hung up: clean EOF
                return
            } else if errno != EINTR {
                let seen = errno
                lock.lock()
                let wasDeliberate = closed
                lock.unlock()
                if wasDeliberate {
                    inboundWriter.finish()
                } else {
                    inboundWriter.finish(throwing: TransportError.systemCall("read", errno: seen))
                }
                return
            }
        }
    }

    /// Scoped locking: async functions may not call `lock()`/`unlock()`
    /// directly (a suspension inside the critical section would deadlock);
    /// funnelling through a synchronous closure makes that impossible.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private enum ConnectionCheck {
        case ready(Int32)
        case closed
        case wait
    }

    private func checkConnection(installing continuation: CheckedContinuation<Int32, Swift.Error>? = nil) -> ConnectionCheck {
        withLock {
            if closed { return .closed }
            if let fd = connectionFD { return .ready(fd) }
            if let continuation { connectionWaiters.append(continuation) }
            return .wait
        }
    }

    private func awaitConnection() async throws -> Int32 {
        switch checkConnection() {
        case .ready(let fd): return fd
        case .closed: throw TransportError.closed
        case .wait: break
        }
        return try await withCheckedThrowingContinuation { continuation in
            // Re-check under the lock while installing: the accept thread may
            // have delivered (or teardown killed) the connection in between.
            switch checkConnection(installing: continuation) {
            case .ready(let fd): continuation.resume(returning: fd)
            case .closed: continuation.resume(throwing: TransportError.closed)
            case .wait: break  // installed; the accept thread resumes us
            }
        }
    }

    // MARK: - Transport

    public func send(_ data: Data) async throws {
        let fd = try await awaitConnection()
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                #else
                let written = Glibc.send(fd, raw.baseAddress! + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                if written > 0 {
                    offset += written
                } else if errno != EINTR {
                    throw TransportError.systemCall("write", errno: errno)
                }
            }
        }
    }

    public func close() async {
        let resources: (listener: Int32, connection: Int32?, waiters: [CheckedContinuation<Int32, Swift.Error>])? = withLock {
            guard !closed else { return nil }
            closed = true
            defer {
                listenerFD = -1
                connectionFD = nil
                connectionWaiters = []
            }
            return (listenerFD, connectionFD, connectionWaiters)
        }
        guard let (listener, connection, waiters) = resources else { return }

        // Shutting down the peer wakes the blocked read(); closing the
        // listener wakes a blocked accept().
        if let connection { posixShutdown(connection); posixClose(connection) }
        if listener >= 0 { posixClose(listener) }
        if let unixPath { unlink(unixPath) }
        for waiter in waiters { waiter.resume(throwing: TransportError.closed) }
    }

    deinit {
        if let connection = connectionFD { posixShutdown(connection); posixClose(connection) }
        if listenerFD >= 0 { posixClose(listenerFD) }
        if let unixPath, !closed { unlink(unixPath) }
    }
}
