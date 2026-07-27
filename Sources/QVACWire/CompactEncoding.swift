import Foundation

/// Primitives from `holepunchto/compact-encoding`, the encoding `bare-rpc`
/// frames its headers with.
///
/// Verified byte-for-byte against the reference JS encoder across 85 vectors
/// including every varint width boundary. See `Tests/Fixtures/fixture.json`.
public enum CompactEncoding {

    // MARK: - Errors

    public enum DecodeError: Error, Equatable {
        /// The buffer ended mid-value. With a length-prefixed frame this means
        /// the frame is malformed, not that more bytes are coming — the framing
        /// layer above guarantees a complete frame before we ever decode.
        case truncated(needed: Int, available: Int)
        case invalidUTF8
        case valueTooLarge
    }

    // MARK: - Unsigned varint (Bitcoin-style CompactSize, little-endian)
    //
    //   n <= 0xfc          1 byte
    //   n <= 0xffff        0xfd + uint16 LE
    //   n <= 0xffffffff    0xfe + uint32 LE
    //   otherwise          0xff + uint64 LE

    @inline(__always)
    public static func encodedSize(uint n: UInt64) -> Int {
        if n <= 0xfc { return 1 }
        if n <= 0xffff { return 3 }
        if n <= 0xffff_ffff { return 5 }
        return 9
    }

    @inline(__always)
    public static func encode(uint n: UInt64, into out: inout Data) {
        if n <= 0xfc {
            out.append(UInt8(n))
        } else if n <= 0xffff {
            out.append(0xfd)
            appendLE(UInt16(n), to: &out)
        } else if n <= 0xffff_ffff {
            out.append(0xfe)
            appendLE(UInt32(n), to: &out)
        } else {
            out.append(0xff)
            appendLE(n, to: &out)
        }
    }

    // MARK: - Signed varint (zigzag over the unsigned varint)
    //
    // Established empirically against the reference encoder: errno 52401
    // encodes as 104802, and -3 encodes as 5. Positive n maps to 2n, negative
    // to -2n-1, so small magnitudes stay in one byte regardless of sign.

    @inline(__always)
    public static func zigzag(_ n: Int64) -> UInt64 {
        n >= 0 ? UInt64(n) &* 2 : (UInt64(-(n &+ 1)) &* 2) &+ 1
    }

    @inline(__always)
    public static func unzigzag(_ u: UInt64) -> Int64 {
        (u & 1) == 1 ? -Int64(u / 2) - 1 : Int64(u / 2)
    }

    @inline(__always)
    public static func encode(int n: Int64, into out: inout Data) {
        encode(uint: zigzag(n), into: &out)
    }

    // MARK: - Composites

    /// Length-prefixed bytes: varint byte count, then the raw bytes.
    @inline(__always)
    public static func encode(bytes: Data, into out: inout Data) {
        encode(uint: UInt64(bytes.count), into: &out)
        out.append(bytes)
    }

    /// Length-prefixed UTF-8: varint *byte* count (not character count).
    @inline(__always)
    public static func encode(utf8 string: String, into out: inout Data) {
        encode(bytes: Data(string.utf8), into: &out)
    }

    /// Booleans are a single raw byte, not a varint.
    @inline(__always)
    public static func encode(bool flag: Bool, into out: inout Data) {
        out.append(flag ? 1 : 0)
    }

    // MARK: - Little-endian helpers

    @inline(__always)
    static func appendLE<T: FixedWidthInteger>(_ value: T, to out: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }
}

// MARK: - Reader

/// A cursor over a raw byte buffer.
///
/// Deliberately operates on `UnsafeRawBufferPointer` and integer offsets: the
/// decode path runs once per frame on every streamed token, so it must not
/// allocate. `Data.subdata` would copy on each field read.
public struct ByteReader {
    public let buffer: UnsafeRawBufferPointer
    public var offset: Int

    @inline(__always)
    public init(_ buffer: UnsafeRawBufferPointer, offset: Int = 0) {
        self.buffer = buffer
        self.offset = offset
    }

    @inline(__always)
    public var remaining: Int { buffer.count - offset }

    @inline(__always)
    mutating func require(_ n: Int) throws {
        guard remaining >= n else {
            throw CompactEncoding.DecodeError.truncated(needed: n, available: remaining)
        }
    }

    @inline(__always)
    public mutating func readByte() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return buffer[offset]
    }

    @inline(__always)
    mutating func readLE<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        try require(size)
        defer { offset += size }
        // loadUnaligned: frame payloads carry no alignment guarantee.
        return T(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: T.self))
    }

    @inline(__always)
    public mutating func readUInt() throws -> UInt64 {
        let tag = try readByte()
        switch tag {
        case 0xfd: return UInt64(try readLE(UInt16.self))
        case 0xfe: return UInt64(try readLE(UInt32.self))
        case 0xff: return try readLE(UInt64.self)
        default: return UInt64(tag)
        }
    }

    @inline(__always)
    public mutating func readInt() throws -> Int64 {
        CompactEncoding.unzigzag(try readUInt())
    }

    @inline(__always)
    public mutating func readBool() throws -> Bool {
        try readByte() != 0
    }

    /// Returns a *view* into the underlying buffer — no copy. Callers that need
    /// to outlive the buffer must copy explicitly (see `readData`).
    @inline(__always)
    public mutating func readSlice() throws -> UnsafeRawBufferPointer {
        let count = try readUInt()
        guard count <= UInt64(Int.max) else { throw CompactEncoding.DecodeError.valueTooLarge }
        let n = Int(count)
        try require(n)
        defer { offset += n }
        return UnsafeRawBufferPointer(rebasing: buffer[offset ..< offset + n])
    }

    @inline(__always)
    public mutating func readData() throws -> Data {
        Data(try readSlice())
    }

    @inline(__always)
    public mutating func readString() throws -> String {
        let slice = try readSlice()
        guard let s = String(bytes: slice, encoding: .utf8) else {
            throw CompactEncoding.DecodeError.invalidUTF8
        }
        return s
    }
}
