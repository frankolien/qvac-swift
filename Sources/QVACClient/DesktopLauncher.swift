#if os(macOS) || os(Linux)
import Foundation
import QVACSession

extension QVACClient {

    /// A running desktop stack: the typed client plus the worker process
    /// behind it.
    public struct DesktopWorkerSession: Sendable {
        public let client: QVACClient
        public let worker: WorkerProcess

        /// Ordered teardown: `__shutdown__` roundtrip, session close, then
        /// SIGTERM for whatever is left of the process.
        public func shutdown() async {
            await client.shutdown()
            worker.terminate()
        }
    }

    /// Turnkey desktop bring-up, in the SDK's own order: bind the listener
    /// first, spawn the worker pointed at it (the worker dials in), then
    /// perform the `__init_config` handshake.
    ///
    /// Loopback TCP with an ephemeral port is the default endpoint — the
    /// `sdk-python` precedent, portable everywhere; pass `.unix(path:)` to
    /// use a filesystem socket instead.
    public static func launchWorker(
        runtime: String = "bare",
        workerPath: String,
        endpoint: SocketListenerTransport.Endpoint = .tcp(host: "127.0.0.1", port: 0),
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        config: JSONValue = .object([:]),
        runtimeContext: JSONValue = .object([:])
    ) async throws -> DesktopWorkerSession {
        let transport = try SocketListenerTransport(endpoint: endpoint)
        let worker = try WorkerProcess(configuration: .init(
            runtime: runtime,
            workerPath: workerPath,
            endpoint: transport.workerEndpointString,
            homeDirectory: homeDirectory))
        let client = QVACClient(transport: transport)
        do {
            try await client.initialize(config: config, runtimeContext: runtimeContext)
        } catch {
            await client.shutdown()
            worker.terminate()
            throw error
        }
        return DesktopWorkerSession(client: client, worker: worker)
    }
}
#endif
