import XCTest
import CryptoKit
@testable import NanoCAD

/// Synthetic integrity/recovery fixtures; these do not exercise an authenticated CAD run.
@MainActor
final class CADCheckpointTests: XCTestCase {
    private let turnID = "checkpoint-test-turn"

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ name: String, bytes: Data) -> CADCheckpoint.File {
        .init(path: "r1/" + name, sha256: digest(bytes), size: bytes.count,
              data_base64: bytes.base64EncodedString())
    }

    private func checkpoint(step: Data = Data("synthetic STEP fixture".utf8),
                            name: String = "model.step", indices: [UInt32] = [0, 1, 2]) throws -> CADCheckpoint {
        let document = CADDocument(name: name, revision: digest(step), faces: [
            .init(id: "o1.f1", positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], normals: [], indices: indices, area: 0.5)
        ], edges: [], vertices: [], parts: [])
        return CADCheckpoint(turn_id: turnID, revision: 1, files: [
            file("model.step", bytes: step),
            file("model.cad.json", bytes: try JSONEncoder().encode(document))
        ])
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func restore(_ checkpoint: CADCheckpoint, phase: String = "running",
                         transport: String? = "cloud", pendingTurn: String? = nil) throws -> GenerationController {
        let root = try directory()
        var pending = PendingGeneration(prompt: "Fixture", references: [], files: [], instructions: "Fixture")
        pending.turnID = pendingTurn ?? turnID
        pending.agentID = "checkpoint-test-agent"
        pending.phase = phase
        pending.transport = transport
        try JSONEncoder().encode(pending).write(to: root.appending(path: "generation.json"))
        try JSONEncoder().encode(checkpoint).write(to: root.appending(path: "checkpoint.json"))
        return GenerationController(root: root, loadCredentials: { nil })
    }

    func testCheckpointRejectsTamperedBytesEvenWhenLengthMatches() throws {
        let valid = try checkpoint(), original = valid.files[0]
        let replacement = Data(repeating: 120, count: original.size)
        let corrupt = CADCheckpoint(turn_id: turnID, revision: 1, files: [
            .init(path: original.path, sha256: original.sha256, size: original.size,
                  data_base64: replacement.base64EncodedString()), valid.files[1]
        ])
        XCTAssertThrowsError(try corrupt.validated(for: turnID))
        let restored = try restore(corrupt)
        XCTAssertNil(restored.livePreview)
        XCTAssertEqual(restored.pending?.turnID, turnID, "A bad optional preview must not discard the durable request.")
    }

    func testCheckpointRejectsInvalidBase64AndDeclaredSizeMismatch() throws {
        let valid = try checkpoint(), original = valid.files[0]
        let invalidFiles: [CADCheckpoint.File] = [
            .init(path: original.path, sha256: original.sha256, size: original.size, data_base64: "not base64!"),
            .init(path: original.path, sha256: original.sha256, size: original.size + 1, data_base64: original.data_base64),
            .init(path: original.path, sha256: original.sha256, size: 0, data_base64: original.data_base64)
        ]
        for invalid in invalidFiles {
            let corrupt = CADCheckpoint(turn_id: turnID, revision: 1, files: [invalid, valid.files[1]])
            XCTAssertThrowsError(try corrupt.validated(for: turnID))
        }
    }

    func testMatchingHashesDoNotBypassPreviewGeometryOrFilenameValidation() throws {
        let invalidGeometry = try checkpoint(indices: [0, 1, 3])
        let wrongName = try checkpoint(name: "unrelated.step")
        for invalid in [invalidGeometry, wrongName] {
            XCTAssertThrowsError(try invalid.validated(for: turnID))
            XCTAssertNil(try restore(invalid).livePreview)
        }
    }

    func testRestorationIgnoresForeignFailedAndLegacyCheckpoints() throws {
        let valid = try checkpoint()
        for restored in [
            try restore(valid, pendingTurn: "another-turn"),
            try restore(valid, phase: "failed"),
            try restore(valid, transport: nil),
            try restore(valid, transport: "native")
        ] {
            XCTAssertNil(restored.livePreview)
            XCTAssertNotNil(restored.pending)
        }
    }

    func testDownloadingRestoresLastCoherentPreviewWithoutCommittingIt() throws {
        let valid = try checkpoint()
        let restored = try restore(valid, phase: "downloading")
        XCTAssertEqual(restored.previewRevision, 1)
        XCTAssertEqual(restored.livePreview?.step, Data("synthetic STEP fixture".utf8))
        XCTAssertEqual(restored.pending?.phase, "downloading")
        XCTAssertFalse(restored.busy)
        XCTAssertTrue(restored.canResume)
    }

    func testExactOneMegabyteSTEPBoundary() throws {
        let atLimit = try checkpoint(step: Data(repeating: 65, count: 1_000_000))
        XCTAssertEqual(try atLimit.validated(for: turnID).step.count, 1_000_000)
        let overLimit = try checkpoint(step: Data(repeating: 65, count: 1_000_001))
        XCTAssertThrowsError(try overLimit.validated(for: turnID))
    }
}
