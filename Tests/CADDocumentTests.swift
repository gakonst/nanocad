import CryptoKit
import Foundation
import XCTest
@testable import NanoCAD

final class CADDocumentTests: XCTestCase {
    func testBundledPreviewMatchesTheExactSTEPRevision() throws {
        // These tests are hosted by NanoCAD. Bundle.main must contain the real shipped assets.
        let previewURL = try XCTUnwrap(Bundle.main.url(forResource: "precision-bracket.cad", withExtension: "json"))
        let stepURL = try XCTUnwrap(Bundle.main.url(forResource: "precision-bracket", withExtension: "step"))
        let document = try CADDocument.decode(Data(contentsOf: previewURL))
        let step = try Data(contentsOf: stepURL)
        let digest = revision(of: step)

        XCTAssertEqual(document.revision, digest, "Face references must describe the bundled STEP's exact bytes.")
        XCTAssertEqual(document.name, "precision-bracket.step")
        XCTAssertEqual(document.units, "mm")
        XCTAssertEqual(document.faces.count, 11)
        XCTAssertEqual(document.edges.count, 27)
        XCTAssertEqual(document.vertices.count, 18)
        XCTAssertEqual(document.parts.count, 1)
        XCTAssertEqual(document.allReferences.count, 57)
        XCTAssertEqual(Set(document.parts[0].faceIDs), Set(document.faces.map(\.id)))
        XCTAssertEqual(document.parts[0].id, "o1")
        XCTAssertGreaterThan(document.faces.reduce(0) { $0 + $1.indices.count / 3 }, 100,
                             "The shipped preview must contain tessellated surfaces.")
        XCTAssertTrue(String(decoding: step.prefix(100), as: UTF8.self).contains("ISO-10303-21;"))
    }

    func testValidTriangleDecodesWithOptionalNormals() throws {
        var document = triangleDocument()
        let decoded = try CADDocument.decode(JSONEncoder().encode(document))
        XCTAssertEqual(decoded.faces[0].positions, document.faces[0].positions)
        XCTAssertEqual(decoded.faces[0].indices, [0, 1, 2])
        XCTAssertEqual(decoded.faces[0].normals, document.faces[0].normals)
        document.faces[0].normals = []
        XCTAssertNoThrow(try CADDocument.decode(JSONEncoder().encode(document)))
    }

    @MainActor
    func testMalformedPackedGeometryIsRejectedBeforeRendering() throws {
        let cases: [(String, (inout CADDocument) -> Void)] = [
            ("fewer than three face vertices", { $0.faces[0].positions = [0, 0, 0, 1, 0, 0] }),
            ("partial position triple", { $0.faces[0].positions.append(1) }),
            ("normal count does not match positions", { $0.faces[0].normals = [0, 0, 1] }),
            ("missing triangles", { $0.faces[0].indices = [] }),
            ("partial triangle", { $0.faces[0].indices = [0, 1, 2, 0] }),
            ("vertex index past buffer end", { $0.faces[0].indices = [0, 1, 3] }),
            ("maximum unsigned index", { $0.faces[0].indices = [0, 1, .max] }),
            ("negative surface area", { $0.faces[0].area = -1 }),
            ("edge with only one point", { $0.edges[0].points = [0, 0, 0] }),
            ("partial edge point", { $0.edges[0].points.append(1) }),
            ("negative edge length", { $0.edges[0].length = -1 }),
            ("short vertex", { $0.vertices[0].position = [0, 0] }),
            ("oversized vertex", { $0.vertices[0].position = [0, 0, 0, 1] }),
            ("empty reference", { $0.edges[0].id = "" }),
            ("duplicate reference across entity kinds", { $0.edges[0].id = "o1.f1" }),
            ("body references a missing face", { $0.parts[0].faceIDs = ["o1.f999"] })
        ]
        for (name, mutate) in cases {
            try XCTContext.runActivity(named: name) { _ in
                var document = triangleDocument()
                mutate(&document)
                let data = try JSONEncoder().encode(document)
                XCTAssertThrowsError(try CADDocument.decode(data)) { error in
                    guard case CADValidationError.invalidGeometry = error else {
                        return XCTFail("Expected invalid geometry for \(name), received \(error)")
                    }
                }
            }
        }
    }

    @MainActor
    func testNonFiniteGeometryIsRejectedByValidation() throws {
        // JSONEncoder rejects NaN/Infinity itself, so exercise the model's own boundary directly.
        let cases: [(String, (inout CADDocument) -> Void)] = [
            ("NaN position", { $0.faces[0].positions[0] = .nan }),
            ("infinite normal", { $0.faces[0].normals[0] = .infinity }),
            ("infinite area", { $0.faces[0].area = .infinity }),
            ("infinite edge point", { $0.edges[0].points[0] = -.infinity }),
            ("NaN edge length", { $0.edges[0].length = .nan }),
            ("NaN vertex", { $0.vertices[0].position[0] = .nan })
        ]
        for (name, mutate) in cases {
            try XCTContext.runActivity(named: name) { _ in
                var document = triangleDocument()
                mutate(&document)
                XCTAssertThrowsError(try document.validate()) { error in
                    guard case CADValidationError.invalidGeometry = error else {
                        return XCTFail("Expected invalid geometry for \(name), received \(error)")
                    }
                }
            }
        }
    }

    @MainActor
    func testUnsupportedDocumentContractsAreRejected() throws {
        let cases: [(String, (inout CADDocument) -> Void)] = [
            ("future schema", { $0.schemaVersion = 2 }),
            ("unsupported units", { $0.units = "in" }),
            ("missing revision", { $0.revision = "" }),
            ("no surfaces", { $0.faces = [] })
        ]
        for (name, mutate) in cases {
            try XCTContext.runActivity(named: name) { _ in
                var document = triangleDocument()
                mutate(&document)
                let data = try JSONEncoder().encode(document)
                XCTAssertThrowsError(try CADDocument.decode(data)) { error in
                    guard case CADValidationError.unsupported = error else {
                        return XCTFail("Expected unsupported document for \(name), received \(error)")
                    }
                }
            }
        }
    }

    func testPromptReferencesIncludeOnlyExistingTopologyAndHaveDocumentNames() {
        let document = triangleDocument()
        let selected: Set<String> = ["o1.v1", "o1.f1", "o1", "o1.e1", "o1.f999", "other.step#o1.f1"]
        XCTAssertEqual(document.promptReferences(selected), [
            "fixture.step#o1", "fixture.step#o1.e1", "fixture.step#o1.f1", "fixture.step#o1.v1"
        ])
        XCTAssertEqual(document.promptReferences([]), [])
        XCTAssertEqual(document.promptReferences(["missing"]), [])
    }

    func testReviewRestoresForItsRevisionAndIsIgnoredForAReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "NanoCADTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = WorkspacePersistence(root: root)
        var document = triangleDocument()
        let firstSTEP = Data("first STEP".utf8)
        document.revision = revision(of: firstSTEP)
        _ = try persistence.saveDocument(JSONEncoder().encode(document), step: firstSTEP)
        let camera = ViewportCameraState(transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 10, 20, 30, 1],
                                         target: [0, 0, 0], orthographicScale: 50)
        let drawing = Data([1, 2, 3, 4])
        let review = SavedReview(revision: document.revision, selected: ["o1.f1", "o1.e1"],
                                 drawing: drawing, camera: camera, prompt: "Enlarge this hole")
        try persistence.save(review)

        let reopened = WorkspacePersistence(root: root)
        let restored = try XCTUnwrap(reopened.loadReview(for: document.revision))
        XCTAssertEqual(restored.selected, review.selected)
        XCTAssertEqual(restored.drawing, drawing)
        XCTAssertEqual(restored.camera, camera)
        XCTAssertEqual(restored.prompt, review.prompt)

        // Topology ordinals can be reused by another revision; that must not revive the old markup.
        let replacementSTEP = Data("replacement STEP".utf8)
        document.revision = revision(of: replacementSTEP)
        _ = try reopened.saveDocument(JSONEncoder().encode(document), step: replacementSTEP)
        let replacement = try XCTUnwrap(reopened.loadDocument())
        XCTAssertEqual(replacement.revision, revision(of: replacementSTEP))
        XCTAssertNil(try reopened.loadReview(for: replacement.revision))
    }

    func testRejectedImportLeavesThePreviousDocumentAndSTEPUsable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "NanoCADTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = WorkspacePersistence(root: root)
        var original = triangleDocument()
        let originalSTEP = Data("previous STEP bytes".utf8)
        original.revision = revision(of: originalSTEP)
        _ = try persistence.saveDocument(JSONEncoder().encode(original), step: originalSTEP)
        var malformed = original
        malformed.revision = "invalid-replacement"
        malformed.faces[0].indices = [0, 1, 99]

        XCTAssertThrowsError(try persistence.saveDocument(JSONEncoder().encode(malformed), step: Data("new STEP".utf8)))
        XCTAssertEqual(try persistence.loadDocument()?.revision, original.revision)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(persistence.stepURL)), originalSTEP)
    }

    func testMismatchedSTEPIsRejectedWithoutReplacingTheSavedPair() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "NanoCADTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = WorkspacePersistence(root: root)
        let step = Data("matching STEP bytes".utf8)
        var document = triangleDocument()
        document.revision = revision(of: step)
        let preview = try JSONEncoder().encode(document)
        _ = try persistence.saveDocument(preview, step: step)

        XCTAssertThrowsError(try persistence.saveDocument(preview, step: Data("different STEP bytes".utf8)))
        XCTAssertEqual(try persistence.loadDocument()?.revision, document.revision)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(persistence.stepURL)), step)
    }

    private func revision(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func triangleDocument() -> CADDocument {
        CADDocument(name: "fixture.step", revision: "original-revision", faces: [
            CADFace(id: "o1.f1", positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
                    normals: [0, 0, 1, 0, 0, 1, 0, 0, 1], indices: [0, 1, 2], area: 0.5)
        ], edges: [CADEdge(id: "o1.e1", points: [0, 0, 0, 1, 0, 0], length: 1)],
           vertices: [CADVertex(id: "o1.v1", position: [0, 0, 0])],
           parts: [CADPart(id: "o1", name: "Triangle", faceIDs: ["o1.f1"])])
    }
}
