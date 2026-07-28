import XCTest
import QVACWire
@testable import QVACSession

/// The session invariants, proven through a scripted transport: multiplexing,
/// the life signal (transport death fails everything pending, immediately),
/// PAUSE/RESUME backpressure with hysteresis, and cancellation in both
/// directions. No Bare binary, no sockets — the mock plays the worker.
final class RPCSessionTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    /// One pull from the stream, deadline-guarded. `ResponseStream`'s iterator
    /// is stateless — all receive state lives in the session — so a fresh
    /// iterator per pull is equivalent to holding one.
    private func nextChunk(_ stream: ResponseStream) async throws -> Data? {
        try await withTimeout {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
    }

    struct CarrierDied: Swift.Error {}

    // MARK: - Unary calls

    func testUnaryCallResolvesWithReply() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let call = Task { try await session.call(command: 12, payload: self.data("ping")) }

        let request = try await mock.nextSent()
        XCTAssertEqual(request.type, .request)
        XCTAssertEqual(request.command, 12)
        XCTAssertEqual(request.flags, .none)
        XCTAssertEqual(request.payload, data("ping"))
        XCTAssertEqual(request.id, 1)

        // Reply shattered into one-byte reads: chunking carries no meaning.
        mock.inject(
            WireMessage(type: .response, id: request.id, flags: .none, payload: data("pong")),
            chunkSize: 1
        )

        let reply = try await withTimeout { try await call.value }
        XCTAssertEqual(reply, data("pong"))
        await session.shutdown()
    }

    func testOutOfOrderRepliesResolveTheRightCalls() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let first = Task { try await session.call(command: 1, payload: self.data("a")) }
        let second = Task { try await session.call(command: 2, payload: self.data("b")) }

        // The tasks race for ids; identify each request by its command.
        let sentA = try await mock.nextSent()
        let sentB = try await mock.nextSent()
        let byCommand = [sentA.command!: sentA, sentB.command!: sentB]

        // Answer in reverse order of the commands.
        mock.inject(WireMessage(type: .response, id: byCommand[2]!.id, flags: .none, payload: data("two")))
        mock.inject(WireMessage(type: .response, id: byCommand[1]!.id, flags: .none, payload: data("one")))

        let firstReply = try await withTimeout { try await first.value }
        let secondReply = try await withTimeout { try await second.value }
        XCTAssertEqual(firstReply, data("one"))
        XCTAssertEqual(secondReply, data("two"))
        await session.shutdown()
    }

    func testErrorResponseThrowsRemoteError() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let call = Task { try await session.call(command: 3, payload: Data()) }
        let request = try await mock.nextSent()

        let wireError = WireError(message: "boom", code: "EFAIL", errno: -3)
        mock.inject(WireMessage(type: .response, id: request.id, flags: .none, error: wireError))

        do {
            _ = try await withTimeout { try await call.value }
            XCTFail("expected a remote error")
        } catch let error as SessionError {
            XCTAssertEqual(error, .remote(wireError))
        }
        await session.shutdown()
    }

    func testUnaryCancellationAbandonsTheCall() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let call = Task { try await session.call(command: 4, payload: Data()) }
        let request = try await mock.nextSent()

        call.cancel()
        do {
            _ = try await withTimeout { try await call.value }
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch let error as TimeoutExceeded {
            XCTFail("call hung after cancellation: \(error)")
        }

        // A late reply for the abandoned id falls into the void…
        mock.inject(WireMessage(type: .response, id: request.id, flags: .none, payload: data("late")))

        // …and the session stays healthy for the next call.
        let next = Task { try await session.call(command: 5, payload: Data()) }
        let nextRequest = try await mock.nextSent()
        mock.inject(WireMessage(type: .response, id: nextRequest.id, flags: .none, payload: data("ok")))
        let reply = try await withTimeout { try await next.value }
        XCTAssertEqual(reply, data("ok"))
        await session.shutdown()
    }

    // MARK: - The life signal

    func testTransportDeathFailsEverythingPendingImmediately() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let first = Task { try await session.call(command: 1, payload: Data()) }
        let second = Task { try await session.call(command: 2, payload: Data()) }
        _ = try await mock.nextSent()
        _ = try await mock.nextSent()

        mock.failCarrier(CarrierDied())

        // Both pending calls fail *now* — not after a timeout, not never,
        // which is the documented bare-rpc hazard this layer exists to fix.
        for task in [first, second] {
            do {
                _ = try await withTimeout { try await task.value }
                XCTFail("expected the pending call to fail on transport death")
            } catch let error as SessionError {
                guard case .closed = error else { return XCTFail("unexpected: \(error)") }
            } catch let error as TimeoutExceeded {
                XCTFail("pending call hung on a dead transport: \(error)")
            }
        }

        // And every future call is rejected outright.
        do {
            _ = try await session.call(command: 3, payload: Data())
            XCTFail("expected an immediate rejection")
        } catch let error as SessionError {
            guard case .closed = error else { return XCTFail("unexpected: \(error)") }
        }
    }

    func testCleanEOFAlsoTearsDown() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let call = Task { try await session.call(command: 1, payload: Data()) }
        _ = try await mock.nextSent()

        mock.endCarrier()

        do {
            _ = try await withTimeout { try await call.value }
            XCTFail("expected failure on clean EOF")
        } catch let error as SessionError {
            guard case .closed = error else { return XCTFail("unexpected: \(error)") }
        }
    }

    // MARK: - Server streams

    func testServerStreamDeliversChunksThenEOF() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let stream = try await session.serverStream(command: 30, payload: data("req"))

        let request = try await mock.nextSent()
        XCTAssertEqual(request.type, .request)
        XCTAssertEqual(request.payload, data("req"))
        let open = try await mock.nextSent()
        XCTAssertEqual(open.type, .stream)
        XCTAssertEqual(open.flags, [.response, .open])

        mock.inject(WireMessage(type: .stream, id: request.id, flags: [.response, .data], payload: data("a")))
        mock.inject(WireMessage(type: .stream, id: request.id, flags: [.response, .data], payload: data("b")))
        mock.inject(WireMessage(type: .stream, id: request.id, flags: [.response, .end]))

        let chunks = try await withTimeout {
            var out: [Data] = []
            for try await chunk in stream { out.append(chunk) }
            return out
        }
        XCTAssertEqual(chunks, [data("a"), data("b")])
        await session.shutdown()
    }

    func testEarlyENDStillDrainsBufferedChunks() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let stream = try await session.serverStream(command: 31, payload: Data())
        let request = try await mock.nextSent()
        _ = try await mock.nextSent()  // OPEN

        // Producer finishes before the consumer reads a single byte.
        mock.inject(WireMessage(type: .stream, id: request.id, flags: [.response, .data], payload: data("x")))
        mock.inject(WireMessage(type: .stream, id: request.id, flags: [.response, .data], payload: data("y")))
        mock.inject(WireMessage(type: .stream, id: request.id, flags: [.response, .end]))

        let chunks = try await withTimeout {
            var out: [Data] = []
            for try await chunk in stream { out.append(chunk) }
            return out
        }
        XCTAssertEqual(chunks, [data("x"), data("y")], "END must not truncate buffered chunks")
        await session.shutdown()
    }

    func testGracefulCloseIsEOF() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let stream = try await session.serverStream(command: 32, payload: Data())
        let request = try await mock.nextSent()
        _ = try await mock.nextSent()  // OPEN

        // CLOSE without an error is how a destroyed-but-not-failed worker
        // stream reads on this side: a graceful end.
        mock.inject(WireMessage(type: .stream, id: request.id, flags: [.response, .close]))

        let chunks = try await withTimeout {
            var out: [Data] = []
            for try await chunk in stream { out.append(chunk) }
            return out
        }
        XCTAssertEqual(chunks, [])
        await session.shutdown()
    }

    func testStreamRemoteErrorThrows() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let stream = try await session.serverStream(command: 33, payload: Data())
        let request = try await mock.nextSent()
        _ = try await mock.nextSent()  // OPEN

        let wireError = WireError(message: "model exploded", code: "EMODEL", errno: 52401)
        mock.inject(WireMessage(
            type: .stream, id: request.id,
            flags: [.response, .close, .error], error: wireError
        ))

        do {
            _ = try await withTimeout {
                var out: [Data] = []
                for try await chunk in stream { out.append(chunk) }
                return out
            }
            XCTFail("expected the stream to throw")
        } catch let error as SessionError {
            XCTAssertEqual(error, .remote(wireError))
        }
        await session.shutdown()
    }

    func testUnaryResponseToStreamCallFailsFast() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let stream = try await session.serverStream(command: 34, payload: Data())
        let request = try await mock.nextSent()
        _ = try await mock.nextSent()  // OPEN

        // A server bug in the reference leaves this stream hanging forever;
        // this client turns it into a loud protocol violation.
        mock.inject(WireMessage(type: .response, id: request.id, flags: .none, payload: data("oops")))

        do {
            _ = try await withTimeout {
                var out: [Data] = []
                for try await chunk in stream { out.append(chunk) }
                return out
            }
            XCTFail("expected a protocol violation")
        } catch let error as SessionError {
            guard case .protocolViolation = error else { return XCTFail("unexpected: \(error)") }
        } catch let error as TimeoutExceeded {
            XCTFail("stream hung on a unary response: \(error)")
        }
        await session.shutdown()
    }

    // MARK: - Backpressure

    func testPauseAtHighWaterResumeAtLowWater() async throws {
        let mock = MockTransport()
        let session = RPCSession(
            transport: mock,
            configuration: .init(highWaterMark: 100, lowWaterMark: 20)
        )

        let stream = try await session.serverStream(command: 40, payload: Data())
        let request = try await mock.nextSent()
        _ = try await mock.nextSent()  // OPEN

        // Three 40-byte chunks: buffered hits 120 ≥ 100 on the third, so the
        // session pauses the producer exactly once.
        let chunk = Data(repeating: 0x61, count: 40)
        for _ in 0 ..< 3 {
            mock.inject(WireMessage(type: .stream, id: request.id, flags: [.response, .data], payload: chunk))
        }
        let pause = try await mock.nextSent()
        XCTAssertEqual(pause.type, .stream)
        XCTAssertEqual(pause.flags, [.response, .pause], "expected PAUSE at the high-water mark")

        // Draining to 0 ≤ 20 releases it: RESUME, exactly once, after the
        // third pop — the hysteresis gap is what prevents per-chunk thrash.
        for _ in 0 ..< 3 {
            let popped = try await nextChunk(stream)
            XCTAssertEqual(popped, chunk)
        }
        let resume = try await mock.nextSent()
        XCTAssertEqual(resume.flags, [.response, .resume], "expected RESUME at the low-water mark")

        mock.inject(WireMessage(type: .stream, id: request.id, flags: [.response, .end]))
        let tail = try await nextChunk(stream)
        XCTAssertNil(tail)
        await session.shutdown()
    }

    // MARK: - Consumer-side teardown

    func testCancellingTheConsumerSendsDESTROY() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let stream = try await session.serverStream(command: 50, payload: Data())
        _ = try await mock.nextSent()  // REQUEST
        _ = try await mock.nextSent()  // OPEN

        let consumer = Task { () -> Bool in
            do {
                for try await _ in stream {}
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        consumer.cancel()

        let destroy = try await mock.nextSent()
        XCTAssertEqual(destroy.type, .stream)
        XCTAssertEqual(destroy.flags, [.response, .destroy])
        let sawCancellation = await consumer.value
        XCTAssertTrue(sawCancellation)
        await session.shutdown()
    }

    func testExplicitCancelSendsDESTROY() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let stream = try await session.serverStream(command: 51, payload: Data())
        _ = try await mock.nextSent()  // REQUEST
        _ = try await mock.nextSent()  // OPEN

        await stream.cancel()

        let destroy = try await mock.nextSent()
        XCTAssertEqual(destroy.flags, [.response, .destroy])
        await session.shutdown()
    }

    // MARK: - Events and worker-initiated calls

    func testEventGoesOutWithIDZero() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        try await session.sendEvent(command: 9, payload: data("fire"))

        let event = try await mock.nextSent()
        XCTAssertEqual(event.type, .request)
        XCTAssertEqual(event.id, 0)
        XCTAssertEqual(event.command, 9)
        XCTAssertEqual(event.payload, data("fire"))
        await session.shutdown()
    }

    func testInboundEventReachesHandlerAsEvent() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let (calls, callsWriter) = AsyncStream.makeStream(of: InboundCall.self)
        await session.setInboundHandler { call in
            callsWriter.yield(call)
            return nil
        }

        mock.inject(WireMessage(type: .request, id: 0, command: 5, flags: .none, payload: data("evt")))

        let call = try await withTimeout { () -> InboundCall in
            var iterator = calls.makeAsyncIterator()
            return await iterator.next()!
        }
        XCTAssertTrue(call.isEvent)
        XCTAssertEqual(call.command, 5)
        XCTAssertEqual(call.payload, data("evt"))
        await session.shutdown()
    }

    func testInboundRequestGetsTheHandlersReply() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        await session.setInboundHandler { call in
            call.isEvent ? nil : Data("pong-\(call.command)".utf8)
        }

        mock.inject(WireMessage(type: .request, id: 77, command: 6, flags: .none, payload: data("ping")))

        let response = try await mock.nextSent()
        XCTAssertEqual(response.type, .response)
        XCTAssertEqual(response.id, 77)
        XCTAssertEqual(response.payload, data("pong-6"))
        await session.shutdown()
    }

    // MARK: - NDJSON record layer

    func testNDJSONRecordsReassembleAcrossChunksAndFlushTheTail() async throws {
        let mock = MockTransport()
        let session = RPCSession(transport: mock)

        let stream = try await session.serverStream(command: 60, payload: Data())
        let request = try await mock.nextSent()
        _ = try await mock.nextSent()  // OPEN

        // Record boundaries deliberately disagree with chunk boundaries, and
        // the final record has no trailing newline — the exact shape the
        // reference Python client produces.
        for piece in ["{\"a\":1}\n{\"b", "\":2}\n\n{\"c\":3}"] {
            mock.inject(WireMessage(
                type: .stream, id: request.id,
                flags: [.response, .data], payload: data(piece)
            ))
        }
        mock.inject(WireMessage(type: .stream, id: request.id, flags: [.response, .end]))

        let records = try await withTimeout {
            var out: [Data] = []
            for try await record in stream.ndjsonRecords() { out.append(record) }
            return out
        }
        XCTAssertEqual(records, [data("{\"a\":1}"), data("{\"b\":2}"), data("{\"c\":3}")])
        await session.shutdown()
    }
}
