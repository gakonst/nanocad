import Foundation
import XCTest
@testable import NanoCAD

/// Wire fixtures follow upstream 806182e2 (Agent.mjs and js/managed handlers).
/// All requests, including unexpected hosts, are intercepted; no account/network is used.
@MainActor
final class NanocodexHTTPTests: XCTestCase {
    private let agentID = "00000000-0000-4000-8000-000000000003"
    private let turnID = "turn.fixture:03"
    // Independent, known SHA-256 vectors, not calculated with the client implementation.
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private let artifactID = String(repeating: "a3", count: 32)

    func testConnectionCheckIsAuthenticatedReadOnly() async throws {
        let fixture = try HTTPFixture([.json(#"{"data":[],"has_more":false}"#)])
        defer { fixture.close() }
        try await fixture.client.validateConnection()

        let request = try XCTUnwrap(fixture.requests.only)
        assertRequest(request, fixture: fixture, method: "GET", path: "/v1/agents")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testCreateUsesManagedReceiptAndAstraSettings() async throws {
        // A distinct session_id proves that the public agent_id field owns the result.
        let fixture = try HTTPFixture([.json("""
            {"agent_id":"\(agentID)","session_id":"ignored-session-id",
             "durability_id":"ignored-durability-id","initial_state":{"latest_event_cursor":"1"}}
            """, status: 201)])
        defer { fixture.close() }
        let result = try await fixture.client.createAgent(requestID: "create:fixture-3", instructions: "Keep hole centres fixed.")
        XCTAssertEqual(result, agentID)

        let request = try XCTUnwrap(fixture.requests.only)
        assertRequest(request, fixture: fixture, method: "POST", path: "/v1/agents", key: "create:fixture-3")
        let body = try object(request)
        XCTAssertEqual(Set(body.keys), ["settings", "configuration"])
        assertAstra(try XCTUnwrap(body["settings"] as? [String: Any]))
        let configuration = try XCTUnwrap(body["configuration"] as? [String: Any])
        let instructions = try XCTUnwrap(configuration["instructions"] as? String)
        XCTAssertTrue(instructions.contains("/brain/outputs/model.step"))
        XCTAssertTrue(instructions.hasSuffix("\nKeep hole centres fixed."))
        let environment = try XCTUnwrap(configuration["environment"] as? [String: Any])
        XCTAssertEqual((environment["files"] as? [[String: String]])?.count, 0)
        XCTAssertEqual(environment["setup_commands"] as? [String], [])
    }

    func testBinarySeedsUseBoundedBase64FilesAndQuotedSetupCommands() async throws {
        let fixture = try HTTPFixture([.json("{\"agent_id\":\"\(agentID)\"}", status: 201)])
        defer { fixture.close() }
        // Cross one 240000-character chunk boundary, including bytes invalid as UTF-8.
        let binary = Data((0..<180_003).map { UInt8(truncatingIfNeeded: $0) })
        let path = "/brain/input/gear's $(touch should-not-run); 世界.step"
        _ = try await fixture.client.createAgent(requestID: "seed:fixture-3", inputFiles: [
            NanocodexInputFile(path: path, data: binary),
            NanocodexInputFile(path: "/brain/input/empty.txt", data: Data())
        ])
        let body = try object(XCTUnwrap(fixture.requests.only))
        let configuration = try XCTUnwrap(body["configuration"] as? [String: Any])
        let environment = try XCTUnwrap(configuration["environment"] as? [String: Any])
        let files = try XCTUnwrap(environment["files"] as? [[String: String]])
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.map { $0["path"] ?? "" }, [
            "/brain/input/nanocad-upload-0-0.b64", "/brain/input/nanocad-upload-0-1.b64", "/brain/input/empty.txt"
        ])
        XCTAssertEqual(files.map { $0["content"]?.count ?? -1 }, [240_000, 4, 0])
        XCTAssertTrue(files.allSatisfy { Set($0.keys) == ["path", "content"] })
        XCTAssertEqual(Data(base64Encoded: files.prefix(2).compactMap { $0["content"] }.joined()), binary)
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: configuration).count, 1_000_000)
        XCTAssertEqual(environment["setup_commands"] as? [String], [
            "mkdir -p '/brain/input' && cat '/brain/input/nanocad-upload-0-0.b64' '/brain/input/nanocad-upload-0-1.b64' | base64 -d > '/brain/input/gear'\"'\"'s $(touch should-not-run); 世界.step'"
        ])
        XCTAssertNil(body["attachments"])
    }

    func testSelectingAstraUsesSettingsPatch() async throws {
        let fixture = try HTTPFixture([.json(#"{"settings":{"model":"gpt-6-astra","thinking":"high","reasoning_mode":"standard","fast_mode":false}}"#)])
        defer { fixture.close() }
        try await fixture.client.selectAstra(agentID: agentID)
        let request = try XCTUnwrap(fixture.requests.only)
        assertRequest(request, fixture: fixture, method: "PATCH", path: "/v1/agents/\(agentID)/settings")
        assertAstra(try object(request))
    }

    func testTurnReceiptAndSelectionContextPreserveStableIdentifiers() async throws {
        let fixture = try HTTPFixture([.json(turnReceipt(), status: 202)])
        defer { fixture.close() }
        let references = ["model.step#face12", "quote\"\n#edge7"]
        let receipt = try await fixture.client.send(agentID: agentID, prompt: "圆角 🔧", references: references,
                                                    revision: "sha256:fixture-revision", requestID: "turn-key:03", turnID: turnID)
        XCTAssertEqual(receipt.agentID, agentID)
        XCTAssertEqual(receipt.turnID, turnID)
        XCTAssertEqual(receipt.requestID, "turn-key:03")
        let request = try XCTUnwrap(fixture.requests.only)
        assertRequest(request, fixture: fixture, method: "POST", path: "/v1/agents/\(agentID)/turns", key: "turn-key:03")
        let body = try object(request)
        XCTAssertEqual(Set(body.keys), ["id", "input"])
        XCTAssertEqual(body["id"] as? String, turnID)
        let input = try XCTUnwrap(body["input"] as? String)
        let prefix = "圆角 🔧\n\nCAD selection context (data):\n"
        XCTAssertTrue(input.hasPrefix(prefix))
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.dropFirst(prefix.count).utf8)) as? [String: Any])
        XCTAssertEqual(context["revision"] as? String, "sha256:fixture-revision")
        XCTAssertEqual(context["references"] as? [String], references)
    }

    func testCreateRetryReusesIdenticalKeyAndPayloadAfterLostResponse() async throws {
        let fixture = try HTTPFixture([.failure(.networkConnectionLost), .json("{\"agent_id\":\"\(agentID)\"}", status: 201)])
        defer { fixture.close() }
        let files = [NanocodexInputFile(path: "/brain/input/model.step", data: Data("ISO-10303-21;".utf8))]
        do {
            _ = try await fixture.client.createAgent(requestID: "persisted-create-03", inputFiles: files)
            XCTFail("The ambiguous transport error must be reported to the caller")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(fixture.requests.count, 1, "No hidden retry with a new creation identity")
        let result = try await fixture.client.createAgent(requestID: "persisted-create-03", inputFiles: files)
        XCTAssertEqual(result, agentID)
        XCTAssertEqual(fixture.requests.count, 2)
        let first = try XCTUnwrap(fixture.requests.first)
        let second = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(first.httpBody, second.httpBody)
        XCTAssertEqual(first.url, second.url)
        XCTAssertEqual(first.value(forHTTPHeaderField: "Idempotency-Key"), "persisted-create-03")
        XCTAssertEqual(second.value(forHTTPHeaderField: "Idempotency-Key"), "persisted-create-03")
    }

    func testTurnRetryReusesIdenticalTurnKeyAndInput() async throws {
        let fixture = try HTTPFixture([.failure(.timedOut), .json(turnReceipt(), status: 200)])
        defer { fixture.close() }
        do {
            _ = try await fixture.client.send(agentID: agentID, prompt: "Make a bracket", requestID: "persisted-turn-03", turnID: turnID)
            XCTFail("The ambiguous transport error must be reported to the caller")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(fixture.requests.count, 1)
        let receipt = try await fixture.client.send(agentID: agentID, prompt: "Make a bracket", requestID: "persisted-turn-03", turnID: turnID)
        XCTAssertEqual(receipt.turnID, turnID)
        XCTAssertEqual(fixture.requests.count, 2)
        let first = try XCTUnwrap(fixture.requests.first)
        let second = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(first.httpBody, second.httpBody)
        XCTAssertEqual(first.value(forHTTPHeaderField: "Idempotency-Key"), "persisted-turn-03")
        XCTAssertEqual(second.value(forHTTPHeaderField: "Idempotency-Key"), "persisted-turn-03")
        XCTAssertEqual(try object(second)["input"] as? String, "Make a bracket")
    }

    func testCancellationTargetsTheExistingTurnWithoutResubmittingIt() async throws {
        let fixture = try HTTPFixture([.json("{\"turn_id\":\"\(turnID)\",\"state\":\"cancelling\"}", status: 202)])
        defer { fixture.close() }
        try await fixture.client.cancel(agentID: agentID, turnID: turnID)
        let request = try XCTUnwrap(fixture.requests.only)
        assertRequest(request, fixture: fixture, method: "POST", path: "/v1/agents/\(agentID)/turns/\(turnID)/cancel")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testArtifactListDecodesPublishedFilesAndPublicationFailures() async throws {
        let fixture = try HTTPFixture([.json("""
            {"data":[{"id":"\(artifactID)","turn_id":"\(turnID)","path":"/brain/outputs/model.step",
                       "digest":"\(abcDigest)","size":3,"created_at":123}],
             "publications":[{"turn_id":"\(turnID)","state":"ready","error":null},
                             {"turn_id":"older-turn","state":"failed","error":"publication exceeds 10 MB"}]}
            """)])
        defer { fixture.close() }
        let page = try await fixture.client.artifacts(agentID: agentID, turnID: turnID)
        let artifact = try XCTUnwrap(page.data.only)
        XCTAssertEqual(artifact.id, artifactID)
        XCTAssertEqual(artifact.turnID, turnID)
        XCTAssertEqual(artifact.path, "/brain/outputs/model.step")
        XCTAssertEqual(artifact.digest, abcDigest)
        XCTAssertEqual(artifact.size, 3)
        XCTAssertEqual(page.publications.count, 2)
        XCTAssertEqual(page.publications.first?.state, "ready")
        XCTAssertNil(page.publications.first?.error)
        XCTAssertEqual(page.publications.last?.turnID, "older-turn")
        XCTAssertEqual(page.publications.last?.state, "failed")
        XCTAssertEqual(page.publications.last?.error, "publication exceeds 10 MB")
        let request = try XCTUnwrap(fixture.requests.only)
        assertRequest(request, fixture: fixture, method: "GET", path: "/v1/agents/\(agentID)/artifacts")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "turn_id", value: turnID)])
    }

    func testUnfilteredArtifactListOmitsTheQuery() async throws {
        let fixture = try HTTPFixture([.json(#"{"data":[],"publications":[]}"#)])
        defer { fixture.close() }
        let page = try await fixture.client.artifacts(agentID: agentID)
        XCTAssertTrue(page.data.isEmpty)
        XCTAssertTrue(page.publications.isEmpty)
        XCTAssertNil(try XCTUnwrap(fixture.requests.only).url?.query)
    }

    func testArtifactDownloadUsesArtifactIDAndChecksKnownDigest() async throws {
        let fixture = try HTTPFixture([.bytes(Data("abc".utf8))])
        defer { fixture.close() }
        let artifact = NanocodexArtifact(id: artifactID, turnID: turnID, path: "/brain/outputs/model.step", digest: abcDigest, size: 3)
        let url = try await fixture.client.download(agentID: agentID, artifact: artifact)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), Data("abc".utf8))
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-model.step"))
        assertRequest(try XCTUnwrap(fixture.requests.only), fixture: fixture, method: "GET",
                      path: "/v1/agents/\(agentID)/artifacts/\(artifactID)/content")
    }

    func testArtifactDownloadRejectsHashMismatchAndLengthMismatch() async throws {
        for bytes in [Data("abd".utf8), Data("ab".utf8)] {
            let fixture = try HTTPFixture([.bytes(bytes)])
            defer { fixture.close() }
            let artifact = NanocodexArtifact(id: artifactID, turnID: turnID, path: "/brain/outputs/model.step", digest: abcDigest, size: 3)
            await expectError(.integrityFailure) {
                let unexpected = try await fixture.client.download(agentID: self.agentID, artifact: artifact)
                try? FileManager.default.removeItem(at: unexpected)
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testInvalidArtifactMetadataIsRefusedBeforeRequest() async throws {
        let fixture = try HTTPFixture([])
        defer { fixture.close() }
        for (id, size) in [("../content", 3), (String(repeating: "A", count: 64), 3), (artifactID, -1), (artifactID, 1_000_001)] {
            let artifact = NanocodexArtifact(id: id, turnID: turnID, path: "/brain/outputs/model.step", digest: abcDigest, size: size)
            await expectError(.invalidReference) { _ = try await fixture.client.download(agentID: self.agentID, artifact: artifact) }
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testHTTPFailuresRemainFailuresEvenWithSuccessShapedBodies() async throws {
        // Valid success bodies ensure the status check cannot accidentally be bypassed.
        let createBody = "{\"agent_id\":\"\(agentID)\"}"
        for status in [400, 401, 403, 409, 429, 500, 503] {
            let fixture = try HTTPFixture([.json(createBody, status: status), .json(turnReceipt(), status: status)])
            defer { fixture.close() }
            await expectError(.http(status)) { _ = try await fixture.client.createAgent(requestID: "refused-create-03") }
            await expectError(.http(status)) {
                _ = try await fixture.client.send(agentID: self.agentID, prompt: "Test", requestID: "refused-turn-03", turnID: self.turnID)
            }
            XCTAssertEqual(fixture.requests.count, 2, "Refused mutations must not be automatically replayed")
        }
    }

    func testAuthenticationRefusalsPropagateThroughAllReadAndControlRoutes() async throws {
        let artifact = NanocodexArtifact(id: artifactID, turnID: turnID, path: "/brain/outputs/model.step", digest: abcDigest, size: 3)
        for status in [401, 403] {
            let fixture = try HTTPFixture(Array(repeating: .json(#"{"error":"unauthorized"}"#, status: status), count: 5))
            defer { fixture.close() }
            await expectError(.http(status)) { try await fixture.client.validateConnection() }
            await expectError(.http(status)) { try await fixture.client.selectAstra(agentID: self.agentID) }
            await expectError(.http(status)) { try await fixture.client.cancel(agentID: self.agentID, turnID: self.turnID) }
            await expectError(.http(status)) { _ = try await fixture.client.artifacts(agentID: self.agentID) }
            await expectError(.http(status)) { _ = try await fixture.client.download(agentID: self.agentID, artifact: artifact) }
            XCTAssertEqual(fixture.requests.count, 5)
            XCTAssertTrue(NanocodexError.http(status).localizedDescription.contains("Reconnect"))
        }
    }

    func testRedirectStatusIsNotTreatedAsSuccess() async throws {
        let fixture = try HTTPFixture([.response(status: 302, body: Data(), headers: ["Location": "https://unregistered.nanocad-http.invalid/credentials"])])
        defer { fixture.close() }
        await expectError(.http(302)) { try await fixture.client.validateConnection() }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testMissingMalformedAndMismatchedReceiptsAreRejected() async throws {
        for body in ["{}", "[]", #"{"session_id":"not-agent-id"}"#, #"{"agent_id":42}"#] {
            let fixture = try HTTPFixture([.json(body, status: 201)])
            defer { fixture.close() }
            await expectError(.invalidResponse) { _ = try await fixture.client.createAgent(requestID: "bad-receipt-03") }
        }
        for body in ["{}", "[]", #"{"turn_id":42}"#, #"{"turn_id":"other-turn"}"#] {
            let fixture = try HTTPFixture([.json(body, status: 202)])
            defer { fixture.close() }
            await expectError(.invalidResponse) {
                _ = try await fixture.client.send(agentID: self.agentID, prompt: "Test", requestID: "bad-receipt-03", turnID: self.turnID)
            }
        }
        let fixture = try HTTPFixture([.json(#"{"agent_id":"../other-agent"}"#, status: 201)])
        defer { fixture.close() }
        await expectError(.invalidReference) { _ = try await fixture.client.createAgent(requestID: "unsafe-receipt-03") }
    }

    func testMalformedJSONAndNonHTTPResponsesCannotSucceed() async throws {
        let fixture = try HTTPFixture([.json("not-json", status: 201), .nonHTTP(Data("{}".utf8)), .json(#"{"data":[],"publications":null}"#)])
        defer { fixture.close() }
        do {
            _ = try await fixture.client.createAgent(requestID: "unreadable-03")
            XCTFail("Malformed JSON must not produce an agent")
        } catch { /* JSONSerialization's decoding failure is intentionally preserved. */ }
        await expectError(.invalidResponse) { try await fixture.client.validateConnection() }
        do {
            _ = try await fixture.client.artifacts(agentID: agentID)
            XCTFail("A malformed publication page must not look like an empty successful result")
        } catch is DecodingError { }
        XCTAssertEqual(fixture.requests.count, 3)
    }

    func testUnsafeIdentifiersAreRefusedBeforeRequest() async throws {
        let fixture = try HTTPFixture([])
        defer { fixture.close() }
        for key in ["", "contains space", "line\nbreak", "é", String(repeating: "x", count: 257)] {
            await expectError(.invalidReference) { _ = try await fixture.client.createAgent(requestID: key) }
            await expectError(.invalidReference) {
                _ = try await fixture.client.send(agentID: self.agentID, prompt: "Test", requestID: key, turnID: self.turnID)
            }
        }
        for id in ["", "agent/escape", "agent?query", "agent#fragment", String(repeating: "a", count: 129)] {
            await expectError(.invalidReference) { try await fixture.client.selectAstra(agentID: id) }
        }
        for id in ["", "turn/escape", "turn?query", "turn#fragment", String(repeating: "t", count: 129)] {
            await expectError(.invalidReference) { try await fixture.client.cancel(agentID: self.agentID, turnID: id) }
            await expectError(.invalidReference) { _ = try await fixture.client.artifacts(agentID: self.agentID, turnID: id) }
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testDotSegmentTurnIdentifiersAreRefusedBeforeRequest() async throws {
        // Upstream public router explicitly excludes these despite the general ID regex.
        let fixture = try HTTPFixture([])
        defer { fixture.close() }
        for id in [".", ".."] {
            await expectError(.invalidReference) {
                _ = try await fixture.client.send(agentID: self.agentID, prompt: "Test", requestID: "dot-segment-03", turnID: id)
            }
            await expectError(.invalidReference) { try await fixture.client.cancel(agentID: self.agentID, turnID: id) }
            await expectError(.invalidReference) { _ = try await fixture.client.artifacts(agentID: self.agentID, turnID: id) }
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testUnsafeSeedPathsAndOversizeConfigurationsAreRefusedBeforeRequest() async throws {
        let fixture = try HTTPFixture([])
        defer { fixture.close() }
        for path in ["/etc/model.step", "/brain/../model.step", "/brain//model.step", "/brain/./model.step", "/brain/model\n.step", "/brain/model\\.step", "/brain/" + String(repeating: "x", count: 506)] {
            await expectError(.invalidReference) {
                _ = try await fixture.client.createAgent(requestID: "unsafe-seed-03", inputFiles: [.init(path: path, data: Data([0xff]))])
            }
        }
        let oversizedFiles: [[NanocodexInputFile]] = [
            [.init(path: "/brain/input/huge.step", data: Data(repeating: 0xff, count: 637_501))],
            (0..<51).map { .init(path: "/brain/input/\($0).txt", data: Data()) },
            (0..<33).map { .init(path: "/brain/input/\($0).bin", data: Data([0xff])) },
            (0..<13).map { .init(path: "/brain/input/\($0).bin", data: Data(repeating: 0xff, count: 60_000)) }
        ]
        for files in oversizedFiles {
            await expectError(.inputTooLarge) { _ = try await fixture.client.createAgent(requestID: "oversize-03", inputFiles: files) }
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testUnsafeLiveFilePathsAreRefusedBeforeRequest() async throws {
        let fixture = try HTTPFixture([])
        defer { fixture.close() }
        for path in ["/etc/passwd", "/brain/../secret", "/brain//model.step", "/brain/model\u{0}.step"] {
            await expectError(.invalidReference) { _ = try await fixture.client.downloadFile(agentID: self.agentID, path: path) }
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testInvalidCredentialsAndOriginsAreRefusedLocally() {
        for origin in ["http://fixture.invalid", "https://fixture.invalid/path", "https://fixture.invalid?query", "https://fixture.invalid#fragment", "https://user:password@fixture.invalid"] {
            XCTAssertThrowsError(try NanocodexCredentials(origin: origin, apiKey: HTTPFixture.apiKey)) { error in
                guard case NanocodexError.invalidOrigin = error else { return XCTFail("Expected invalidOrigin") }
            }
        }
        for key in ["", "fixture", "Bearer " + HTTPFixture.apiKey, HTTPFixture.apiKey + "x"] {
            XCTAssertThrowsError(try NanocodexCredentials(origin: "https://fixture.nanocad-http.invalid", apiKey: key)) { error in
                guard case NanocodexError.invalidCredential = error else { return XCTFail("Expected invalidCredential") }
            }
        }
    }

    private func turnReceipt() -> String {
        """
        {"turn_id":"\(turnID)","state":"accepted","input":"fixture",
         "accepted_cursor":"9007199254740993","terminal_cursor":null,
         "created_at":123,"accepted_at":123,"updated_at":123,"attempt_count":0,"retry_at":null}
        """
    }

    private func assertRequest(_ request: URLRequest, fixture: HTTPFixture, method: String, path: String,
                               key: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request.url?.scheme, "https", file: file, line: line)
        XCTAssertEqual(request.url?.host, fixture.host, file: file, line: line)
        XCTAssertEqual(request.url?.path, path, file: file, line: line)
        XCTAssertEqual(request.httpMethod, method, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + HTTPFixture.apiKey, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), key, file: file, line: line)
        if request.httpBody != nil {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", file: file, line: line)
        }
    }

    private func assertAstra(_ settings: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(settings.keys), ["model", "thinking", "reasoning_mode", "fast_mode"], file: file, line: line)
        XCTAssertEqual(settings["model"] as? String, "gpt-6-astra", file: file, line: line)
        XCTAssertEqual(settings["thinking"] as? String, "high", file: file, line: line)
        XCTAssertEqual(settings["reasoning_mode"] as? String, "standard", file: file, line: line)
        XCTAssertEqual(settings["fast_mode"] as? Bool, false, file: file, line: line)
    }

    private func object(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private enum ExpectedError { case invalidReference, invalidResponse, inputTooLarge, integrityFailure, http(Int) }
    private func expectError(_ expected: ExpectedError, file: StaticString = #filePath, line: UInt = #line,
                             operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            guard let actual = error as? NanocodexError else {
                return XCTFail("Expected \(expected); received \(error)", file: file, line: line)
            }
            switch (expected, actual) {
            case (.invalidReference, .invalidReference), (.invalidResponse, .invalidResponse),
                 (.inputTooLarge, .inputTooLarge), (.integrityFailure, .integrityFailure): break
            case (.http(let expectedStatus), .http(let actualStatus)):
                XCTAssertEqual(actualStatus, expectedStatus, file: file, line: line)
            default: XCTFail("Expected \(expected); received \(actual)", file: file, line: line)
            }
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private enum HTTPReply: Sendable {
    case response(status: Int, body: Data, headers: [String: String])
    case failure(URLError.Code)
    case nonHTTP(Data)

    static func json(_ text: String, status: Int = 200) -> Self {
        .response(status: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
    }
    static func bytes(_ data: Data) -> Self {
        .response(status: 200, body: data, headers: ["Content-Type": "application/octet-stream"])
    }
}

private final class HTTPFixture {
    // Exactly the public key regex; this deliberately recognizable value is never live.
    static let apiKey = "ncx_live_TESTFIXTURE3_" + String(repeating: "fixture", count: 6) + "X"
    let host: String
    let client: NanocodexClient
    private let exchange: HTTPExchange
    var requests: [URLRequest] { exchange.requests }

    init(_ replies: [HTTPReply]) throws {
        host = UUID().uuidString.lowercased() + ".nanocad-http.invalid"
        exchange = HTTPExchange(replies: replies)
        let credentials = try NanocodexCredentials(origin: "https://" + host, apiKey: Self.apiKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPFixtureProtocol.self]
        client = NanocodexClient(credentials: credentials, configuration: configuration)
        HTTPFixtureProtocol.registry.insert(exchange, host: host)
    }

    func close() {
        client.close()
        HTTPFixtureProtocol.registry.remove(host: host)
    }
    deinit { close() }
}

/// The unchecked Sendable types below protect ALL mutable state with locks; URLProtocol
/// callbacks run on Foundation queues. No global mutable handler or test-case capture.
private final class HTTPExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [HTTPReply]
    private var captured: [URLRequest] = []
    init(replies: [HTTPReply]) { self.replies = replies }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }
    func takeReply(for request: URLRequest) -> HTTPReply {
        lock.lock(); defer { lock.unlock() }
        captured.append(request)
        guard !replies.isEmpty else { return .failure(.resourceUnavailable) }
        return replies.removeFirst()
    }
}

private final class HTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [String: HTTPExchange] = [:]
    func insert(_ exchange: HTTPExchange, host: String) {
        lock.lock(); defer { lock.unlock() }
        exchanges[host] = exchange
    }
    func remove(host: String) {
        lock.lock(); defer { lock.unlock() }
        exchanges.removeValue(forKey: host)
    }
    func exchange(host: String) -> HTTPExchange? {
        lock.lock(); defer { lock.unlock() }
        return exchanges[host]
    }
}

private final class HTTPFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let registry = HTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let exchange = Self.registry.exchange(host: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            var captured = request
            // URLSession may present POST bodies as a stream rather than httpBody.
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBodyStream = nil
                captured.httpBody = body
            }
            switch exchange.takeReply(for: captured) {
            case .failure(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            case .nonHTTP(let body):
                let response = URLResponse(url: url, mimeType: "application/json", expectedContentLength: body.count, textEncodingName: "utf-8")
                finish(response: response, body: body)
            case .response(let status, let body, let headers):
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                    throw URLError(.badServerResponse)
                }
                finish(response: response, body: body)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    private func finish(response: URLResponse, body: Data) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { /* Replies finish synchronously; there is no outstanding work. */ }
}
