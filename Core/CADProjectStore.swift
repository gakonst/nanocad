import Foundation
import Observation

struct CADProject: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    let legacyRoot: Bool
    let conversationID: String

    /// The original workspace retains its original Keychain entry. Every new
    /// project has a separate account and must receive its own Connect grant.
    var credentialProjectID: String? { legacyRoot ? nil : id }
}

@MainActor @Observable
final class CADProjectStore {
    private struct Manifest: Codable {
        var projects: [CADProject]
        var activeID: String?
    }

    private(set) var projects: [CADProject] = []
    private(set) var activeID: String?
    var activeProject: CADProject? { projects.first { $0.id == activeID } }

    private let directory: URL
    private let legacyConversationID: () throws -> String?
    private var loaded = false

    init(root: URL? = nil,
         legacyConversationID: @escaping () throws -> String? = ConnectionCredentials.legacyConversationID) {
        directory = root ?? URL.documentsDirectory.appending(path: "NanoCAD", directoryHint: .isDirectory)
        self.legacyConversationID = legacyConversationID
    }

    /// Loads an existing manifest or adopts the original workspace in place.
    /// No model, checkpoint, transcript, or credential is copied or deleted.
    func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            try validate(manifest)
            projects = manifest.projects
            activeID = manifest.activeID
        } else {
            let id = UUID().uuidString
            let conversation = try legacyConversationID() ?? id
            let project = CADProject(id: id, name: "My Project", createdAt: Date(),
                                     legacyRoot: true, conversationID: conversation)
            try commit(Manifest(projects: [project], activeID: id))
        }
        loaded = true
    }

    /// The project and conversation IDs are durably saved before callers can
    /// open Connect. New projects contain no model or connection from another project.
    @discardableResult
    func create(name: String? = nil) throws -> CADProject {
        try load()
        let id = UUID().uuidString
        let project = CADProject(id: id, name: normalized(name ?? "Project \(projects.count + 1)"),
                                 createdAt: Date(), legacyRoot: false, conversationID: id)
        try FileManager.default.createDirectory(at: root(for: project), withIntermediateDirectories: true)
        try commit(Manifest(projects: projects + [project], activeID: project.id))
        return project
    }

    func select(_ project: CADProject) throws {
        try load()
        guard projects.contains(where: { $0.id == project.id }) else { throw StoreError.missingProject }
        try commit(Manifest(projects: projects, activeID: project.id))
    }

    func rename(_ project: CADProject, to name: String) throws {
        try load()
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { throw StoreError.missingProject }
        var updated = projects
        updated[index].name = normalized(name)
        try commit(Manifest(projects: updated, activeID: activeID))
    }

    func root(for project: CADProject) -> URL {
        project.legacyRoot ? directory : directory.appending(path: "projects/\(project.id)", directoryHint: .isDirectory)
    }

    private var manifestURL: URL { directory.appending(path: "projects.json") }

    private func commit(_ manifest: Manifest) throws {
        try validate(manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        projects = manifest.projects
        activeID = manifest.activeID
    }

    private func validate(_ manifest: Manifest) throws {
        let ids = manifest.projects.compactMap { UUID(uuidString: $0.id) }
        let conversations = manifest.projects.compactMap { UUID(uuidString: $0.conversationID) }
        guard !manifest.projects.isEmpty,
              ids.count == manifest.projects.count, Set(ids).count == ids.count,
              conversations.count == manifest.projects.count, Set(conversations).count == conversations.count,
              manifest.projects.filter(\.legacyRoot).count <= 1,
              manifest.projects.contains(where: { $0.id == manifest.activeID }),
              manifest.projects.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw StoreError.invalidManifest
        }
    }

    private func normalized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Project" : trimmed
    }

    private enum StoreError: LocalizedError {
        case missingProject, invalidManifest
        var errorDescription: String? {
            switch self {
            case .missingProject: "This project could not be found. Reopen the project list."
            case .invalidManifest: "The saved project list could not be restored. Your project files have not been changed."
            }
        }
    }
}
