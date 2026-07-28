import XCTest
import QVACWire
@testable import QVACSession

/// The whole stack against a REAL `bare-rpc` peer: `Scripts/fake-worker.js`
/// dials into the Swift listener — the actual transport direction — and every
/// byte on the wire is produced or parsed by the reference library. The mock
/// suite proves the session's invariants; this proves the stack speaks to the
/// thing it claims to speak to.
final class LiveWorkerTests: XCTestCase {

    enum Command {
        static let echo: UInt64 = 100
        static let tokens: UInt64 = 101
        static let fail: UInt64 = 102
        static let bye: UInt64 = 103
    }

    static let scriptsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LiveWorkerTests.swift
        .deletingLastPathComponent()   // QVACIntegrationTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Scripts")

    private var worker: Process?

    override func tearDown() {
        if let worker, worker.isRunning { worker.terminate() }
        worker = nil
        super.tearDown()
    }

    /// Skips (never fails) when the environment can't host the fake worker.
    private func launchWorker(endpoint: String) throws {
        let scripts = Self.scriptsDirectory
        try XCTSkipUnless(
            FileManager.default.fileExists(
                atPath: scripts.appendingPathComponent("node_modules/bare-rpc/index.js").path),
            "run `npm install` in Scripts/ to enable the live-worker tests"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "fake-worker.js", endpoint]
        process.currentDirectoryURL = scripts
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw XCTSkip("could not launch node: \(error)")
        }
        worker = process
    }

    private func runConversation(over transport: SocketListenerTransport) async throws {
        let session = RPCSession(transport: transport)

        // Unary round trip through the reference encoder and back.
        let echoed = try await withTimeout(5) {
            try await session.call(command: Command.echo, payload: Data("hello, worker".utf8))
        }
        XCTAssertEqual(echoed, Data("hello, worker".utf8))

        // A response stream of NDJSON records, including the unterminated
        // trailer the Python client documents.
        let stream = try await session.serverStream(command: Command.tokens, payload: Data())
        let records = try await withTimeout(5) {
            var out: [String] = []
            for try await record in stream.ndjsonRecords() {
                out.append(String(decoding: record, as: UTF8.self))
            }
            return out
        }
        XCTAssertEqual(records.count, 6, "5 tokens + flushed trailer, got: \(records)")
        XCTAssertEqual(records.first, #"{"tok":"t0"}"#)
        XCTAssertEqual(records.last, #"{"done":true}"#)

        // A protocol-level error, faithfully reconstructed — code, message,
        // and a negative errno straight through the zigzag path.
        do {
            _ = try await withTimeout(5) {
                try await session.call(command: Command.fail, payload: Data())
            }
            XCTFail("expected a remote error")
        } catch let error as SessionError {
            guard case .remote(let wireError) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(wireError.code, "EDELIBERATE")
            XCTAssertEqual(wireError.errno, -42)
            XCTAssertTrue(wireError.message.contains("deliberate failure"))
        }

        // Clean goodbye; the worker exits and the session notices EOF.
        let bye = try await withTimeout(5) {
            try await session.call(command: Command.bye, payload: Data())
        }
        XCTAssertEqual(bye, Data("bye".utf8))

        let deadline = Date().addingTimeInterval(5)
        while worker?.isRunning == true && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(worker?.isRunning, false, "worker should exit after BYE")

        await session.shutdown()
    }

    // MARK: - The two desktop endpoint forms

    func testConversationOverLoopbackTCP() async throws {
        let transport = try SocketListenerTransport(endpoint: .tcp(host: "127.0.0.1", port: 0))
        XCTAssertTrue(transport.workerEndpointString.hasPrefix("tcp://127.0.0.1:"))
        try launchWorker(endpoint: transport.workerEndpointString)
        try await runConversation(over: transport)
    }

    func testConversationOverUnixDomainSocket() async throws {
        let path = "/tmp/qvac-live-\(getpid()).sock"
        let transport = try SocketListenerTransport(endpoint: .unix(path: path))
        XCTAssertEqual(transport.workerEndpointString, path)
        try launchWorker(endpoint: path)
        try await runConversation(over: transport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "socket file should be unlinked on close")
    }

    // MARK: - Death, not hangs

    func testWorkerCrashFailsPendingCallsImmediately() async throws {
        let transport = try SocketListenerTransport(endpoint: .tcp(host: "127.0.0.1", port: 0))
        try launchWorker(endpoint: transport.workerEndpointString)
        let session = RPCSession(transport: transport)

        // Prove the channel is up, then kill the worker out from under it.
        _ = try await withTimeout(5) {
            try await session.call(command: Command.echo, payload: Data("up?".utf8))
        }

        let hanging = Task {
            try await session.call(command: Command.tokens - 50, payload: Data())
        }
        // Give the request a moment to reach the wire, then crash the worker.
        try await Task.sleep(nanoseconds: 100_000_000)
        worker?.terminate()

        do {
            _ = try await withTimeout(5) { try await hanging.value }
            // The worker may have answered EUNKNOWN before dying — also fine;
            // what is forbidden is a hang.
        } catch let error as TimeoutExceeded {
            XCTFail("pending call hung after worker death: \(error)")
        } catch {
            // SessionError.closed or .remote — both acceptable outcomes.
        }
        await session.shutdown()
    }
}

// MARK: - Deadline guard (local copy; test targets cannot share sources)

struct TimeoutExceeded: Swift.Error { let label: String }

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
