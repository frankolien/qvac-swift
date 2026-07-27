import Foundation

/// Message kinds on the wire. `bare-rpc/lib/constants.js`.
public enum MessageType: UInt64, Sendable, Equatable {
    case request = 1
    case response = 2
    case stream = 3
}

/// Stream control bits. A bitmask, not an enumeration — `OPEN | REQUEST` is a
/// single legitimate value (0x101), so modelling these as distinct cases would
/// be wrong.
///
/// `pause`/`resume` are the flow-control channel. Ignoring them makes a fast
/// token stream an unbounded buffer: it will pass every short test and fail on
/// a long generation.
public struct StreamFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let open     = StreamFlags(rawValue: 0x1)
    public static let close    = StreamFlags(rawValue: 0x2)
    public static let pause    = StreamFlags(rawValue: 0x4)
    public static let resume   = StreamFlags(rawValue: 0x8)
    public static let data     = StreamFlags(rawValue: 0x10)
    public static let end      = StreamFlags(rawValue: 0x20)
    public static let destroy  = StreamFlags(rawValue: 0x40)
    public static let error    = StreamFlags(rawValue: 0x80)
    public static let request  = StreamFlags(rawValue: 0x100)
    public static let response = StreamFlags(rawValue: 0x200)

    /// `stream == 0` is the sentinel for "unary", and is what gates whether a
    /// payload is present on request/response frames.
    public static let none = StreamFlags([])
    public var isUnary: Bool { rawValue == 0 }
}

/// Transport-level error carried in a frame header.
///
/// Distinct from an application error: the SDK reports those *in band* as a
/// JSON payload `{"type":"error", ...}` on the success path. Both must be
/// handled, and conflating them loses the typed error taxonomy.
public struct WireError: Error, Sendable, Equatable {
    public let message: String
    public let code: String
    public let errno: Int64

    public init(message: String, code: String = "", errno: Int64 = 0) {
        self.message = message
        self.code = code
        self.errno = errno
    }
}

/// One decoded `bare-rpc` frame.
public struct WireMessage: Sendable, Equatable {
    public var type: MessageType
    public var id: UInt64
    /// Present on `.request` only.
    public var command: UInt64?
    public var flags: StreamFlags
    public var payload: Data?
    public var error: WireError?

    public init(
        type: MessageType,
        id: UInt64,
        command: UInt64? = nil,
        flags: StreamFlags = .none,
        payload: Data? = nil,
        error: WireError? = nil
    ) {
        self.type = type
        self.id = id
        self.command = command
        self.flags = flags
        self.payload = payload
        self.error = error
    }

    /// A REQUEST with `id == 0` is a fire-and-forget event, not a request
    /// awaiting a reply. Dispatching it as a request leaks a continuation.
    public var isEvent: Bool { type == .request && id == 0 }

    // MARK: - Convenience constructors

    public static func request(id: UInt64, command: UInt64, payload: Data) -> WireMessage {
        WireMessage(type: .request, id: id, command: command, flags: .none, payload: payload)
    }

    public static func openStream(id: UInt64, command: UInt64, flags: StreamFlags) -> WireMessage {
        WireMessage(type: .request, id: id, command: command, flags: flags)
    }

    public static func streamData(id: UInt64, payload: Data) -> WireMessage {
        WireMessage(type: .stream, id: id, flags: .data, payload: payload)
    }

    public static func streamControl(id: UInt64, flags: StreamFlags) -> WireMessage {
        WireMessage(type: .stream, id: id, flags: flags)
    }
}

// MARK: - Codec

public enum WireCodec {

    public enum Error: Swift.Error, Equatable {
        case unknownMessageType(UInt64)
        case frameTooLarge(Int)
    }

    /// Serialises a message, length prefix included.
    ///
    /// Layout: `uint32 LE bodyLength` then the body. The prefix counts the body
    /// only — it does not count itself.
    public static func encode(_ message: WireMessage) -> Data {
        var body = Data()
        body.reserveCapacity(32 + (message.payload?.count ?? 0))

        CompactEncoding.encode(uint: message.type.rawValue, into: &body)
        CompactEncoding.encode(uint: message.id, into: &body)

        var hasPayload = false

        switch message.type {
        case .request:
            CompactEncoding.encode(uint: message.command ?? 0, into: &body)
            CompactEncoding.encode(uint: message.flags.rawValue, into: &body)
            hasPayload = message.flags.isUnary

        case .response:
            CompactEncoding.encode(bool: message.error != nil, into: &body)
            CompactEncoding.encode(uint: message.flags.rawValue, into: &body)
            if let error = message.error {
                encode(error: error, into: &body)
            } else {
                hasPayload = message.flags.isUnary
            }

        case .stream:
            CompactEncoding.encode(uint: message.flags.rawValue, into: &body)
            if message.flags.contains(.error) {
                encode(error: message.error ?? WireError(message: ""), into: &body)
            } else if message.flags.contains(.data) {
                hasPayload = true
            }
        }

        if hasPayload {
            CompactEncoding.encode(bytes: message.payload ?? Data(), into: &body)
        }

        var out = Data()
        out.reserveCapacity(body.count + 4)
        CompactEncoding.appendLE(UInt32(body.count), to: &out)
        out.append(body)
        return out
    }

    private static func encode(error: WireError, into body: inout Data) {
        CompactEncoding.encode(utf8: error.message, into: &body)
        CompactEncoding.encode(utf8: error.code, into: &body)
        CompactEncoding.encode(int: error.errno, into: &body)
    }

    /// Decodes one complete frame, length prefix included.
    ///
    /// Mirrors `bare-rpc`'s `_onmessage`, which is handed the frame *with* its
    /// prefix and re-reads the uint32 before parsing. Keeping that convention
    /// means offsets can be compared directly against the reference when
    /// debugging a desync.
    public static func decode(frame: UnsafeRawBufferPointer) throws -> WireMessage {
        var reader = ByteReader(frame, offset: 4)   // skip the length prefix

        let rawType = try reader.readUInt()
        guard let type = MessageType(rawValue: rawType) else {
            throw Error.unknownMessageType(rawType)
        }
        let id = try reader.readUInt()

        switch type {
        case .request:
            let command = try reader.readUInt()
            let flags = StreamFlags(rawValue: try reader.readUInt())
            let payload = flags.isUnary ? try reader.readData() : nil
            return WireMessage(type: .request, id: id, command: command, flags: flags, payload: payload)

        case .response:
            let isError = try reader.readBool()
            let flags = StreamFlags(rawValue: try reader.readUInt())
            if isError {
                return WireMessage(type: .response, id: id, flags: flags, error: try decodeError(&reader))
            }
            let payload = flags.isUnary ? try reader.readData() : nil
            return WireMessage(type: .response, id: id, flags: flags, payload: payload)

        case .stream:
            let flags = StreamFlags(rawValue: try reader.readUInt())
            if flags.contains(.error) {
                return WireMessage(type: .stream, id: id, flags: flags, error: try decodeError(&reader))
            }
            let payload = flags.contains(.data) ? try reader.readData() : nil
            return WireMessage(type: .stream, id: id, flags: flags, payload: payload)
        }
    }

    public static func decode(frame: Data) throws -> WireMessage {
        try frame.withUnsafeBytes { try decode(frame: $0) }
    }

    private static func decodeError(_ reader: inout ByteReader) throws -> WireError {
        WireError(
            message: try reader.readString(),
            code: try reader.readString(),
            errno: try reader.readInt()
        )
    }
}
