import Foundation
import XCTest
@testable import NanoCAD

@MainActor
final class CADProjectStoreTests: XCTestCase {
    func testLegacyMigrationKeepsExistingWorkspaceAndConversationInPlace() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let savedFiles = ["model.step", "workspace.json", "review.json", "generation.json", "transcript.json", "documents/existing/model.step", "personal-notes.txt"]
        for path in savedFiles {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("existing \(path)".utf8).write(to: url)
        }
        let conversation = UUID().uuidString
        let store = CADProjectStore(root: root, legacyConversationID: { conversation })
        try store.load()
        let project = try XCTUnwrap(store.activeProject)

        XCTAssertTrue(project.legacyRoot)
        XCTAssertNil(project.credentialProjectID)
        XCTAssertEqual(store.root(for: project), root)
        XCTAssertEqual(project.conversationID, conversation)
        XCTAssertEqual(store.projects.count, 1)
        for path in savedFiles {
            XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), Data("existing \(path)".utf8))
        }
        let restored = CADProjectStore(root: root, legacyConversationID: { XCTFail("Migration must not rerun"); return nil })
        try restored.load()
        XCTAssertEqual(restored.activeProject, project)
        XCTAssertEqual(restored.projects, store.projects)
    }

    func testNewProjectsAreBlankAndRestoreIndependentStableIdentities() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CADProjectStore(root: root, legacyConversationID: { nil })
        try store.load()
        let legacy = try XCTUnwrap(store.activeProject)
        let first = try store.create(name: "Widget")
        let second = try store.create(name: "Widget")

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.conversationID, second.conversationID)
        XCTAssertNotEqual(first.conversationID, legacy.conversationID)
        XCTAssertEqual(first.credentialProjectID, first.id)
        XCTAssertEqual(second.credentialProjectID, second.id)
        XCTAssertFalse(first.legacyRoot)
        XCTAssertEqual(store.root(for: first), root.appending(path: "projects/\(first.id)", directoryHint: .isDirectory))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root(for: first).path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root(for: second).path), [])

        // Each create is already persisted before the project can be passed to Connect.
        let afterCreate = CADProjectStore(root: root, legacyConversationID: { nil })
        try afterCreate.load()
        XCTAssertEqual(afterCreate.activeProject, second)
        XCTAssertEqual(afterCreate.projects, [legacy, first, second])

        let model = Data("first project's design".utf8)
        try model.write(to: store.root(for: first).appending(path: "model.step"))
        try store.select(first)
        let restored = CADProjectStore(root: root, legacyConversationID: { nil })
        try restored.load()
        XCTAssertEqual(restored.activeProject, first)
        XCTAssertEqual(restored.projects.map(\.conversationID), store.projects.map(\.conversationID))
        XCTAssertEqual(try Data(contentsOf: restored.root(for: first).appending(path: "model.step")), model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.root(for: second).appending(path: "model.step").path))
    }

    func testRenamePreservesProjectDirectoryAndConversation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CADProjectStore(root: root, legacyConversationID: { nil })
        let project = try store.create()
        let originalRoot = store.root(for: project)
        try store.rename(project, to: "  Revised model  \n")

        let restored = CADProjectStore(root: root, legacyConversationID: { nil })
        try restored.load()
        let renamed = try XCTUnwrap(restored.activeProject)
        XCTAssertEqual(renamed.name, "Revised model")
        XCTAssertEqual(renamed.id, project.id)
        XCTAssertEqual(renamed.conversationID, project.conversationID)
        XCTAssertEqual(renamed.credentialProjectID, project.credentialProjectID)
        XCTAssertEqual(restored.root(for: renamed), originalRoot)
    }

    func testUnreadableManifestDoesNotResetOrDeleteWorkspace() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let damaged = Data("interrupted user-edited manifest".utf8)
        let design = Data("existing design".utf8)
        try damaged.write(to: root.appending(path: "projects.json"))
        try design.write(to: root.appending(path: "model.step"))
        let store = CADProjectStore(root: root, legacyConversationID: { XCTFail("Must not remigrate over a saved list"); return nil })

        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.create())
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "projects.json")), damaged)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "model.step")), design)
        XCTAssertTrue(store.projects.isEmpty)
    }

    func testDuplicateConversationManifestCannotShareOneGrantAcrossProjects() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CADProjectStore(root: root, legacyConversationID: { nil })
        _ = try store.create()
        let manifestURL = root.appending(path: "projects.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
        projects[1]["conversationID"] = projects[0]["conversationID"]
        json["projects"] = projects
        let damaged = try JSONSerialization.data(withJSONObject: json)
        try damaged.write(to: manifestURL)

        let restored = CADProjectStore(root: root, legacyConversationID: { nil })
        XCTAssertThrowsError(try restored.load())
        XCTAssertEqual(try Data(contentsOf: manifestURL), damaged)
        XCTAssertTrue(restored.projects.isEmpty)
    }

    func testFailedSelectionWriteLeavesActiveProjectUnchanged() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CADProjectStore(root: root, legacyConversationID: { nil })
        let project = try store.create()
        let legacy = try XCTUnwrap(store.projects.first)
        let manifestURL = root.appending(path: "projects.json")
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.select(legacy))
        XCTAssertEqual(store.activeProject, project)
    }

    func testMigrationFailureCanRetryWithoutCommittingAnUnrelatedConversation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        enum Locked: Error { case keychain }
        var locked = true
        let conversation = UUID().uuidString
        let store = CADProjectStore(root: root, legacyConversationID: {
            if locked { throw Locked.keychain }
            return conversation
        })
        XCTAssertThrowsError(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "projects.json").path))
        locked = false
        try store.load()
        XCTAssertEqual(store.activeProject?.conversationID, conversation)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "NanoCAD-project-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
