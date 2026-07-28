import Foundation

/// An application-level error the worker reported *in band* — a
/// `{"type":"error", ...}` payload on the success path, distinct from
/// protocol-level RPC errors (`SessionError.remote`). Mirrors the JS
/// client's `reconstructError` so the typed taxonomy survives the boundary.
public struct QVACRemoteError: Swift.Error, Equatable, Sendable {
    public let response: ErrorResponse

    public init(response: ErrorResponse) {
        self.response = response
    }

    public var message: String { response.message }
    public var code: Int? { response.code.map(Int.init) }
    /// The symbolic name from the contract's error taxonomy, when known —
    /// e.g. 52401 → `MODEL_NOT_FOUND`-style names from `error-codes.json`.
    public var codeName: String? { code.flatMap(QVACErrorCodes.name(for:)) }
}

extension QVACRemoteError: CustomStringConvertible {
    public var description: String {
        var out = "QVACRemoteError(\(message)"
        if let code { out += ", code: \(codeName ?? String(code))" }
        return out + ")"
    }
}

/// Client-side failures that never touched the worker.
public enum QVACClientError: Swift.Error, Equatable, Sendable {
    /// A promoted call was made through the unary overload. The manifest's
    /// condition says this request streams progress; awaiting a single reply
    /// would hang. Use the `onProgress:` overload.
    case progressPromoted(method: String)
    /// A promoted stream ended without its final record.
    case missingFinalResponse(method: String)
    /// The `__init_config` handshake was rejected.
    case initializationFailed(String)
    /// A payload failed to decode as the contract's response type.
    case undecodableResponse(method: String, detail: String)
}
