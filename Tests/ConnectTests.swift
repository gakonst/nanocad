import CryptoKit
import XCTest
@testable import NanoCAD

final class ConnectTests: XCTestCase {
    private func grant() throws -> NanocodexConnectGrant {
        .init(appID: ConnectConfiguration.appID, appOrigin: ConnectConfiguration.appOrigin,
              grantID: "0x" + String(repeating: "a", count: 64), agentID: "agent-fixture", token: String(repeating: "x", count: 43),
              expiresAt: Date().timeIntervalSince1970 + 3600, conversationID: UUID().uuidString.lowercased(),
              toolCatalogDigest: try ConnectConfiguration.catalogDigest())
    }

    func testExpiredOrDifferentToolApprovalRejected() throws {
        var value = try grant()
        value.expiresAt = Date().timeIntervalSince1970 - 1
        XCTAssertThrowsError(try NanocodexCredentials(connect: value))
        value.expiresAt += 3600; value.toolCatalogDigest = "0x" + String(repeating: "0", count: 64)
        XCTAssertThrowsError(try NanocodexCredentials(connect: value))
    }

    func testGrantRequestCannotTargetAnotherAgentAndIncludesOrigin() throws {
        let value = try grant(), credentials = try NanocodexCredentials(connect: value)
        let client = NanocodexClient(credentials: credentials); defer { client.close() }
        let request = try client.request(path: "/v1/agents/agent-fixture/events?cursor=42")
        XCTAssertEqual(request.url?.path, "/v1/grants/\(value.grantID)/agents/agent-fixture/events")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), ConnectConfiguration.appOrigin)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Nanocodex-App-ID"), ConnectConfiguration.appID)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + value.token)
        XCTAssertThrowsError(try client.request(path: "/v1/agents/other-agent/turns"))
        XCTAssertThrowsError(try client.request(path: "/v1/agents"))
    }

    func testNativeGenerationBindsRuntimeIdentityWithoutConfusingPublicIDs() throws {
        let generation = UUID().uuidString
        var binding = ConnectRuntimeBinding(generationID: generation)
        XCTAssertFalse(binding.accepts(session: "runtime-session", turn: "runtime-session:2", input: ["generation_id": UUID().uuidString]))
        XCTAssertTrue(binding.accepts(session: "runtime-session", turn: "runtime-session:2", input: ["generation_id": generation]))
        XCTAssertTrue(binding.accepts(session: "runtime-session", turn: "runtime-session:2", input: ["generation_id": generation]))
        XCTAssertFalse(binding.accepts(session: "other-session", turn: "runtime-session:2", input: ["generation_id": generation]))
        XCTAssertFalse(binding.accepts(session: "runtime-session", turn: "runtime-session:3", input: ["generation_id": generation]))
        XCTAssertFalse(binding.accepts(session: "runtime-session", turn: "runtime-session:2", input: ["generation_id": UUID().uuidString]))
        XCTAssertTrue(binding.accepts(session: "runtime-session", turn: "runtime-session:2", input: ["generation_id": generation]))
    }

    func testChunkTransferRestoresAndRejectsConflictingRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = PendingGeneration(prompt: "fixture", references: [], files: [.init(path: "/brain/input/model.step", data: Data("original STEP".utf8))], instructions: "")
        let transfer = try ConnectFileTransfer(root: root, generationID: generation.creationID)
        try await transfer.prepare(generation, agentID: "agent-fixture")
        let read: [String: Any] = ["generation_id": generation.creationID, "file": "model.step", "offset": 0, "length": 32768]
        let input = try await transfer.handle(name: "nanocad_read_input", input: JSONSerialization.data(withJSONObject: read))
        let decoded = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        XCTAssertEqual(decoded["data_base64"] as? String, Data("original STEP".utf8).base64EncodedString())
        let bytes = Data(repeating: 42, count: 40000)
        for file in ["model.step", "model.cad.json"] {
            for offset in [0, 32768] {
                let chunk = bytes.subdata(in: offset..<min(offset + 32768, bytes.count))
                let payload: [String: Any] = ["generation_id": generation.creationID, "file": file, "offset": offset, "total_size": bytes.count, "sha256": ConnectFileTransfer.digest(bytes), "data_base64": chunk.base64EncodedString()]
                let encoded = try JSONSerialization.data(withJSONObject: payload)
                _ = try await transfer.handle(name: "nanocad_write_output", input: encoded)
                _ = try await transfer.handle(name: "nanocad_write_output", input: encoded)
                var conflict = payload; conflict["data_base64"] = Data(repeating: 1, count: chunk.count).base64EncodedString()
                do { _ = try await transfer.handle(name: "nanocad_write_output", input: JSONSerialization.data(withJSONObject: conflict)); XCTFail("conflicting retry accepted") }
                catch NanocodexError.integrityFailure { }
            }
        }
        let restored = try ConnectFileTransfer(root: root, generationID: generation.creationID)
        try await restored.prepare(generation, agentID: "agent-fixture")
        let result = try await restored.result(agentID: "agent-fixture", turnID: generation.turnID)
        XCTAssertEqual(result.step, bytes); XCTAssertEqual(result.preview, bytes)
        do { _ = try await restored.result(agentID: "other-agent", turnID: generation.turnID); XCTFail("wrong agent accepted") }
        catch NanocodexError.invalidReference { }
        var wrong = read; wrong["generation_id"] = UUID().uuidString
        do { _ = try await restored.handle(name: "nanocad_read_input", input: JSONSerialization.data(withJSONObject: wrong)); XCTFail("wrong generation accepted") }
        catch NanocodexError.invalidReference { }
        wrong = read; wrong["file"] = "../../generation.json"
        do { _ = try await restored.handle(name: "nanocad_read_input", input: JSONSerialization.data(withJSONObject: wrong)); XCTFail("path traversal accepted") }
        catch NanocodexError.invalidReference { }
    }
}
