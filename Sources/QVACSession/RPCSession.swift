import Foundation
import QVACWire

/// Errors surfaced by the session layer.
public enum SessionError: Swift.Error, Equatable {
    /// The transport died or the session was shut down. Every operation that
    /// was pending fails with this at the moment of death — nothing is left
    /// hanging on a dead socket. (The reference JS client documents this exact
    /// hazard: `bare-rpc` does not reject in-flight requests on channel death,
    /// and its fix is a "worker life signal". This is that signal, built in.)
    case closed(reason: String)
    /// The worker answered with a protocol-level RPC error.
    case remote(WireError)
    /// The peer said something the protocol does not allow here — e.g. a unary
    /// RESPONSE to a call that was opened as a stream. Failing loudly beats the
    /// alternative, which is an `AsyncSequence` that never terminates.
    case protocolViolation(String)
}

/// A request or event arriving *from* the worker.
public struct InboundCall: Sendable {
    public let command: UInt64
    public let payload: Data
    /// `id == 0` on the wire: fire-and-forget, no reply possible. Replying to
    /// one as if it were a request would leak a continuation forever.
    public let isEvent: Bool
}

/// The consumer half of a `bare-rpc` channel: one connection, many concurrent
/// calls, replies and stream chunks routed back by request id.
///
/// Actor isolation is the multiplexing invariant: the pending-reply table, the
/// stream registry, the id counter, and the frame decoder are all actor state,
/// so no lock ordering exists to get wrong. One read task drives the decode
/// loop; one write task drains an ordered outbound queue, so frames can never
/// interleave mid-write.
public actor RPCSession {

    public struct Configuration: Sendable {
        /// Bytes buffered on a stream before the session sends `PAUSE`.
        public var highWaterMark: Int
        /// Once a paused stream's buffer drains to this, the session sends
        /// `RESUME`. The gap between the marks is the hysteresis — without it a
        /// fast token stream thrashes one control frame per token.
        public var lowWaterMark: Int

        public init(highWaterMark: Int = 1 << 20, lowWaterMark: Int = 1 << 18) {
            precondition(lowWaterMark <= highWaterMark)
            self.highWaterMark = highWaterMark
            self.lowWaterMark = lowWaterMark
        }
    }

    // MARK: - State

    private enum Pending {
        case unary(CheckedContinuation<Data, Swift.Error>)
        case stream(StreamState)
    }

    /// Per-stream receive state. A class so the actor mutates it in place.
    final class StreamState {
        var chunks: [Data] = []
        var head = 0                    // moving read index; compacted lazily
        var bufferedBytes = 0
        var pausedByUs = false
        var finished = false
        var failure: Swift.Error?
        var waiter: CheckedContinuation<Data?, Swift.Error>?

        var isDrained: Bool { head >= chunks.count }

        func popChunk() -> Data? {
            guard head < chunks.count else { return nil }
            let chunk = chunks[head]
            head += 1
            bufferedBytes -= chunk.count
            if head >= chunks.count {
                chunks.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= chunks.count / 2 {
                chunks.removeFirst(head)
                head = 0
            }
            return chunk
        }
    }

    private let transport: any Transport
    private let config: Configuration

    private var nextID: UInt64 = 0
    private var pending: [UInt64: Pending] = [:]
    private var closedReason: String?

    private var decoder = FrameDecoder()
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private let outbound: AsyncStream<Data>
    private let outboundWriter: AsyncStream<Data>.Continuation

    private var inboundHandler: (@Sendable (InboundCall) async -> Data?)?

    // MARK: - Lifecycle

    public init(transport: any Transport, configuration: Configuration = .init()) {
        self.transport = transport
        self.config = configuration
        (self.outbound, self.outboundWriter) = AsyncStream.makeStream(of: Data.self)

        Task { await self.start() }
    }

    private func start() {
        guard readTask == nil, closedReason == nil else { return }

        // These Tasks inherit the actor's isolation, so calls back into
        // session state are synchronous — no lock, no hop, no race.
        writeTask = Task {
            for await frame in self.outbound {
                do { try await self.transport.send(frame) } catch {
                    self.tearDown(reason: "transport write failed: \(error)")
                    return
                }
            }
        }

        readTask = Task {
            do {
                for try await chunk in self.transport.inbound {
                    try self.receive(chunk)
                }
                self.tearDown(reason: "channel closed")
            } catch {
                self.tearDown(reason: "transport read failed: \(error)")
            }
        }
    }

    /// Idempotent. Fails everything pending, stops both loops, closes the
    /// transport. Higher layers perform the `__shutdown__` roundtrip *before*
    /// calling this — that ordering is what avoids the documented V8
    /// GlobalHandle crash when tearing down an iOS worklet.
    public func shutdown() async {
        tearDown(reason: "session shut down")
        await transport.close()
    }

    private func tearDown(reason: String) {
        guard closedReason == nil else { return }
        closedReason = reason

        outboundWriter.finish()
        readTask?.cancel()

        let dying = pending
        pending.removeAll()
        for entry in dying.values {
            switch entry {
            case .unary(let continuation):
                continuation.resume(throwing: SessionError.closed(reason: reason))
            case .stream(let state):
                fail(state, with: SessionError.closed(reason: reason))
            }
        }
    }

    // MARK: - Outbound API

    /// A unary request-reply call.
    public func call(command: UInt64, payload: Data) async throws -> Data {
        try ensureOpen()
        nextID += 1
        let id = nextID

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancelled before the entry existed: `onCancel` has already
                // run and found nothing to abandon, so settle here — the two
                // checks together close the install/cancel race.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Install before enqueueing the frame: replies route through
                // this actor, so the entry is visible before any reply can be.
                pending[id] = .unary(continuation)
                enqueue(.request(id: id, command: command, payload: payload))
            }
        } onCancel: {
            // `bare-rpc` has no unary-cancel wire message; the most we can do
            // is stop waiting and let any late reply fall into the void.
            Task { await self.abandonUnary(id: id) }
        }
    }

    /// A fire-and-forget event (`id == 0` on the wire). No reply ever comes.
    public func sendEvent(command: UInt64, payload: Data) throws {
        try ensureOpen()
        enqueue(WireMessage(type: .request, id: 0, command: command, flags: .none, payload: payload))
    }

    /// Opens a server-stream call: one request out, a stream of payload chunks
    /// back. Chunks are raw frame payloads — for QVAC methods the records
    /// inside are NDJSON; compose `ResponseStream.ndjsonRecords()` on top.
    public func serverStream(command: UInt64, payload: Data) throws -> ResponseStream {
        try ensureOpen()
        nextID += 1
        let id = nextID

        pending[id] = .stream(StreamState())
        enqueue(.request(id: id, command: command, payload: payload))
        // Announce readiness to receive the response stream, exactly as the
        // reference client's eager-open does.
        enqueue(WireMessage(type: .stream, id: id, flags: [.response, .open]))

        return ResponseStream(session: self, id: id)
    }

    /// Handler for calls arriving from the worker. Return a payload to reply
    /// to a request; the return value is ignored for events. Unhandled
    /// requests are dropped, matching the reference implementation's no-op
    /// default.
    public func setInboundHandler(_ handler: @escaping @Sendable (InboundCall) async -> Data?) {
        inboundHandler = handler
    }

    // MARK: - Outbound plumbing

    private func ensureOpen() throws {
        if let reason = closedReason { throw SessionError.closed(reason: reason) }
    }

    private func enqueue(_ message: WireMessage) {
        outboundWriter.yield(WireCodec.encode(message))
    }

    private func abandonUnary(id: UInt64) {
        if case .unary(let continuation)? = pending.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - Inbound dispatch

    private func receive(_ chunk: Data) throws {
        for message in try decoder.appendDecoding(chunk) {
            dispatch(message)
        }
    }

    private func dispatch(_ message: WireMessage) {
        switch message.type {
        case .request:
            dispatchInbound(message)
        case .response:
            dispatchResponse(message)
        case .stream:
            dispatchStream(message)
        }
    }

    private func dispatchResponse(_ message: WireMessage) {
        guard message.id != 0, let entry = pending[message.id] else { return }

        switch entry {
        case .unary(let continuation):
            if let error = message.error {
                pending.removeValue(forKey: message.id)
                continuation.resume(throwing: SessionError.remote(error))
            } else if message.flags.isUnary {
                pending.removeValue(forKey: message.id)
                continuation.resume(returning: message.payload ?? Data())
            }
            // RESPONSE with nonzero flags and no error is a stream-open
            // announcement — meaningless for a unary call; ignore, as the
            // reference does.

        case .stream(let state):
            if let error = message.error {
                fail(state, with: SessionError.remote(error))
            } else if message.flags.isUnary {
                // The server answered unary where we opened a stream. The
                // reference resolves a promise nobody holds and the stream
                // hangs forever; we fail fast instead.
                fail(state, with: SessionError.protocolViolation(
                    "unary RESPONSE to a stream call (id \(message.id))"))
            }
            // RESPONSE {stream: OPEN}: the server's stream-open announcement.
            // Data flows via STREAM frames; nothing to do.
        }
    }

    private func dispatchStream(_ message: WireMessage) {
        guard message.id != 0,
              message.flags.contains(.response),
              case .stream(let state)? = pending[message.id]
        else { return }
        // REQUEST-masked traffic (duplex request streams) is not consumed by
        // this client yet; `bare-rpc` ignores unknown stream traffic likewise.

        // Terminal conditions are latched on the state, never acted on by
        // removing the entry here: buffered chunks must drain through the
        // iterator before EOF is reported, or an early-finishing producer
        // silently truncates its own stream. `nextChunk` removes the entry
        // once the consumer has seen the terminal condition.
        if message.flags.contains(.open) {
            // Ack for a stream we would be writing — nothing to do as reader.
        } else if message.flags.contains(.close) {
            // CLOSE without an error is a graceful EOF in the reference.
            if let error = message.error {
                fail(state, with: SessionError.remote(error))
            } else {
                finish(state)
            }
        } else if message.flags.contains(.data) {
            deliver(message.payload ?? Data(), to: state, id: message.id)
        } else if message.flags.contains(.end) {
            finish(state)
        } else if message.flags.contains(.destroy) {
            fail(state, with: message.error.map { SessionError.remote($0) }
                ?? SessionError.closed(reason: "stream destroyed by peer"))
        }
        // PAUSE/RESUME target streams we write; the reader side has none yet.
    }

    private func dispatchInbound(_ message: WireMessage) {
        let call = InboundCall(
            command: message.command ?? 0,
            payload: message.payload ?? Data(),
            isEvent: message.id == 0
        )
        guard let handler = inboundHandler else { return }
        let id = message.id

        Task {
            let reply = await handler(call)
            if !call.isEvent, let reply {
                self.reply(to: id, payload: reply)
            }
        }
    }

    private func reply(to id: UInt64, payload: Data) {
        guard closedReason == nil else { return }
        enqueue(WireMessage(type: .response, id: id, flags: .none, payload: payload))
    }

    // MARK: - Stream receive state

    private func deliver(_ chunk: Data, to state: StreamState, id: UInt64) {
        guard !state.finished, state.failure == nil else { return }  // late data
        if let waiter = state.waiter {
            state.waiter = nil
            waiter.resume(returning: chunk)
            return
        }
        state.chunks.append(chunk)
        state.bufferedBytes += chunk.count
        if !state.pausedByUs && state.bufferedBytes >= config.highWaterMark {
            state.pausedByUs = true
            enqueue(WireMessage(type: .stream, id: id, flags: [.response, .pause]))
        }
    }

    private func finish(_ state: StreamState) {
        state.finished = true
        if let waiter = state.waiter {
            state.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    private func fail(_ state: StreamState, with error: Swift.Error) {
        guard state.failure == nil, !state.finished else { return }
        state.failure = error
        // Errors discard buffered data (a destroyed Readable drops its
        // buffer); only a graceful END drains first.
        state.chunks.removeAll()
        state.head = 0
        state.bufferedBytes = 0
        if let waiter = state.waiter {
            state.waiter = nil
            waiter.resume(throwing: error)
        }
    }

    // Called by `ResponseStream`'s iterator. `nil` means EOF.
    func nextChunk(id: UInt64) async throws -> Data? {
        guard case .stream(let state)? = pending[id] else {
            // Already terminated and reaped (or torn down): EOF.
            return nil
        }

        if let failure = state.failure {
            pending.removeValue(forKey: id)
            throw failure
        }

        if let chunk = state.popChunk() {
            if state.pausedByUs && state.bufferedBytes <= config.lowWaterMark {
                state.pausedByUs = false
                enqueue(WireMessage(type: .stream, id: id, flags: [.response, .resume]))
            }
            return chunk
        }

        if state.finished {
            pending.removeValue(forKey: id)
            return nil
        }

        guard state.waiter == nil else {
            throw SessionError.protocolViolation("a stream supports a single consumer")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Re-check: the stream may have finished, died, or been
                // cancelled between the suspension points above and here.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let failure = state.failure {
                    continuation.resume(throwing: failure)
                } else if state.finished {
                    continuation.resume(returning: nil)
                } else {
                    state.waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelStream(id: id) }
        }
    }

    /// Consumer-initiated teardown: sends `DESTROY`, exactly what the
    /// reference client's incoming stream does when destroyed locally.
    func cancelStream(id: UInt64) {
        guard case .stream(let state)? = pending.removeValue(forKey: id) else { return }
        if closedReason == nil {
            enqueue(WireMessage(type: .stream, id: id, flags: [.response, .destroy]))
        }
        fail(state, with: CancellationError())
    }
}

// MARK: - ResponseStream

/// The chunks of a server-stream reply, as a pull-based `AsyncSequence`.
///
/// Pull-based is the point: demand flows from the consumer's `next()` into the
/// session, which is what makes `PAUSE`/`RESUME` real backpressure rather than
/// an unbounded buffer. Cancelling the consuming task sends `DESTROY` to the
/// worker. Single consumer.
public struct ResponseStream: AsyncSequence, Sendable {
    public typealias Element = Data

    let session: RPCSession
    let id: UInt64

    public func makeAsyncIterator() -> Iterator {
        Iterator(session: session, id: id)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let session: RPCSession
        let id: UInt64

        public mutating func next() async throws -> Data? {
            try await session.nextChunk(id: id)
        }
    }

    /// Explicit early teardown without cancelling the surrounding task.
    public func cancel() async {
        await session.cancelStream(id: id)
    }
}
