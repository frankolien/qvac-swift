import Foundation

/// Reassembles length-prefixed frames from an arbitrarily chunked byte stream.
///
/// The transport hands us whatever the kernel or the worklet produced: one read
/// may carry half a frame, or forty frames, or one byte. Two invariants matter.
///
/// **Amortized O(n).** The naive version re-concatenates a growing buffer on
/// every chunk, which is O(chunks²). A 40 MB base64 audio payload arriving in
/// 8 KB reads is ~5000 concatenations averaging 20 MB — minutes of CPU burned
/// silently. Instead we keep one contiguous buffer with a moving read index and
/// drop the consumed prefix only once it exceeds half the buffer, so each byte
/// is copied a bounded number of times. This is the same trick the QVAC Python
/// client uses in its NDJSON reader, for the same reason.
///
/// **Drain fully after every append.** One read can contain many frames. A
/// decoder that returns only the first and waits for more bytes deadlocks the
/// moment the worker stops talking — which is exactly what it does after
/// sending a final frame.
public struct FrameDecoder {

    public enum Error: Swift.Error, Equatable {
        /// Guards against a corrupt or hostile length prefix driving an
        /// unbounded allocation. The prefix is attacker-controlled in the sense
        /// that a desynced stream produces arbitrary values.
        case frameTooLarge(Int, limit: Int)
    }

    private var buffer: Data
    private var readIndex: Int = 0
    /// Total frame size (prefix included) once known; `nil` while we are still
    /// waiting on the 4-byte prefix.
    private var pendingFrameSize: Int?

    public let maxFrameSize: Int

    /// - Parameter maxFrameSize: default 256 MiB. Model payloads and base64
    ///   audio are genuinely large, so this is generous by design; it exists to
    ///   bound corruption, not to enforce policy.
    public init(maxFrameSize: Int = 256 * 1024 * 1024) {
        self.maxFrameSize = maxFrameSize
        self.buffer = Data()
    }

    private static let prefixSize = 4

    /// Bytes buffered but not yet consumed.
    public var bufferedCount: Int { buffer.count - readIndex }

    /// Appends a chunk and returns every frame that is now complete.
    ///
    /// Returns `Data` copies rather than buffer views: the frames outlive this
    /// call and the buffer gets compacted underneath them. Copying once here is
    /// the correct trade — the alternative is a lifetime bug.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        if !chunk.isEmpty { buffer.append(chunk) }
        var frames: [Data] = []
        while let frame = try nextFrame() {
            frames.append(frame)
        }
        compactIfNeeded()
        return frames
    }

    /// Appends a chunk and yields decoded messages directly.
    public mutating func appendDecoding(_ chunk: Data) throws -> [WireMessage] {
        try append(chunk).map { try WireCodec.decode(frame: $0) }
    }

    private mutating func nextFrame() throws -> Data? {
        if pendingFrameSize == nil {
            guard bufferedCount >= Self.prefixSize else { return nil }
            let bodyLength = buffer.withUnsafeBytes { raw -> UInt32 in
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: readIndex, as: UInt32.self))
            }
            let total = Self.prefixSize + Int(bodyLength)
            guard total <= maxFrameSize else {
                throw Error.frameTooLarge(total, limit: maxFrameSize)
            }
            pendingFrameSize = total
        }

        guard let size = pendingFrameSize, bufferedCount >= size else { return nil }

        let start = readIndex
        readIndex += size
        pendingFrameSize = nil
        // `Data` slices carry non-zero start indices; re-base so callers can
        // index from 0 without surprises.
        return Data(buffer[start ..< start + size])
    }

    /// Drops the consumed prefix once it is worth the memmove. Amortized O(1)
    /// per byte: each byte moves at most once per doubling of the live region.
    private mutating func compactIfNeeded() {
        guard readIndex > 0 else { return }
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex >= buffer.count / 2 {
            buffer.removeSubrange(0 ..< readIndex)
            readIndex = 0
        }
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        readIndex = 0
        pendingFrameSize = nil
    }
}

/// Splits a byte stream into newline-delimited JSON records.
///
/// The second framing layer: streamed SDK payloads are NDJSON *inside*
/// `bare-rpc` frames, so one frame may hold several records and one record may
/// span frames. Same amortized-compaction discipline as `FrameDecoder`.
///
/// `flush()` is not optional. The QVAC Python client explicitly emits a
/// trailing unterminated record, so a stream whose last line lacks a newline
/// silently loses its final token without it.
public struct NDJSONSplitter {
    private var buffer: Data
    private var readIndex: Int = 0

    public init() { buffer = Data() }

    private static let newline: UInt8 = 0x0a

    public mutating func append(_ chunk: Data) -> [Data] {
        if !chunk.isEmpty { buffer.append(chunk) }
        var records: [Data] = []

        while true {
            guard let nl = indexOfNewline(from: readIndex) else { break }
            if nl > readIndex {
                let line = buffer[readIndex ..< nl]
                if !isBlank(line) { records.append(Data(line)) }
            }
            readIndex = nl + 1
        }

        if readIndex > 0 {
            if readIndex == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                readIndex = 0
            } else if readIndex >= buffer.count / 2 {
                buffer.removeSubrange(0 ..< readIndex)
                readIndex = 0
            }
        }
        return records
    }

    /// Emits any trailing record not terminated by a newline.
    public mutating func flush() -> Data? {
        guard readIndex < buffer.count else { return nil }
        let tail = buffer[readIndex ..< buffer.count]
        readIndex = buffer.count
        return isBlank(tail) ? nil : Data(tail)
    }

    /// Scans for the delimiter over a raw pointer rather than using
    /// `split(separator:)`, which allocates a `Data` per record.
    private func indexOfNewline(from start: Int) -> Int? {
        guard start < buffer.count else { return nil }
        return buffer.withUnsafeBytes { raw -> Int? in
            var i = start
            while i < raw.count {
                if raw[i] == Self.newline { return i }
                i += 1
            }
            return nil
        }
    }

    private func isBlank(_ slice: Data) -> Bool {
        slice.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0d || $0 == 0x0a }
    }
}
