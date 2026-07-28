import Foundation

// MARK: - Methods

extension Codegen {

    func emitMethods() throws -> String {
        var out = """
        /// The 37-method contract surface, one Swift method per manifest
        /// entry. Bodies delegate to the hand-written core (`unaryCall`,
        /// `streamCall`, `progressCall`) — the generated layer contains no
        /// transport logic at all.
        extension QVACClient {

        """

        struct Entry { let name: String; let source: String }
        var entries: [Entry] = []

        for method in methods {
            guard let name = method["name"]?.stringValue,
                  let callShape = method["callShape"]?.stringValue,
                  let requestRef = method["requestSchema"]?.stringValue,
                  let responseRef = method["responseSchema"]?.stringValue else {
                throw CodegenError.malformedContract("manifest entry missing fields: \(method)")
            }
            let requestType = try titleOfRef(requestRef, context: name)
            let responseType = try titleOfRef(responseRef, context: name)
            var source = ""

            switch callShape {
            case "request-reply":
                if let progress = method["progress"] {
                    let progressType = try titleOfRef(
                        progress["responseSchema"]!.stringValue!, context: "\(name).progress")
                    let progressTag = try constType(ofRef: progress["responseSchema"]!.stringValue!, context: name)
                    let finalTag = try constType(ofRef: responseRef, context: name)
                    source += """
                        /// `\(name)` — request-reply. Promotes to a progress stream when the
                        /// manifest condition holds; this overload requires that it does NOT
                        /// (it throws `QVACClientError.progressPromoted` instead of hanging
                        /// on a streamed reply).
                        public func \(name)(_ request: \(requestType)) async throws -> \(responseType) {
                            try await unaryGuardedCall(request, method: \(quoted(name)))
                        }

                        /// `\(name)` with progress reporting — the manifest's promoted
                        /// call shape. Requires a request the promotion condition accepts
                        /// (`withProgress == true`, plus the operation gate where one exists).
                        public func \(name)(
                            _ request: \(requestType),
                            onProgress: @escaping @Sendable (\(progressType)) -> Void
                        ) async throws -> \(responseType) {
                            try await progressCall(
                                request, method: \(quoted(name)),
                                finalTag: \(quoted(finalTag)), progressTag: \(quoted(progressTag)),
                                onProgress: onProgress)
                        }
                    """
                } else {
                    source += """
                        /// `\(name)` — request-reply.
                        public func \(name)(_ request: \(requestType)) async throws -> \(responseType) {
                            try await unaryCall(request)
                        }
                    """
                }

            case "server-stream":
                source += """
                    /// `\(name)` — server-stream: one request, NDJSON records back.
                    public func \(name)(_ request: \(requestType)) async throws -> AsyncThrowingStream<\(responseType), Swift.Error> {
                        try await streamCall(request)
                    }
                """

            case "duplex":
                source += """
                    /// `\(name)` — duplex: the request goes out as the stream's first
                    /// record; send continuation records and read typed responses on
                    /// the returned handle.
                    public func \(name)(_ request: \(requestType)) async throws -> QVACDuplexCall<\(responseType)> {
                        try await duplexCall(request)
                    }
                """

            default:
                throw CodegenError.malformedContract("unknown callShape '\(callShape)' on \(name)")
            }
            entries.append(Entry(name: name, source: source))
        }

        out += entries
            .sorted { $0.name < $1.name }
            .map(\.source)
            .joined(separator: "\n\n")
        out += "\n}"
        return out
    }

    private func titleOfRef(_ ref: String, context: String) throws -> String {
        guard let defName = ref.components(separatedBy: "$defs/").last,
              let def = defs[defName],
              let title = def["title"]?.stringValue else {
            throw CodegenError.malformedContract("cannot resolve schema ref '\(ref)' for \(context)")
        }
        return title
    }

    /// The `type` const of a response def — the tag that partitions progress
    /// records from the final record in a promoted stream. Union responses
    /// qualify when every arm agrees (`rag.response`: nine arms, all
    /// `type: "rag"`).
    private func constType(ofRef ref: String, context: String) throws -> String {
        guard let defName = ref.components(separatedBy: "$defs/").last, let def = defs[defName] else {
            throw CodegenError.malformedContract("\(context): cannot resolve '\(ref)'")
        }
        if let tag = def["properties"]?["type"]?["const"]?.stringValue { return tag }
        if let arms = (def["oneOf"] ?? def["anyOf"])?.arrayValue {
            let tags = Set(arms.compactMap { $0["properties"]?["type"]?["const"]?.stringValue })
            if tags.count == 1, arms.count > 0 { return tags.first! }
        }
        throw CodegenError.malformedContract(
            "\(context): '\(ref)' has no unanimous `type` const — progress partitioning needs one")
    }

    // MARK: - Error codes

    func emitErrorCodes() -> String {
        var out = """
        /// The contract's error taxonomy (`error-codes.json`): name → numeric
        /// code per category, plus a reverse lookup for diagnostics.
        public enum QVACErrorCodes {

        """
        var reverse: [(Int, String)] = []
        for category in errorCodes.keys.sorted() {
            guard let table = errorCodes[category]?.objectValue else { continue }
            out += "    public static let \(identifier(from: category)): [String: Int] = [\n"
            for name in table.keys.sorted() {
                if case .number(let value)? = table[name] {
                    let code = Int(value)
                    out += "        \(quoted(name)): \(code),\n"
                    reverse.append((code, name))
                }
            }
            out += "    ]\n\n"
        }
        out += "    private static let names: [Int: String] = [\n"
        for (code, name) in reverse.sorted(by: { $0.0 < $1.0 }) {
            out += "        \(code): \(quoted(name)),\n"
        }
        out += """
            ]

            /// The symbolic name for a wire error code, if the contract knows it.
            public static func name(for code: Int) -> String? { names[code] }
        }
        """
        return out
    }
}

// MARK: - Naming

func pascal(_ raw: String) -> String {
    raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined()
}

func identifier(from raw: String) -> String {
    // SCREAMING_CASE varnames (ERROR, MODEL_NOT_FOUND) camelize sensibly only
    // after lowercasing; mixed-case input keeps its interior capitalization.
    let normalized = raw == raw.uppercased() ? raw.lowercased() : raw
    let pascalCased = pascal(normalized)
    guard let first = pascalCased.first else { return "_" }
    var name = first.lowercased() + pascalCased.dropFirst()
    if name.first!.isNumber { name = "_" + name }
    return name
}

private let swiftKeywords: Set<String> = [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
    "func", "import", "init", "inout", "internal", "let", "open", "operator",
    "private", "protocol", "public", "rethrows", "static", "struct",
    "subscript", "typealias", "var", "break", "case", "continue", "default",
    "defer", "do", "else", "fallthrough", "for", "guard", "if", "in",
    "repeat", "return", "switch", "where", "while", "as", "catch", "false",
    "is", "nil", "self", "super", "throw", "throws", "true", "try"
]

func escaped(_ name: String) -> String {
    swiftKeywords.contains(name) ? "`\(name)`" : name
}

func quoted(_ string: String) -> String {
    var out = "\""
    for character in string.unicodeScalars {
        switch character {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default: out.unicodeScalars.append(character)
        }
    }
    return out + "\""
}

/// A stable case name for a shape-union arm, derived from its Swift type.
func caseName(forTypeExpression type: String) -> String {
    var bare = type
    if bare.hasSuffix("?") { bare.removeLast() }
    if bare.hasPrefix("[String: ") { return "dictionary" }
    if bare.hasPrefix("[") {
        let element = String(bare.dropFirst().dropLast())
        return caseName(forTypeExpression: element) + "Array"
    }
    switch bare {
    case "String": return "string"
    case "Double": return "number"
    case "Int": return "int"
    case "Bool": return "bool"
    case "JSONValue": return "value"
    default: return identifier(from: bare)
    }
}

func sanitizeDocLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
}
