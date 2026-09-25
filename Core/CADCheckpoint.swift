import Foundation
import CryptoKit

/// A checkpoint is a coherent intermediate pair, never a final publication.
struct CADCheckpoint: Codable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let sha256: String
        let size: Int
        let data_base64: String
    }
    let turn_id: String
    let revision: Int
    let files: [File]

    func validated(for turnID: String) throws -> LiveCADPreview {
        guard turn_id == turnID, revision > 0, files.count == 2 else { throw NanocodexError.integrityFailure }
        func bytes(_ name: String) throws -> Data {
            let matches = files.filter { $0.path == "r\(revision)/" + name }
            guard matches.count == 1, let file = matches.first, (1...1_000_000).contains(file.size),
                  file.data_base64.count <= 1_333_336,
                  let bytes = Data(base64Encoded: file.data_base64), bytes.count == file.size,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw NanocodexError.integrityFailure
            }
            return bytes
        }
        let step = try bytes("model.step"), preview = try bytes("model.cad.json")
        let document = try CADDocument.decode(preview)
        guard document.name == "model.step", document.revision == SHA256.hash(data: step).map({ String(format: "%02x", $0) }).joined() else {
            throw NanocodexError.integrityFailure
        }
        return LiveCADPreview(revision: revision, document: document, preview: preview, step: step)
    }
}
struct LiveCADPreview: Sendable {
    let revision: Int
    let document: CADDocument
    let preview: Data
    let step: Data
}
