import XCTest
import CryptoKit
@testable import NanoCAD

private func revision(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func preview(_ step: Data, name: String = "model.step") throws -> Data {
    try JSONEncoder().encode(CADDocument(name: name, revision: revision(step), faces: [
        CADFace(id: "o1.f1", positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], normals: [], indices: [0, 1, 2], area: 0.5)
    ], edges: [], vertices: [], parts: []))
}

private actor GenerationFixture: GenerationClient {
    var createKeys: [String] = []
    var sendKeys: [String] = []
    var turnIDs: [String] = []
    var cursors: [String] = []
    var cancels = 0
    var liveReads = 0
    var failFirstSend = false
    var disconnectFirstStream = false
    var holdCreate = false
    var missingLocalOutput = false
    var scriptedEvents: [NanocodexEvent]?
    var createWaiter: CheckedContinuation<Void, Never>?
    var page: NanocodexArtifactPage
    var output: [String: Data]
    init(step: Data, turn: String = "turn-fixture", missing: Bool = false, corrupt: Bool = false) throws {
        let json = try preview(corrupt ? Data("other revision".utf8) : step)
        output = ["/brain/outputs/model.step": step, "/brain/outputs/model.cad.json": json]
        page = NanocodexArtifactPage(data: missing ? [] : output.map { path, bytes in
            NanocodexArtifact(id: revision(Data(path.utf8)), turnID: turn, path: path, digest: revision(bytes), size: bytes.count)
        }, publications: [.init(turnID: turn, state: "ready", error: nil)])
    }
    func configure(failSend: Bool = false, disconnect: Bool = false, hold: Bool = false) {
        failFirstSend = failSend; disconnectFirstStream = disconnect; holdCreate = hold
    }
    func configureEvents(_ events: [NanocodexEvent]) { scriptedEvents = events }
    func configureMissingLocalOutput() { missingLocalOutput = true }
    func localResult(agentID: String, turnID: String) async throws -> (preview: Data, step: Data)? {
        if missingLocalOutput { throw NanocodexError.missingCADOutput }; return nil
    }
    func releaseCreate() { createWaiter?.resume(); createWaiter = nil }
    func createAgent(requestID: String, inputFiles: [NanocodexInputFile], instructions: String) async throws -> String {
        createKeys.append(requestID)
        if holdCreate { await withCheckedContinuation { createWaiter = $0 } }
        return "agent-fixture"
    }
    func send(agentID: String, prompt: String, references: [String], revision: String?, requestID: String, turnID: String) async throws -> NanocodexTurnReceipt {
        sendKeys.append(requestID); turnIDs.append(turnID)
        if failFirstSend && sendKeys.count == 1 { throw URLError(.networkConnectionLost) }
        return NanocodexTurnReceipt(agentID: agentID, turnID: turnID, requestID: requestID)
    }
    func events(agentID: String, after: String, untilTurnID: String?, receive: @escaping @Sendable (NanocodexEvent) async -> Void) async throws {
        cursors.append(after)
        if let scriptedEvents {
            for event in scriptedEvents { await receive(event) }
            return
        }
        if disconnectFirstStream && cursors.count == 1 {
            await receive(.init(cursor: "9007199254740993", turnID: untilTurnID, type: "assistant.delta", text: "Working", toolName: nil))
            throw NanocodexError.streamEnded
        }
        await receive(.init(cursor: "9007199254740994", turnID: "another-turn", type: "turn_failed", text: "wrong turn", toolName: nil))
        await receive(.init(cursor: "9007199254740995", turnID: untilTurnID, type: "turn_completed", text: "Saved", toolName: nil))
    }
    func cancel(agentID: String, turnID: String) async throws { cancels += 1 }
    func artifacts(agentID: String, turnID: String?) async throws -> NanocodexArtifactPage { page }
    func download(agentID: String, artifact: NanocodexArtifact) async throws -> URL { try temporary(output[artifact.path]!) }
    func downloadFile(agentID: String, path: String, expectedDigest: String?) async throws -> URL { liveReads += 1; return try temporary(output[path]!) }
    private func temporary(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try data.write(to: url); return url
    }
    nonisolated func close() {}
}

@MainActor
final class GenerationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func pending(_ phase: String = "sending") -> PendingGeneration {
        var value = PendingGeneration(prompt: "Make a bracket", references: [], files: [], instructions: "fixture")
        value.creationID = "creation-fixture"; value.requestID = "request-fixture"; value.turnID = "turn-fixture"
        value.agentID = phase == "creating" ? nil : "agent-fixture"; value.phase = phase
        return value
    }
    private func seed(_ value: PendingGeneration, at root: URL) throws {
        try JSONEncoder().encode(value).write(to: root.appending(path: "generation.json"))
    }
    private func controller(_ root: URL, _ fixture: GenerationFixture) throws -> GenerationController {
        let credentials = try NanocodexCredentials(origin: "https://example.com", apiKey: "ncx_live_abcdefghijkl_" + String(repeating: "x", count: 43))
        return GenerationController(root: root, loadCredentials: { credentials }, makeClient: { _ in fixture })
    }
    private func idle(_ value: GenerationController) async throws {
        for _ in 0..<200 {
            if !value.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Generation did not settle")
    }

    func testAmbiguousAdmissionRetriesPersistedIDsAndAppliesOnce() async throws {
        let root = try directory(), fixture = try GenerationFixture(step: Data("STEP-one".utf8))
        await fixture.configure(failSend: true)
        try seed(pending(), at: root)
        let first = try controller(root, fixture)
        first.resume(); try await idle(first)
        XCTAssertEqual(first.pending?.phase, "sending")
        let restored = try controller(root, fixture)
        var applied = 0
        restored.onResult = { _, _ in applied += 1 }
        restored.resume(); try await idle(restored)
        let keys = await fixture.sendKeys, ids = await fixture.turnIDs
        XCTAssertEqual(keys, ["request-fixture", "request-fixture"])
        XCTAssertEqual(ids, ["turn-fixture", "turn-fixture"])
        XCTAssertEqual(applied, 1); XCTAssertNil(restored.pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "generation.json").path))
    }

    func testDisconnectedStreamResumesCursorWithoutResubmitting() async throws {
        let root = try directory(), fixture = try GenerationFixture(step: Data("STEP-one".utf8))
        await fixture.configure(disconnect: true)
        try seed(pending("running"), at: root)
        let first = try controller(root, fixture)
        first.resume(); try await idle(first)
        XCTAssertEqual(first.pending?.cursor, "9007199254740993")
        let restored = try controller(root, fixture)
        XCTAssertEqual(restored.response, "Working")
        restored.onResult = { _, _ in }
        restored.resume(); try await idle(restored)
        let cursors = await fixture.cursors, keys = await fixture.sendKeys
        XCTAssertEqual(cursors, ["0", "9007199254740993"]); XCTAssertTrue(keys.isEmpty)
        XCTAssertNil(restored.pending)
    }

    func testVisibleTranscriptSurvivesCompletedRunClearAndRelaunch() async throws {
        let root = try directory(), fixture = try GenerationFixture(step: Data("STEP-one".utf8))
        await fixture.configureEvents([
            .init(cursor: "1", turnID: "turn-fixture", type: "assistant.delta", text: "Reading ", toolName: nil, itemID: "update", modelCallIndex: 1, phase: "commentary"),
            .init(cursor: "1", turnID: "turn-fixture", type: "assistant.delta", text: "Reading ", toolName: nil, itemID: "update", modelCallIndex: 1, phase: "commentary"),
            .init(cursor: "2", turnID: "turn-fixture", type: "assistant.message", text: "Reading the model.", toolName: nil, itemID: "update", modelCallIndex: 1, phase: "commentary"),
            .init(cursor: "3", turnID: "turn-fixture", type: "tool.call", text: "", toolName: "exec_command", callID: "call-1", arguments: "python model.py"),
            .init(cursor: "4", turnID: "turn-fixture", type: "tool.result", text: "", toolName: "exec_command", callID: "call-1", result: "Model exported", toolStatus: "completed"),
            .init(cursor: "5", turnID: "turn-fixture", type: "assistant.message", text: "Saved", toolName: nil, itemID: "final", modelCallIndex: 2, phase: "final_answer"),
            .init(cursor: "6", turnID: "turn-fixture", type: "turn_completed", text: "Saved", toolName: nil)
        ])
        try seed(pending("running"), at: root)
        let value = try controller(root, fixture)
        value.onResult = { _, _ in }
        value.resume(); try await idle(value)
        XCTAssertNil(value.pending)
        XCTAssertEqual(value.statusSummary, "Model ready")
        XCTAssertEqual(value.transcript.map(\.kind), [.user, .commentary, .toolCall, .toolResult, .final, .notice])
        XCTAssertEqual(value.transcript.filter { $0.kind == .commentary }.map(\.text), ["Reading the model."])
        let restored = try controller(root, fixture)
        XCTAssertNil(restored.pending)
        XCTAssertEqual(restored.transcript, value.transcript)
        XCTAssertEqual(restored.response, "Saved")
    }

    func testServerFailureNeverBecomesModelReadyAndRemainsAfterDismissal() async throws {
        let root = try directory(), fixture = try GenerationFixture(step: Data("STEP-one".utf8))
        await fixture.configureEvents([
            .init(cursor: "1", turnID: "turn-fixture", type: "tool.result", text: "", toolName: "exec_command", result: "Invalid geometry", toolStatus: "error"),
            .init(cursor: "2", turnID: "turn-fixture", type: "turn_failed", text: "The model failed validation.", toolName: nil)
        ])
        try seed(pending("running"), at: root)
        let value = try controller(root, fixture)
        value.onResult = { _, _ in XCTFail("A failed turn cannot deliver a model") }
        value.resume(); try await idle(value)
        XCTAssertEqual(value.pending?.phase, "failed")
        XCTAssertEqual(value.statusSummary, "Generation failed")
        XCTAssertTrue(value.transcript.contains { $0.kind == .toolResult && $0.isError })
        value.forgetFailedRun()
        XCTAssertNil(value.pending)
        let restored = try controller(root, fixture)
        XCTAssertEqual(restored.transcript, value.transcript)
        XCTAssertTrue(restored.transcript.contains { $0.kind == .error && $0.text.contains("failed validation") })
    }

    func testStopDuringCreationJoinsReceiptAndNeverSendsTurn() async throws {
        let root = try directory(), fixture = try GenerationFixture(step: Data("STEP-one".utf8))
        await fixture.configure(hold: true)
        try seed(pending("creating"), at: root)
        let value = try controller(root, fixture)
        value.resume()
        for _ in 0..<100 {
            if await fixture.createWaiter != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        value.stop()
        let saved = try JSONDecoder().decode(PendingGeneration.self, from: Data(contentsOf: root.appending(path: "generation.json")))
        XCTAssertEqual(saved.stopRequested, true)
        await fixture.releaseCreate()
        try await idle(value)
        let keys = await fixture.sendKeys, cancellations = await fixture.cancels
        XCTAssertTrue(keys.isEmpty); XCTAssertEqual(cancellations, 1)
        XCTAssertNil(value.pending); XCTAssertEqual(value.status, "Stopped")
    }

    func testRelaunchedStopRetriesCancelWithoutAdmission() async throws {
        let root = try directory(), fixture = try GenerationFixture(step: Data("STEP-one".utf8))
        var saved = pending(); saved.stopRequested = true
        try seed(saved, at: root)
        let value = try controller(root, fixture)
        value.resume(); try await idle(value)
        let keys = await fixture.sendKeys, cancellations = await fixture.cancels
        XCTAssertTrue(keys.isEmpty); XCTAssertEqual(cancellations, 1); XCTAssertNil(value.pending)
    }

    func testTextOnlyCompletionCanRetryWithoutReplacingWorkspaceOrRepeatingTheFinishedTurn() async throws {
        let root = try directory(), fixture = try GenerationFixture(step: Data("original".utf8))
        await fixture.configureMissingLocalOutput()
        let original = pending("running")
        try seed(original, at: root)
        let value = try controller(root, fixture)
        value.onResult = { _, _ in XCTFail("A text-only response must not replace geometry") }
        value.resume(); try await idle(value)
        XCTAssertEqual(value.pending?.phase, "failed")
        XCTAssertNotNil(value.error)
        XCTAssertTrue(try JSONDecoder().decode(PendingGeneration.self, from: Data(contentsOf: root.appending(path: "generation.json"))).phase == "failed")
        value.retryFailedRun(); try await idle(value)
        XCTAssertNotEqual(value.pending?.turnID, original.turnID)
        XCTAssertNotEqual(value.pending?.requestID, original.requestID)
        XCTAssertEqual(value.pending?.prompt, original.prompt)
        XCTAssertEqual(value.pending?.references, original.references)
        let sends = await fixture.turnIDs
        XCTAssertEqual(sends.count, 1)
        XCTAssertNotEqual(sends.first, original.turnID)
    }

    func testMissingPublishedPairDoesNotUseUnpublishedWorkspaceFiles() async throws {
        let root = try directory(), fixture = try GenerationFixture(step: Data("STEP-one".utf8), missing: true)
        try seed(pending("downloading"), at: root)
        let value = try controller(root, fixture)
        value.onResult = { _, _ in XCTFail("Missing pair was applied") }
        value.resume(); try await idle(value)
        let liveReads = await fixture.liveReads
        XCTAssertEqual(liveReads, 0); XCTAssertNotNil(value.error); XCTAssertNotNil(value.pending)
    }

    func testWrongRevisionNeverReplacesWorkspace() async throws {
        let root = try directory(), fixture = try GenerationFixture(step: Data("STEP-one".utf8), corrupt: true)
        try seed(pending("downloading"), at: root)
        let value = try controller(root, fixture)
        value.onResult = { _, _ in XCTFail("Mismatched pair was applied") }
        value.resume(); try await idle(value)
        XCTAssertNotNil(value.error); XCTAssertEqual(value.pending?.phase, "downloading")
    }

    func testWorkspaceRejectsMismatchedSaveAndKeepsCommittedPair() throws {
        let root = try directory(), storage = WorkspacePersistence(root: root)
        let original = Data("STEP-original".utf8), next = Data("STEP-next".utf8)
        _ = try storage.saveDocument(preview(original, name: "bracket.step"), step: original)
        XCTAssertThrowsError(try storage.saveDocument(preview(next), step: original))
        XCTAssertEqual(try storage.loadDocument()?.name, "bracket.step")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(storage.stepURL)), original)
        // Orphaned files from an interrupted save cannot change the manifest.
        let orphan = root.appending(path: "documents/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try next.write(to: orphan.appending(path: "model.step"))
        XCTAssertEqual(try storage.loadDocument()?.revision, revision(original))
        try storage.clear()
        XCTAssertNil(try WorkspacePersistence(root: root).loadDocument()); XCTAssertNil(storage.stepURL)
    }

    func testLegacyMismatchCannotBeExportedAndPreviewOnlyRemovesSTEP() throws {
        let root = try directory(), storage = WorkspacePersistence(root: root)
        let original = Data("STEP-original".utf8)
        try preview(original).write(to: root.appending(path: "model.cad.json"))
        try Data("wrong".utf8).write(to: root.appending(path: "model.step"))
        XCTAssertThrowsError(try storage.loadDocument()); XCTAssertNil(storage.stepURL)
        _ = try storage.saveDocument(preview(original), step: nil)
        XCTAssertNotNil(try storage.loadDocument()); XCTAssertNil(storage.stepURL)
        try storage.clear()
        XCTAssertNil(try storage.loadDocument()) // Must not resurrect the legacy pair.
    }

    func testSavedReviewImageIsOptionalForOlderWorkspaces() throws {
        let old = Data(#"{"revision":"old","selected":[],"prompt":"edit"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SavedReview.self, from: old).drawingImage)
        let root = try directory(), storage = WorkspacePersistence(root: root)
        let image = Data([1, 2, 3])
        try storage.save(SavedReview(revision: "r", selected: [], drawing: nil, camera: nil, prompt: "edit", drawingImage: image))
        XCTAssertEqual(try storage.loadReview(for: "r")?.drawingImage, image)
        XCTAssertNil(try storage.loadReview(for: "other"))
    }
}
