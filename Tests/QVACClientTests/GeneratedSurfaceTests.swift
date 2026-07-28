import XCTest
import QVACWire
import QVACSession
import QVACCodegenCore
@testable import QVACClient

/// The generated surface, checked three ways: the generator's acceptance
/// criteria (deterministic, current), the hand-written progress predicates
/// against the manifest's verbatim JS conditions, and the types themselves
/// against wire-shaped JSON.
final class GeneratedSurfaceTests: XCTestCase {

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // GeneratedSurfaceTests.swift
        .deletingLastPathComponent()   // QVACClientTests
        .deletingLastPathComponent()   // Tests

    // MARK: - Generator acceptance criteria

    func testGenerationIsDeterministicAndCurrent() throws {
        let contract = Self.packageRoot.appendingPathComponent("contract")
        let first = try Codegen.generate(contractDirectory: contract)
        let second = try Codegen.generate(contractDirectory: contract)

        XCTAssertEqual(first.files.keys.sorted(), second.files.keys.sorted())
        for (name, content) in first.files {
            XCTAssertEqual(content, second.files[name], "\(name) differs between two runs")
        }

        // What's committed must be exactly what the contract produces — the
        // `contract:check` guarantee, as a test.
        let generated = Self.packageRoot.appendingPathComponent("Sources/QVACClient/Generated")
        for (name, content) in first.files {
            let committed = try String(contentsOf: generated.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(committed, content, "\(name) is stale — run `swift run qvac-codegen`")
        }
    }

    func testProgressConditionsMatchManifestVerbatim() throws {
        let manifestURL = Self.packageRoot.appendingPathComponent("contract/manifest.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        let methods = manifest["methods"] as! [[String: Any]]

        var upstream: [String: String] = [:]
        for method in methods {
            if let progress = method["progress"] as? [String: Any] {
                upstream[method["name"] as! String] = (progress["condition"] as! String)
            }
        }
        // Same four methods, same strings, character for character. A contract
        // update that touches a condition fails here instead of silently
        // skewing call shapes.
        XCTAssertEqual(upstream, ProgressPredicates.manifestConditions)
    }

    func testProgressPredicateSemantics() {
        // withProgress is the master gate.
        XCTAssertFalse(ProgressPredicates.promotes(method: "loadModel", withProgress: nil, operation: nil))
        XCTAssertFalse(ProgressPredicates.promotes(method: "loadModel", withProgress: false, operation: nil))
        XCTAssertTrue(ProgressPredicates.promotes(method: "loadModel", withProgress: true, operation: nil))
        XCTAssertTrue(ProgressPredicates.promotes(method: "downloadAsset", withProgress: true, operation: nil))
        // finetune: start, resume, or absent.
        XCTAssertTrue(ProgressPredicates.promotes(method: "finetune", withProgress: true, operation: nil))
        XCTAssertTrue(ProgressPredicates.promotes(method: "finetune", withProgress: true, operation: "start"))
        XCTAssertFalse(ProgressPredicates.promotes(method: "finetune", withProgress: true, operation: "stop"))
        // rag: the three ingest-shaped operations only.
        XCTAssertTrue(ProgressPredicates.promotes(method: "rag", withProgress: true, operation: "ingest"))
        XCTAssertFalse(ProgressPredicates.promotes(method: "rag", withProgress: true, operation: "search"))
        XCTAssertFalse(ProgressPredicates.promotes(method: "rag", withProgress: true, operation: nil))
        // Non-promotable methods never promote.
        XCTAssertFalse(ProgressPredicates.promotes(method: "embed", withProgress: true, operation: nil))
    }

    // MARK: - Generated types against wire-shaped JSON

    func testEnumsUseContractVarnames() {
        XCTAssertEqual(ModelType.llamacppCompletion.rawValue, "llamacpp-completion")
        XCTAssertEqual(Verbosity.error.rawValue, 0)
        XCTAssertEqual(Verbosity.debug.rawValue, 3)
    }

    func testRagRequestRoundTripsThroughItsDiscriminator() throws {
        let request = RagRequest.search(RagRequestSearch(modelId: "m1", query: "what is bare-rpc?"))
        let encoded = try QVACClient.encode(request)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertEqual(json["operation"] as? String, "search")
        XCTAssertEqual(json["type"] as? String, "rag")

        let decoded = try JSONDecoder().decode(RagRequest.self, from: encoded)
        XCTAssertEqual(decoded, request)
    }

    func testErrorCodesTableAndReverseLookup() {
        XCTAssertEqual(QVACErrorCodes.server["ARCHIVE_EXTRACTION_FAILED"], 53011)
        XCTAssertEqual(QVACErrorCodes.name(for: 53011), "ARCHIVE_EXTRACTION_FAILED")
        XCTAssertFalse(QVACErrorCodes.client.isEmpty)
        XCTAssertFalse(QVACErrorCodes.registry.isEmpty)
    }

    func testInBandErrorGate() throws {
        let payload = Data(#"{"type":"error","message":"model exploded","code":53011}"#.utf8)
        do {
            let _: HeartbeatResponse = try QVACClient.decodeResponse(payload)
            XCTFail("expected the error gate to throw")
        } catch let error as QVACRemoteError {
            XCTAssertEqual(error.message, "model exploded")
            XCTAssertEqual(error.codeName, "ARCHIVE_EXTRACTION_FAILED")
        }
    }

    // MARK: - End to end over a scripted transport

    /// Answers each decoded request via a script — the worker side of the
    /// conversation, three layers below the typed API.
    final class ScriptedTransport: Transport, @unchecked Sendable {
        let inbound: AsyncThrowingStream<Data, Swift.Error>
        private let writer: AsyncThrowingStream<Data, Swift.Error>.Continuation
        private let respond: @Sendable (WireMessage) -> [WireMessage]

        init(respond: @escaping @Sendable (WireMessage) -> [WireMessage]) {
            (inbound, writer) = AsyncThrowingStream.makeStream(of: Data.self)
            self.respond = respond
        }

        func send(_ data: Data) async throws {
            for reply in respond(try WireCodec.decode(frame: data)) {
                writer.yield(WireCodec.encode(reply))
            }
        }

        func close() async { writer.finish() }
    }

    func testHandshakeThenTypedCallThenRemoteError() async throws {
        let transport = ScriptedTransport { message in
            guard message.type == .request, let payload = message.payload else { return [] }
            let text = String(decoding: payload, as: UTF8.self)

            if text.contains("__init_config") {
                // The handshake rides the very first command a client sends.
                XCTAssertEqual(message.command, 1)
                return [WireMessage(type: .response, id: message.id, flags: .none,
                                    payload: Data(#"{"success":true}"#.utf8))]
            }
            if text.contains("__shutdown__") {
                return [WireMessage(type: .response, id: message.id, flags: .none,
                                    payload: Data(#"{"success":true}"#.utf8))]
            }
            if text.contains(#""type":"heartbeat""#) {
                return [WireMessage(type: .response, id: message.id, flags: .none,
                                    payload: Data(#"{"type":"heartbeat","number":7}"#.utf8))]
            }
            if text.contains(#""type":"embed""#) {
                return [WireMessage(type: .response, id: message.id, flags: .none,
                                    payload: Data(#"{"type":"error","message":"no such model","code":53011}"#.utf8))]
            }
            return []
        }

        let client = QVACClient(transport: transport)
        try await client.initialize()

        let heartbeat = try await client.heartbeat(HeartbeatRequest())
        XCTAssertEqual(heartbeat.number, 7)

        do {
            _ = try await client.embed(EmbedRequest(modelId: "missing", text: .string("x")))
            XCTFail("expected a remote error")
        } catch let error as QVACRemoteError {
            XCTAssertEqual(error.codeName, "ARCHIVE_EXTRACTION_FAILED")
        }
        await client.shutdown()
    }

    func testDuplexMethodCarriesTypedConversation() async throws {
        let transport = ScriptedTransport { message in
            // The duplex opener: REQUEST + OPEN, no payload. Ack its stream.
            if message.type == .request, message.flags == .open {
                return [WireMessage(type: .stream, id: message.id, flags: [.request, .open])]
            }
            // Outbound records arrive one per DATA frame.
            if message.type == .stream, message.flags == [.request, .data], let payload = message.payload {
                let text = String(decoding: payload, as: UTF8.self)
                let reply = text.contains("audioChunk")
                    ? #"{"type":"transcribeStream","text":"heard"}"#
                    : #"{"type":"transcribeStream","text":"ready"}"#
                return [WireMessage(type: .stream, id: message.id, flags: [.response, .data],
                                    payload: Data((reply + "\n").utf8))]
            }
            // Half-close: finish the response side with a done record.
            if message.type == .stream, message.flags == [.request, .end] {
                return [
                    WireMessage(type: .stream, id: message.id, flags: [.response, .data],
                                payload: Data(#"{"type":"transcribeStream","done":true}"#.utf8)),
                    WireMessage(type: .stream, id: message.id, flags: [.response, .end])
                ]
            }
            if message.type == .request, let payload = message.payload,
               String(decoding: payload, as: UTF8.self).contains("__shutdown__") {
                return [WireMessage(type: .response, id: message.id, flags: .none,
                                    payload: Data(#"{"success":true}"#.utf8))]
            }
            return []
        }

        let client = QVACClient(transport: transport)
        let call = try await client.transcribeStream(TranscribeStreamRequest(modelId: "whisper-1"))
        try await call.send(["audioChunk": "AAAA"])
        try await call.finishSending()

        var texts: [String?] = []
        var done = false
        for try await response in call.responses {
            texts.append(response.text)
            if response.done == true { done = true }
        }
        XCTAssertEqual(texts, ["ready", "heard", nil])
        XCTAssertTrue(done, "the trailer record must arrive before END")
        await client.shutdown()
    }

    func testUnaryOverloadRefusesPromotedRequest() async throws {
        let transport = ScriptedTransport { message in
            guard let payload = message.payload,
                  String(decoding: payload, as: UTF8.self).contains("__shutdown__") else { return [] }
            return [WireMessage(type: .response, id: message.id, flags: .none,
                                payload: Data(#"{"success":true}"#.utf8))]
        }
        let client = QVACClient(transport: transport)

        // withProgress: true on the unary overload would await one reply to a
        // streamed response — the generated guard turns the hang into a
        // typed error pointing at the onProgress overload.
        let promoted = RagRequest.ingest(RagRequestIngest(
            documents: .string("hello"), modelId: "m1", withProgress: true))
        do {
            _ = try await client.rag(promoted)
            XCTFail("expected progressPromoted")
        } catch QVACClientError.progressPromoted(let method) {
            XCTAssertEqual(method, "rag")
        }
        await client.shutdown()
    }
}
