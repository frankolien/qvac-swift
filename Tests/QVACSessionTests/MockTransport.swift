import Foundation
import QVACWire
@testable import QVACSession

/// A scriptable transport: tests play the worker's side of the conversation.
///
/// Sent frames are decoded back into `WireMessage`s and exposed as an ordered
/// stream, so a test reads the client's outbound traffic exactly as a worker
/// would — and can deliberately fragment its own inbound bytes to prove that
/// chunking carries no meaning.
final class MockTransport: Transport, @unchecked Sendable {
    let inbound: AsyncThrowingStream<Data, Swift.Error>
    private let inboundWriter: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private let sentMessages: AsyncStream<WireMessage>
    private let sentWriter: AsyncStream<WireMessage>.Continuation
    private var sentIterator: AsyncStream<WireMessage>.Iterator

    private(set) var closeCallCount = 0

    init() {
        (inbound, inboundWriter) = AsyncThrowingStream.makeStream(of: Data.self)
        (sentMessages, sentWriter) = AsyncStream.makeStream(of: WireMessage.self)
        sentIterator = sentMessages.makeAsyncIterator()
    }

    // MARK: - Transport

    func send(_ data: Data) async throws {
        sentWriter.yield(try WireCodec.decode(frame: data))
    }

    func close() async {
        closeCallCount += 1
        inboundWriter.finish()
    }

    // MARK: - Worker-side scripting

    /// Delivers a frame from the "worker", optionally shattered into
    /// `chunkSize`-byte reads.
    func inject(_ message: WireMessage, chunkSize: Int? = nil) {
        let frame = WireCodec.encode(message)
        guard let chunkSize, chunkSize < frame.count else {
            inboundWriter.yield(frame)
            return
        }
        var offset = 0
        while offset < frame.count {
            let end = min(offset + chunkSize, frame.count)
            inboundWriter.yield(frame.subdata(in: offset ..< end))
            offset = end
        }
    }

    /// Simulates carrier death: a read error (worker crashed mid-write).
    func failCarrier(_ error: Swift.Error) {
        inboundWriter.finish(throwing: error)
    }

    /// Simulates a clean EOF (worker exited).
    func endCarrier() {
        inboundWriter.finish()
    }

    /// Next frame the client sent, in order. Fails the test fast on a hang.
    func nextSent(timeout: TimeInterval = 2,
                  file: StaticString = #filePath, line: UInt = #line) async throws -> WireMessage {
        try await withTimeout(timeout, label: "waiting for a sent frame") {
            await self.sentIterator.next()!
        }
    }
}

struct TimeoutExceeded: Swift.Error { let label: String }

/// Races an operation against a deadline so a session bug hangs a test for
/// `seconds`, not forever.
func withTimeout<T: Sendable>(_ seconds: TimeInterval = 2,
                              label: String = "operation",
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutExceeded(label: label)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
