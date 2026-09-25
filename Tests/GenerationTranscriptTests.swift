import XCTest
import CryptoKit
@testable import NanoCAD

final class GenerationTranscriptTests: XCTestCase {
    private func event(_ cursor: String, _ type: String, _ text: String = "", turn: String = "turn-a", phase: String? = nil, item: String? = "item-a", model: Int? = 1) -> NanocodexEvent {
        .init(cursor: cursor, turnID: turn, type: type, text: text, toolName: nil, itemID: item, modelCallIndex: model, phase: phase)
    }

    func testCoalescesByTurnModelItemAndPhaseWithoutReplayedTokens() throws {
        var transcript = GenerationTranscript()
        transcript.recordUser("Make a bracket", turnID: "turn-a")
        XCTAssertTrue(transcript.receive(event("9007199254740993", "assistant.delta", "Reading ", phase: "commentary"), for: "turn-a"))
        XCTAssertFalse(transcript.receive(event("9007199254740993", "assistant.delta", "Reading ", phase: "commentary"), for: "turn-a"))
        _ = transcript.receive(event("9007199254740994", "assistant.delta", "the model.", phase: "commentary"), for: "turn-a")
        _ = transcript.receive(event("9007199254740995", "assistant.message", "Reading the model.", phase: "commentary"), for: "turn-a")
        _ = transcript.receive(event("9007199254740996", "assistant.message", "Done.", phase: "final_answer"), for: "turn-a")
        _ = transcript.receive(event("9007199254740997", "assistant.message", "Second call", phase: "commentary", model: 2), for: "turn-a")
        _ = transcript.receive(event("9007199254740998", "reasoning.delta", "private reasoning"), for: "turn-a")
        _ = transcript.receive(event("9007199254740999", "assistant.message", "other turn", turn: "turn-b", phase: "commentary"), for: "turn-a")
        _ = transcript.receive(event("9007199254741000", "turn_completed", "Done."), for: "turn-a")
        XCTAssertEqual(transcript.entries.map(\.text), ["Make a bracket", "Reading the model.", "Done.", "Second call"])
        XCTAssertEqual(transcript.entries.map(\.kind), [.user, .commentary, .final, .commentary])
        let restored = try JSONDecoder().decode(GenerationTranscript.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(restored.entries, transcript.entries)
        XCTAssertEqual(restored.cursor(for: "turn-a"), "9007199254741000")
    }

    func testMissingDeltaPhaseIsResolvedByCompletedItemButFinalNeverOverwritesCommentary() {
        var transcript = GenerationTranscript()
        _ = transcript.receive(event("1", "assistant.delta", "Reading"), for: "turn-a")
        _ = transcript.receive(event("2", "assistant.message", "Reading the STEP", phase: "commentary"), for: "turn-a")
        _ = transcript.receive(event("3", "assistant.message", "Finished", phase: "final_answer"), for: "turn-a")
        XCTAssertEqual(transcript.entries.map(\.text), ["Reading the STEP", "Finished"])
        XCTAssertEqual(transcript.entries.map(\.kind), [.commentary, .final])
    }

    func testCompletedMessageBindsMissingDeltaIDAndTerminalCompletesPartialFinal() {
        var transcript = GenerationTranscript()
        _ = transcript.receive(event("1", "assistant.delta", "Inspecting ", phase: "commentary", item: nil), for: "turn-a")
        _ = transcript.receive(event("2", "assistant.message", "Inspecting STEP", phase: "commentary"), for: "turn-a")
        _ = transcript.receive(event("3", "assistant.message", "Inspecting STEP", phase: "commentary"), for: "turn-a")
        _ = transcript.receive(event("4", "assistant.delta", "Saved", phase: "final_answer", item: "final-a"), for: "turn-a")
        _ = transcript.receive(event("5", "turn_completed", "Saved the bracket."), for: "turn-a")
        XCTAssertEqual(transcript.entries.map(\.text), ["Inspecting STEP", "Saved the bracket."])
        XCTAssertTrue(transcript.entries.allSatisfy(\.isComplete))
        XCTAssertEqual(transcript.entries.first?.itemID, "item-a")
    }

    func testTerminalDoesNotRepeatAnUnphasedStreamedAnswer() {
        var transcript = GenerationTranscript()
        _ = transcript.receive(event("1", "assistant.delta", "Saved"), for: "turn-a")
        _ = transcript.receive(event("2", "turn_completed", "Saved"), for: "turn-a")
        XCTAssertEqual(transcript.entries.map(\.kind), [.final])
        XCTAssertEqual(transcript.entries.map(\.text), ["Saved"])
        XCTAssertEqual(transcript.entries.first?.isComplete, true)
    }

    func testUnknownAndReasoningPhasesNeverEnterVisibleTranscript() {
        var transcript = GenerationTranscript()
        for (index, phase) in ["analysis", "reasoning", "unknown"].enumerated() {
            _ = transcript.receive(event(String(index + 1), "assistant.message", "Hidden", phase: phase), for: "turn-a")
        }
        XCTAssertTrue(transcript.entries.isEmpty)
        XCTAssertEqual(transcript.cursor(for: "turn-a"), "3")
    }

    func testFallbackToolLabelsDescribeWorkWithoutClaimingValidation() {
        XCTAssertEqual(GenerationProgress.summary(toolName: "functions.exec_command", arguments: "python /brain/tools/export_step.py"), "Preparing model preview")
        XCTAssertEqual(GenerationProgress.summary(toolName: "functions.exec_command", arguments: "python model.py"), "Updating geometry")
        XCTAssertEqual(GenerationProgress.summary(toolName: "functions.exec_command", arguments: "check_volume"), "Running model tools")
        var transcript = GenerationTranscript()
        _ = transcript.receive(.init(cursor: "1", turnID: "turn-a", type: "tool.result", text: "", toolName: "exec_command", toolStatus: "failed"), for: "turn-a")
        _ = transcript.receive(.init(cursor: "2", turnID: "turn-a", type: "tool.result", text: "", toolName: "exec_command", toolStatus: "cancelled"), for: "turn-a")
        XCTAssertEqual(transcript.entries.map(\.text), ["Failed", "Cancelled"])
        XCTAssertEqual(transcript.entries.map(\.title), ["Tool failed", "Tool cancelled"])
    }

    func testToolErrorsRemainErrorsAndSensitiveFileBytesAreNotRetained() throws {
        let payload: [String: Any] = ["generation_id": "generation-fixture", "data_base64": "c2VjcmV0LWZpbGU=", "offset": 0,
            "Authorization": "Bearer fixture-secret", "nested": ["api_key": "fixture-key"], "cmd": "echo '" + String(repeating: "QUJD", count: 100) + "' | base64 -d"]
        let details = TranscriptRedaction.details(payload)
        XCTAssertFalse(details.contains("fixture-secret")); XCTAssertFalse(details.contains("fixture-key"))
        XCTAssertFalse(details.contains("c2VjcmV0LWZpbGU=")); XCTAssertFalse(details.contains(String(repeating: "QUJD", count: 100)))
        XCTAssertTrue(details.contains("generation-fixture")); XCTAssertTrue(details.contains("omitted"))
        var transcript = GenerationTranscript()
        _ = transcript.receive(.init(cursor: "1", turnID: "turn-a", type: "tool.call", text: "", toolName: "exec_command", callID: "call-a", arguments: details), for: "turn-a")
        _ = transcript.receive(.init(cursor: "2", turnID: "turn-a", type: "tool.result", text: "", toolName: nil, callID: "call-a", result: "exit code 1", toolStatus: "error"), for: "turn-a")
        XCTAssertEqual(transcript.entries.last?.kind, .toolResult)
        XCTAssertEqual(transcript.entries.last?.toolName, "exec_command")
        XCTAssertEqual(transcript.entries.last?.isError, true)
        XCTAssertEqual(transcript.entries.last?.title, "Tool failed")
    }

    func testOversizedTranscriptReportsItsRetentionLimit() {
        var transcript = GenerationTranscript()
        for index in 0...GenerationTranscript.maximumEntries {
            transcript.recordUser("Prompt \(index)", turnID: "turn-\(index)")
        }
        XCTAssertLessThanOrEqual(transcript.entries.count, GenerationTranscript.maximumEntries)
        XCTAssertNotNil(transcript.notice)
        XCTAssertGreaterThan(transcript.omittedEntries, 0)
    }
}

/// The first observation deliberately joins cancellation late, matching a socket
/// whose cancellation callback is still draining when the scene becomes active.
private actor TranscriptObservationFixture: GenerationClient {
    var cursors: [String] = []
    var creates = 0
    var sends = 0
    var cancels = 0
    var waiting = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let failReconnection: Bool
    private let step = Data("STEP lifecycle fixture".utf8)

    init(failReconnection: Bool = false) { self.failReconnection = failReconnection }
    func release() { waiter?.resume(); waiter = nil; waiting = false }
    func createAgent(requestID: String, inputFiles: [NanocodexInputFile], instructions: String) async throws -> String {
        creates += 1; return "agent-fixture"
    }
    func send(agentID: String, prompt: String, references: [String], revision: String?, requestID: String, turnID: String) async throws -> NanocodexTurnReceipt {
        sends += 1; return .init(agentID: agentID, turnID: turnID, requestID: requestID)
    }
    func events(agentID: String, after: String, untilTurnID: String?, receive: @escaping @Sendable (NanocodexEvent) async -> Void) async throws {
        cursors.append(after)
        if cursors.count == 1 {
            await receive(.init(cursor: "10", turnID: untilTurnID, type: "assistant.delta", text: "Inspecting ", toolName: nil, itemID: "update", modelCallIndex: 1, phase: "commentary"))
            waiting = true
            await withCheckedContinuation { waiter = $0 }
            try Task.checkCancellation()
        }
        if failReconnection { throw URLError(.networkConnectionLost) }
        // Include an overlap at the cursor boundary to verify replay coalescing.
        await receive(.init(cursor: "10", turnID: untilTurnID, type: "assistant.delta", text: "Inspecting ", toolName: nil, itemID: "update", modelCallIndex: 1, phase: "commentary"))
        await receive(.init(cursor: "11", turnID: untilTurnID, type: "assistant.message", text: "Inspecting the model.", toolName: nil, itemID: "update", modelCallIndex: 1, phase: "commentary"))
        await receive(.init(cursor: "12", turnID: untilTurnID, type: "turn_completed", text: "Saved the model.", toolName: nil))
    }
    func cancel(agentID: String, turnID: String) async throws { cancels += 1 }
    func localResult(agentID: String, turnID: String) async throws -> (preview: Data, step: Data)? {
        let revision = SHA256.hash(data: step).map { String(format: "%02x", $0) }.joined()
        let document = CADDocument(name: "model.step", revision: revision, faces: [
            CADFace(id: "o1.f1", positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], normals: [], indices: [0, 1, 2], area: 0.5)
        ], edges: [], vertices: [], parts: [])
        return (try JSONEncoder().encode(document), step)
    }
    func artifacts(agentID: String, turnID: String?) async throws -> NanocodexArtifactPage { throw NanocodexError.invalidResponse }
    func download(agentID: String, artifact: NanocodexArtifact) async throws -> URL { throw NanocodexError.invalidResponse }
    func downloadFile(agentID: String, path: String, expectedDigest: String?) async throws -> URL { throw NanocodexError.invalidResponse }
    nonisolated func close() {}
}

@MainActor
final class GenerationObservationTests: XCTestCase {
    private func seed(phase: String = "running") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var pending = PendingGeneration(prompt: "Make a bracket", references: [], files: [], instructions: "fixture")
        pending.agentID = "agent-fixture"; pending.phase = phase; pending.turnID = "turn-fixture"
        try JSONEncoder().encode(pending).write(to: root.appending(path: "generation.json"))
        return root
    }
    private func controller(_ root: URL, _ fixture: TranscriptObservationFixture) throws -> GenerationController {
        let credentials = try NanocodexCredentials(origin: "https://example.com", apiKey: "ncx_live_abcdefghijkl_" + String(repeating: "x", count: 43))
        return GenerationController(root: root, loadCredentials: { credentials }, makeClient: { _ in fixture })
    }
    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The fixture did not reach its expected state")
    }

    func testCloudTransportDefaultKeepsLegacyCheckpointNil() throws {
        let value = PendingGeneration(prompt: "Fixture", references: [], files: [], instructions: "fixture")
        XCTAssertEqual(value.transport, "cloud")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object.removeValue(forKey: "transport")
        let old = try JSONDecoder().decode(PendingGeneration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.transport)
    }

    func testPauseAndImmediateForegroundJoinObserverWithoutServerCancelOrResubmission() async throws {
        let root = try seed(), fixture = TranscriptObservationFixture()
        let value = try controller(root, fixture)
        var applied = 0
        value.onResult = { _, _ in applied += 1 }
        value.resumeWhenForeground()
        try await waitUntil { await fixture.waiting }
        XCTAssertEqual(value.statusSummary, "Inspecting")
        value.pauseObservation()
        value.resumeWhenForeground() // The old observer is still busy.
        value.resumeWhenForeground() // Repeated scene notifications still resume once.
        XCTAssertTrue(value.busy)
        XCTAssertNil(value.pending?.stopRequested)
        await fixture.release()
        try await waitUntil { !value.busy }
        let cursors = await fixture.cursors, creates = await fixture.creates, sends = await fixture.sends, cancels = await fixture.cancels
        XCTAssertEqual(cursors, ["0", "10"])
        XCTAssertEqual(creates, 0); XCTAssertEqual(sends, 0); XCTAssertEqual(cancels, 0)
        XCTAssertEqual(applied, 1)
        XCTAssertNil(value.pending)
        XCTAssertEqual(value.statusSummary, "Model ready")
        XCTAssertEqual(value.transcript.map(\.text), ["Make a bracket", "Inspecting the model.", "Saved the model.", "Model ready"])
        let restored = try controller(root, fixture)
        XCTAssertNil(restored.pending)
        XCTAssertEqual(restored.transcript, value.transcript)
        XCTAssertEqual(restored.response, "Saved the model.")
    }

    func testPauseAloneStaysPausedAndPreservesCursor() async throws {
        let root = try seed(), fixture = TranscriptObservationFixture()
        let value = try controller(root, fixture)
        value.resumeWhenForeground()
        try await waitUntil { await fixture.waiting }
        value.pauseObservation()
        await fixture.release()
        try await waitUntil { !value.busy }
        let cursors = await fixture.cursors, sends = await fixture.sends, cancels = await fixture.cancels
        XCTAssertEqual(cursors, ["0"]); XCTAssertEqual(sends, 0); XCTAssertEqual(cancels, 0)
        XCTAssertEqual(value.pending?.phase, "running")
        XCTAssertEqual(value.pending?.cursor, "10")
        XCTAssertNil(value.pending?.stopRequested)
        XCTAssertEqual(value.statusSummary, "Progress disconnected · Tap to reconnect")
        let restored = try controller(root, fixture)
        XCTAssertEqual(restored.transcript, value.transcript)
        XCTAssertEqual(restored.pending?.cursor, "10")
    }

    func testForegroundReconnectFailureDoesNotCreateAnAutomaticNetworkRetryLoop() async throws {
        let root = try seed(), fixture = TranscriptObservationFixture(failReconnection: true)
        let value = try controller(root, fixture)
        value.resumeWhenForeground()
        try await waitUntil { await fixture.waiting }
        value.pauseObservation(); value.resumeWhenForeground()
        await fixture.release()
        try await waitUntil { !value.busy }
        let cursors = await fixture.cursors, sends = await fixture.sends, cancels = await fixture.cancels
        XCTAssertEqual(cursors, ["0", "10"]); XCTAssertEqual(sends, 0); XCTAssertEqual(cancels, 0)
        XCTAssertEqual(value.pending?.phase, "running")
        XCTAssertNotNil(value.error)
        XCTAssertEqual(value.statusSummary, "Needs attention · Tap to resume")
    }

    func testForegroundDoesNotRestartFailedGeneration() async throws {
        let root = try seed(phase: "failed"), fixture = TranscriptObservationFixture()
        let value = try controller(root, fixture)
        value.resumeWhenForeground()
        XCTAssertFalse(value.busy)
        let cursors = await fixture.cursors, sends = await fixture.sends
        XCTAssertTrue(cursors.isEmpty); XCTAssertEqual(sends, 0)
        XCTAssertEqual(value.pending?.phase, "failed")
    }
}
