#if os(macOS) || os(Linux)
import Foundation

/// Spawns and supervises the Bare worker on desktop platforms, with the argv
/// contract `node-rpc-client.ts` uses:
///
///     bare <workerPath> '{"QVAC_IPC_SOCKET_PATH": <endpoint>, "HOME_DIR": <home>}'
///
/// The listener must already be bound when the worker launches — the worker
/// dials in — which is why this takes the transport's `workerEndpointString`
/// rather than making up its own.
///
/// stderr is piped and a bounded tail retained, mirroring the JS client's
/// crash diagnostics: when a worker dies, the last lines it wrote are usually
/// the only evidence.
public final class WorkerProcess: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// The runtime executable, resolved via `/usr/bin/env`. The real
        /// worker runs under `bare`; tests substitute `node`.
        public var runtime: String
        /// The worker bundle/script path — the SDK's `WORKER_PATH`.
        public var workerPath: String
        /// What goes into `QVAC_IPC_SOCKET_PATH`: a socket path or
        /// `tcp://host:port`, i.e. `SocketListenerTransport.workerEndpointString`.
        public var endpoint: String
        /// What goes into `HOME_DIR`.
        public var homeDirectory: String

        public init(
            runtime: String = "bare",
            workerPath: String,
            endpoint: String,
            homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
        ) {
            self.runtime = runtime
            self.workerPath = workerPath
            self.endpoint = endpoint
            self.homeDirectory = homeDirectory
        }
    }

    public enum LaunchError: Swift.Error {
        case spawnFailed(String)
    }

    private let process: Process
    private let lock = NSLock()
    private var stderrLines: [String] = []
    private static let stderrTailLimit = 64

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    /// The last lines the worker wrote to stderr — the crash post-mortem.
    public var stderrTail: String {
        lock.lock()
        defer { lock.unlock() }
        return stderrLines.joined(separator: "\n")
    }

    public init(configuration: Configuration,
                onExit: (@Sendable (Int32) -> Void)? = nil) throws {
        let argument: String
        do {
            // JSONSerialization keeps this dependency-free; key order is
            // irrelevant to the worker.
            let payload = try JSONSerialization.data(withJSONObject: [
                "QVAC_IPC_SOCKET_PATH": configuration.endpoint,
                "HOME_DIR": configuration.homeDirectory
            ])
            argument = String(decoding: payload, as: UTF8.self)
        } catch {
            throw LaunchError.spawnFailed("could not encode worker argument: \(error)")
        }

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [configuration.runtime, configuration.workerPath, argument]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.terminationHandler = { process in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            onExit?(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw LaunchError.spawnFailed("\(configuration.runtime) \(configuration.workerPath): \(error)")
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.lock()
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                self.stderrLines.append(String(line))
            }
            if self.stderrLines.count > Self.stderrTailLimit {
                self.stderrLines.removeFirst(self.stderrLines.count - Self.stderrTailLimit)
            }
            self.lock.unlock()
        }
    }

    /// SIGTERM — the only signal the reference client ever sends; the real
    /// worker exits on it, though not instantly (addons unwind first). The
    /// escalation to SIGKILL is a backstop the reference lacks: a supervisor
    /// that cannot guarantee reaping leaves zombies behind.
    ///
    /// The session's `__shutdown__` roundtrip belongs *before* this — the
    /// client layer sequences that.
    public func terminate(forceAfter seconds: TimeInterval = 10) {
        guard process.isRunning else { return }
        process.terminate()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}
#endif
