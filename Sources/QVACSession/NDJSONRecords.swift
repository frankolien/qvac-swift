import Foundation
import QVACWire

extension ResponseStream {
    /// The stream's payload as individual NDJSON records.
    ///
    /// QVAC streamed payloads are NDJSON *inside* the frames: one frame may
    /// carry several records and one record may span frames, so record
    /// boundaries and chunk boundaries are unrelated. The final record is
    /// flushed even when unterminated — the reference Python client explicitly
    /// emits a trailing record with no newline, and dropping it loses the last
    /// token of a generation.
    public func ndjsonRecords() -> NDJSONRecordStream {
        NDJSONRecordStream(chunks: self)
    }
}

/// `AsyncSequence` of NDJSON records reassembled from a `ResponseStream`.
public struct NDJSONRecordStream: AsyncSequence, Sendable {
    public typealias Element = Data

    let chunks: ResponseStream

    public func makeAsyncIterator() -> Iterator {
        Iterator(chunks: chunks.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        var chunks: ResponseStream.Iterator
        var splitter = NDJSONSplitter()
        var queued: [Data] = []
        var head = 0
        var flushed = false

        public mutating func next() async throws -> Data? {
            while true {
                if head < queued.count {
                    defer { head += 1 }
                    return queued[head]
                }
                queued.removeAll(keepingCapacity: true)
                head = 0

                guard !flushed else { return nil }

                if let chunk = try await chunks.next() {
                    queued = splitter.append(chunk)
                } else {
                    flushed = true
                    if let tail = splitter.flush() { return tail }
                    return nil
                }
            }
        }
    }
}
