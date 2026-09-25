import Foundation
import CryptoKit

struct SavedReview: Codable {
    var revision: String
    var selected: Set<String>
    var drawing: Data?
    var camera: ViewportCameraState?
    var prompt: String
    var drawingImage: Data? = nil
}

struct WorkspacePersistence {
    private struct Manifest: Codable { var snapshot: String? }
    let root: URL
    var hasSavedWorkspace: Bool { FileManager.default.fileExists(atPath: manifestURL.path) }
    init(root: URL? = nil) {
        self.root = root ?? URL.documentsDirectory.appending(path: "NanoCAD", directoryHint: .isDirectory)
    }
    func prepare() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func saveDraft(_ text: String) throws {
        try prepare()
        try Data(text.utf8).write(to: root.appending(path: "draft.txt"), options: .atomic)
    }
    func loadDraft() throws -> String {
        let url = root.appending(path: "draft.txt")
        return FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
    }
    func save(_ review: SavedReview) throws {
        try prepare()
        try JSONEncoder().encode(review).write(to: root.appending(path: "review.json"), options: .atomic)
    }
    func loadReview(for revision: String) throws -> SavedReview? {
        let url = root.appending(path: "review.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(SavedReview.self, from: Data(contentsOf: url))
        return value.revision == revision ? value : nil
    }
    func saveDocument(_ data: Data, step: Data?) throws -> CADDocument {
        let doc = try CADDocument.decode(data)
        if let step { try Self.verify(step, document: doc) }
        try prepare()
        // Publish one pointer only after BOTH files exist. An interrupted write cannot
        // replace the previous document's STEP underneath its preview.
        let id = UUID().uuidString
        let directory = root.appending(path: "documents/" + id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            if let step { try step.write(to: directory.appending(path: "model.step"), options: .atomic) }
            try data.write(to: directory.appending(path: "model.cad.json"), options: .atomic)
            try JSONEncoder().encode(Manifest(snapshot: id)).write(to: manifestURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return doc
    }
    func loadDocument() throws -> CADDocument? {
        guard let directory = try currentDirectory() else { return nil }
        let url = directory.appending(path: "model.cad.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            if directory == root { return nil } // Legacy workspace with no document.
            throw NanocodexError.publication("The saved model preview is missing. Reopen the original STEP file.")
        }
        let doc = try CADDocument.decode(Data(contentsOf: url))
        let step = directory.appending(path: "model.step")
        if FileManager.default.fileExists(atPath: step.path) { try Self.verify(Data(contentsOf: step), document: doc) }
        return doc
    }
    var stepURL: URL? {
        guard let directory = try? currentDirectory(),
              let doc = try? loadDocument() else { return nil }
        let url = directory.appending(path: "model.step")
        guard let data = try? Data(contentsOf: url), (try? Self.verify(data, document: doc)) != nil else { return nil }
        return url
    }
    /// An empty committed manifest also suppresses legacy files after a relaunch.
    func clear() throws {
        try prepare()
        try JSONEncoder().encode(Manifest(snapshot: nil)).write(to: manifestURL, options: .atomic)
        try? FileManager.default.removeItem(at: root.appending(path: "review.json"))
        try? FileManager.default.removeItem(at: root.appending(path: "draft.txt"))
    }
    private var manifestURL: URL { root.appending(path: "workspace.json") }
    private func currentDirectory() throws -> URL? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return root }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard let id = manifest.snapshot else { return nil }
        guard UUID(uuidString: id) != nil else { throw NanocodexError.invalidResponse }
        return root.appending(path: "documents/" + id, directoryHint: .isDirectory)
    }
    private static func verify(_ step: Data, document: CADDocument) throws {
        let digest = SHA256.hash(data: step).map { String(format: "%02x", $0) }.joined()
        guard digest == document.revision else {
            throw NanocodexError.publication("The STEP file does not match the displayed preview. Reopen the original STEP file before editing or exporting.")
        }
    }
}
