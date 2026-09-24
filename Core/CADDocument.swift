import Foundation

struct CADDocument: Codable, Identifiable, Sendable {
    var schemaVersion: Int = 1
    var name: String
    var revision: String
    var units: String = "mm"
    var faces: [CADFace]
    var edges: [CADEdge]
    var vertices: [CADVertex]
    var parts: [CADPart]
    var id: String { revision }
    var allReferences: Set<String> { Set(faces.map(\.id) + edges.map(\.id) + vertices.map(\.id) + parts.map(\.id)) }

    static func decode(_ data: Data) throws -> CADDocument {
        guard data.count <= 80_000_000 else { throw CADValidationError.tooLarge }
        let doc = try JSONDecoder().decode(Self.self, from: data)
        try doc.validate()
        return doc
    }

    func validate() throws {
        guard schemaVersion == 1, units == "mm", !revision.isEmpty, !faces.isEmpty else { throw CADValidationError.unsupported }
        guard faces.count <= 50_000, edges.count <= 100_000, vertices.count <= 100_000 else { throw CADValidationError.tooLarge }
        let ids = faces.map(\.id) + edges.map(\.id) + vertices.map(\.id) + parts.map(\.id)
        guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else { throw CADValidationError.invalidGeometry }
        for face in faces {
            guard face.positions.count >= 9, face.positions.count % 3 == 0,
                  face.normals.isEmpty || face.normals.count == face.positions.count,
                  face.indices.count >= 3, face.indices.count % 3 == 0,
                  face.indices.allSatisfy({ Int($0) < face.positions.count / 3 }),
                  (face.positions + face.normals).allSatisfy(\.isFinite), face.area.isFinite, face.area >= 0 else { throw CADValidationError.invalidGeometry }
        }
        for edge in edges {
            guard edge.points.count >= 6, edge.points.count % 3 == 0,
                  edge.points.allSatisfy(\.isFinite), edge.length.isFinite, edge.length >= 0 else { throw CADValidationError.invalidGeometry }
        }
        guard vertices.allSatisfy({ $0.position.count == 3 && $0.position.allSatisfy(\.isFinite) }) else { throw CADValidationError.invalidGeometry }
        let faceIDs = Set(faces.map(\.id))
        guard parts.allSatisfy({ Set($0.faceIDs).isSubset(of: faceIDs) }) else { throw CADValidationError.invalidGeometry }
    }

    func promptReferences(_ selected: Set<String>) -> [String] {
        selected.intersection(allReferences).sorted().map { "\(name)#\($0.trimmingCharacters(in: CharacterSet(charactersIn: "#")))" }
    }
}

struct CADFace: Codable, Identifiable, Sendable {
    var id: String
    var positions: [Float]
    var normals: [Float]
    var indices: [UInt32]
    var area: Double
}
struct CADEdge: Codable, Identifiable, Sendable {
    var id: String
    var points: [Float]
    var length: Double
}
struct CADVertex: Codable, Identifiable, Sendable {
    var id: String
    var position: [Float]
}
struct CADPart: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var faceIDs: [String]
}
enum CADValidationError: LocalizedError {
    case unsupported, invalidGeometry, tooLarge
    var errorDescription: String? {
        switch self {
        case .unsupported: "This preview uses an unsupported format or has no surfaces."
        case .invalidGeometry: "The CAD preview contains invalid geometry. Rebuild the preview from the STEP file."
        case .tooLarge: "This preview is too large to open safely. Ask Astra for a coarser preview."
        }
    }
}
