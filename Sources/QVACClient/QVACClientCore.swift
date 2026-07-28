import Foundation
import QVACSession

/// The typed QVAC client: generated method surface over the session layer.
///
/// Two facts about the wire that the brief obscures, both taken from
/// `rpc-client.ts`: the `bare-rpc` *command* is a per-call counter, not a
/// method identifier — the method is named by the payload's JSON `type`
/// field — and the very first command a client sends (`1`) is therefore the
/// `__init_config` handshake.
public actor QVACClient {

    private let session: RPCSession
    private var commandCounter: UInt64 = 0

    public init(session: RPCSession) {
        self.session = session
    }

    public init(transport: any Transport) {
        self.session = RPCSession(transport: transport)
    }

    private func nextCommand() -> UInt64 {
        commandCounter += 1
        return commandCounter
    }

    // MARK: - Lifecycle

    /// The `__init_config` handshake. Must be the first call; the config
    /// becomes immutable worker-side afterwards.
    public func initialize(config: JSONValue = .object([:]),
                           runtimeContext: JSONValue = .object([:])) async throws {
        struct Reply: Decodable { let success: Bool?; let error: JSONValue? }
        let payload = JSONValue.object([
            "type": .string("__init_config"),
            "config": config,
            "runtimeContext": runtimeContext
        ])
        let reply: Reply = try await unaryCall(payload)
        guard reply.success == true else {
            throw QVACClientError.initializationFailed(String(describing: reply.error))
        }
    }

    /// The `__shutdown__` roundtrip, then session teardown. The ordering is
    /// deliberate: terminating an iOS worklet without the roundtrip trips a
    /// documented V8 GlobalHandle assertion when addon state outlives the
    /// isolate. Errors on the roundtrip are swallowed — a dead worker is
    /// already shut down — and a watchdog bounds the wait, because a live
    /// worker that never answers must not be able to hang teardown.
    public func shutdown(roundtripTimeout: Duration = .seconds(3)) async {
        struct Reply: Decodable { let success: Bool? }
        let payload = JSONValue.object(["type": .string("__shutdown__")])
        let roundtrip = Task { _ = try? await self.unaryCall(payload) as Reply }
        let watchdog = Task {
            try? await Task.sleep(for: roundtripTimeout)
            roundtrip.cancel()
        }
        _ = await roundtrip.value
        watchdog.cancel()
        await session.shutdown()
    }

    // MARK: - Call primitives (used by the generated surface)

    func unaryCall<Request: Encodable, Response: Decodable>(_ request: Request) async throws -> Response {
        let payload = try Self.encode(request)
        let reply = try await session.call(command: nextCommand(), payload: payload)
        return try Self.decodeResponse(reply)
    }

    /// The unary path for the four promotable methods: refuses a request the
    /// manifest would promote, because awaiting one reply to a streamed
    /// response hangs forever.
    func unaryGuardedCall<Request: Encodable, Response: Decodable>(
        _ request: Request, method: String
    ) async throws -> Response {
        let payload = try Self.encode(request)
        let probe = try Self.decodeRequestProbe(payload)
        guard !ProgressPredicates.promotes(
            method: method, withProgress: probe.withProgress, operation: probe.operation) else {
            throw QVACClientError.progressPromoted(method: method)
        }
        let reply = try await session.call(command: nextCommand(), payload: payload)
        return try Self.decodeResponse(reply)
    }

    func streamCall<Request: Encodable, Response: Decodable & Sendable>(
        _ request: Request
    ) async throws -> AsyncThrowingStream<Response, Swift.Error> {
        let payload = try Self.encode(request)
        let records = try await session.serverStream(command: nextCommand(), payload: payload).ndjsonRecords()

        return AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    for try await record in records {
                        continuation.yield(try Self.decodeResponse(record) as Response)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    /// The promoted call shape: a stream where progress records and the final
    /// result are distinguished only by each payload's `type` tag, never by
    /// position. Falls back to the plain unary shape when the request does
    /// not actually promote.
    func progressCall<Request: Encodable, Progress: Decodable, Response: Decodable>(
        _ request: Request,
        method: String,
        finalTag: String,
        progressTag: String,
        onProgress: @Sendable (Progress) -> Void
    ) async throws -> Response {
        let payload = try Self.encode(request)
        let probe = try Self.decodeRequestProbe(payload)
        guard ProgressPredicates.promotes(
            method: method, withProgress: probe.withProgress, operation: probe.operation) else {
            let reply = try await session.call(command: nextCommand(), payload: payload)
            return try Self.decodeResponse(reply)
        }

        let records = try await session.serverStream(command: nextCommand(), payload: payload).ndjsonRecords()
        var final: Response?
        for try await record in records {
            let tag = try Self.decodeTypeTag(record)
            switch tag {
            case "error":
                throw QVACRemoteError(response: try Self.decoder().decode(ErrorResponse.self, from: record))
            case progressTag:
                onProgress(try Self.decoder().decode(Progress.self, from: record))
            case finalTag:
                final = try Self.decoder().decode(Response.self, from: record)
            default:
                continue  // forward-compatible: unknown record kinds skip
            }
        }
        guard let final else { throw QVACClientError.missingFinalResponse(method: method) }
        return final
    }

    // MARK: - Encoding plumbing

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted keys keep the wire deterministic, which keeps tests exact.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder { JSONDecoder() }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    private struct RequestProbe: Decodable {
        let withProgress: Bool?
        let operation: String?
    }

    private static func decodeRequestProbe(_ payload: Data) throws -> RequestProbe {
        try decoder().decode(RequestProbe.self, from: payload)
    }

    private struct TypeTag: Decodable { let type: String? }

    private static func decodeTypeTag(_ payload: Data) throws -> String? {
        (try? decoder().decode(TypeTag.self, from: payload))?.type
    }

    /// Every reply passes the in-band error gate before decoding: application
    /// errors arrive as `{"type":"error", ...}` on the *success* path.
    static func decodeResponse<Response: Decodable>(_ payload: Data) throws -> Response {
        if try decodeTypeTag(payload) == "error" {
            throw QVACRemoteError(response: try decoder().decode(ErrorResponse.self, from: payload))
        }
        do {
            return try decoder().decode(Response.self, from: payload)
        } catch {
            throw QVACClientError.undecodableResponse(
                method: String(describing: Response.self), detail: String(describing: error))
        }
    }
}
