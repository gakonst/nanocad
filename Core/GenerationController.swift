import Foundation
import Observation
import CryptoKit

protocol GenerationClient: Sendable {
    func createAgent(requestID: String, inputFiles: [NanocodexInputFile], instructions: String) async throws -> String
    func send(agentID: String, prompt: String, references: [String], revision: String?, requestID: String, turnID: String) async throws -> NanocodexTurnReceipt
    func events(agentID: String, after: String, untilTurnID: String?, receive: @escaping @Sendable (NanocodexEvent) async -> Void) async throws
    func cancel(agentID: String, turnID: String) async throws
    func artifacts(agentID: String, turnID: String?) async throws -> NanocodexArtifactPage
    func download(agentID: String, artifact: NanocodexArtifact) async throws -> URL
    func downloadFile(agentID: String, path: String, expectedDigest: String?) async throws -> URL
    func close()
}
extension NanocodexClient: GenerationClient {}

struct PendingGeneration: Codable {
    struct File: Codable { var path: String; var data: Data }
    var creationID = UUID().uuidString
    var requestID = UUID().uuidString
    var turnID = UUID().uuidString
    var agentID: String?
    var prompt: String
    var references: [String]
    var revision: String?
    var files: [File]
    var instructions: String
    var cursor = "0"
    var phase = "creating"
    var response = ""
    var stopRequested: Bool?
    var origin: String?
}

@MainActor @Observable
final class GenerationController {
    var credentials: NanocodexCredentials?
    var busy = false
    var status = ""
    var response = ""
    var error: String?
    var pending: PendingGeneration?
    var onResult: ((Data, Data) throws -> Void)?
    private var work: Task<Void, Never>?
    private let makeClient: (NanocodexCredentials) -> any GenerationClient
    private let root: URL
    var connected: Bool { credentials != nil }
    var canResume: Bool { pending != nil && !busy }

    init(root: URL? = nil, loadCredentials: () throws -> NanocodexCredentials? = ConnectionCredentials.load,
         makeClient: @escaping (NanocodexCredentials) -> any GenerationClient = { NanocodexClient(credentials: $0) }) {
        self.root = root ?? URL.documentsDirectory.appending(path: "NanoCAD", directoryHint: .isDirectory)
        self.makeClient = makeClient
        do { credentials = try loadCredentials() } catch { self.error = error.localizedDescription }
        let url = self.root.appending(path: "generation.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                pending = try JSONDecoder().decode(PendingGeneration.self, from: Data(contentsOf: url))
                response = pending?.response ?? ""
                status = pending?.stopRequested == true ? "Stop unconfirmed · Tap to retry" : pending?.phase == "failed" ? "Generation failed" : "Generation paused · Tap to resume"
            } catch { self.error = "The saved generation could not be restored." }
        }
    }

    func start(prompt: String, document: CADDocument?, step: Data?, markup: Data? = nil, importing: Bool = false) {
        guard !busy, pending == nil else { error = "Resume or stop the current generation first."; return }
        guard connected else { error = "Connect Nanocodex to create models with Astra."; return }
        do {
            if let document {
                guard let step else { throw NanocodexError.publication("Reopen the original STEP file to edit this preview.") }
                guard Self.digest(step) == document.revision else { throw NanocodexError.publication("The STEP file does not match the displayed preview. Reopen the original STEP file before editing.") }
            }
            guard let exporter = Bundle.main.url(forResource: "export_step", withExtension: "py") else { throw NanocodexError.publication("The CAD exporter is missing from this build.") }
            var files = [PendingGeneration.File(path: "/brain/tools/export_step.py", data: try Data(contentsOf: exporter))]
            if let step { files.append(.init(path: "/brain/input/model.step", data: step)) }
            if let markup { files.append(.init(path: "/brain/input/markup.jpg", data: markup)) }
            // The cloud input is named model.step; cadgen resolves refs by that filename.
            var inputDocument = document
            inputDocument?.name = "model.step"
            let references = inputDocument?.promptReferences(selectedReferences) ?? []
            let revision = step.map(Self.digest)
            let instructions = """
            NanoCAD ships its real STEP-to-preview exporter at /brain/tools/export_step.py. Use it; do not synthesize preview JSON. Mount a native hand, create a venv there, install cadgen==0.6.6, and run python /brain/tools/export_step.py /brain/outputs/model.step --out /brain/outputs/model.cad.json. The native hand can access /brain. If its namespace cannot, transfer only these task inputs using available file tools. Use build123d for real CAD modeling, then export the saved STEP before the preview. The exporter uses cadgen's exact topology references.
            \(step != nil ? "The current document is /brain/input/model.step. Any selected reference filename refers to those exact bytes, originally named \(document?.name ?? "imported.step"). Its exact SHA-256 revision is \(revision ?? ""). Verify it before resolving model.step references with cadgen.read_scene. Preserve dimensions not requested to change." : "Create a new CAD model from the user's brief; use millimeters and record any dimensional assumptions.")
            \(markup != nil ? "An annotated viewport image is at /brain/input/markup.jpg. Open it with view_image and use its marks as visual context for the user's request." : "")
            \(importing ? "This is an import for viewing: preserve the original STEP bytes by copying /brain/input/model.step to /brain/outputs/model.step; export only the preview. Do not modify the geometry." : "Check the resulting saved STEP is valid with positive volume where a solid was requested. Export the final STEP and JSON only when checks pass.")
            Write a concise completion explaining the actual model change and dimensions. Both output files must exist at the specified paths.
            """
            pending = PendingGeneration(prompt: prompt, references: references, revision: revision, files: files, instructions: instructions, origin: credentials?.origin)
            try persist()
            response = ""
            resume()
        } catch { self.error = error.localizedDescription }
    }
    var selectedReferences: Set<String> = []

    func resume() {
        guard !busy, let saved = pending, let credentials else { return }
        guard saved.phase != "failed" || saved.stopRequested == true else { return }
        guard saved.origin == nil || saved.origin == credentials.origin else {
            error = "Reconnect to the original Nanocodex server to resume this generation."; return
        }
        // Retry a failed disk checkpoint before making another remote request.
        do { try persist() } catch { self.error = error.localizedDescription; return }
        busy = true; error = nil
        let client = makeClient(credentials)
        let stopping = saved.stopRequested == true
        work = Task {
            defer {
                busy = false; client.close(); work = nil
                // Stop joins the cancelled observer before using a new client. Its
                // persisted intent survives relaunch and never resubmits the turn.
                if !stopping && pending?.stopRequested == true { resume() }
            }
            do {
                guard var current = pending else { return }
                if current.agentID == nil {
                    status = stopping ? "Reconciling workspace before stopping…" : "Preparing CAD workspace…"
                    let agent = try await client.createAgent(requestID: current.creationID, inputFiles: current.files.map { .init(path: $0.path, data: $0.data) }, instructions: current.instructions)
                    current.agentID = agent; current.phase = "sending"
                    current.stopRequested = pending?.stopRequested
                    pending = current; try persist()
                }
                try Task.checkCancellation()
                guard let agentID = current.agentID else { throw NanocodexError.invalidResponse }
                if stopping {
                    status = "Stopping…"
                    // The HTTP API reserves cancellation even before admission.
                    if current.phase == "running" || current.phase == "sending" {
                        try await client.cancel(agentID: agentID, turnID: current.turnID)
                    }
                    try clearPending(); status = "Stopped"; return
                }
                if current.phase == "sending" {
                    status = "Sending to Astra…"
                    _ = try await client.send(agentID: agentID, prompt: current.prompt, references: current.references, revision: current.revision, requestID: current.requestID, turnID: current.turnID)
                    current.phase = "running"; current.stopRequested = pending?.stopRequested
                    pending = current; try persist()
                }
                try Task.checkCancellation()
                if current.phase == "running" {
                    status = "Astra is shaping your idea…"
                    try await client.events(agentID: agentID, after: current.cursor, untilTurnID: current.turnID) { [weak self] event in
                        await self?.receive(event)
                    }
                }
                try Task.checkCancellation()
                guard pending?.phase == "downloading" else {
                    throw NanocodexError.publication(pending?.response.isEmpty == false ? pending!.response : "The generation ended without a completed model.")
                }
                status = "Opening your model…"
                let (preview, step) = try await downloadResult(client: client, agentID: agentID, turnID: current.turnID)
                try Task.checkCancellation()
                let doc = try CADDocument.decode(preview)
                guard doc.revision == Self.digest(step), doc.name == "model.step" else { throw NanocodexError.integrityFailure }
                guard let onResult else { throw NanocodexError.publication("The workspace is not ready to open this model. Resume to try again.") }
                try onResult(preview, step)
                try clearPending()
                status = "Model ready"
            } catch {
                if Task.isCancelled || error is CancellationError {
                    status = pending?.stopRequested == true ? "Stopping…" : "Generation paused · Tap to resume"
                } else {
                    self.error = error.localizedDescription
                    status = stopping ? "Stop unconfirmed · Tap to retry" : pending?.phase == "failed" ? "Generation failed" : "Needs attention · Tap to resume"
                }
            }
        }
    }

    private func receive(_ event: NanocodexEvent) {
        guard var current = pending, current.stopRequested != true else { return }
        current.cursor = event.cursor
        if event.turnID == current.turnID {
            switch event.type {
            case "assistant.delta": response += event.text
            case "assistant.message": if !event.text.isEmpty { response = event.text }
            case "tool.call": status = "Astra · " + (event.toolName ?? "Working on geometry")
            case "turn_completed":
                if !event.text.isEmpty { response = event.text }
                current.phase = "downloading"
            case "turn_failed", "turn_cancelled":
                response = event.text.isEmpty ? "The generation was stopped or failed." : event.text
                current.phase = "failed"
            default: break
            }
        }
        current.response = response; pending = current
        do { try persist() } catch { self.error = error.localizedDescription }
    }

    func stop() {
        guard var current = pending, current.stopRequested != true else { return }
        let previous = current
        current.stopRequested = true
        pending = current
        do { try persist() } catch { pending = previous; self.error = error.localizedDescription; return }
        status = "Stopping…"
        if busy { work?.cancel() }
        else { resume() }
    }

    func forgetFailedRun() {
        guard pending?.phase == "failed", !busy else { return }
        do { try clearPending(); status = "" } catch { self.error = error.localizedDescription }
    }

    private func downloadResult(client: any GenerationClient, agentID: String, turnID: String) async throws -> (Data, Data) {
        let page = try await client.artifacts(agentID: agentID, turnID: turnID)
        let publication = page.publications.first { $0.turnID == turnID }
        guard let publication, ["ready", "failed"].contains(publication.state) else {
            throw NanocodexError.publication("The completed model has no publication receipt. Resume to check again.")
        }
        func fetch(_ suffix: String) async throws -> Data {
            let path = "/brain/outputs/model." + suffix
            let artifact = page.data.first { $0.turnID == turnID && $0.path == path }
            let url: URL
            if let artifact { url = try await client.download(agentID: agentID, artifact: artifact) }
            else if publication.state == "failed" {
                // Oversized exports use the account-only live file endpoint. The
                // dedicated agent has one turn, and the pair is checked below.
                url = try await client.downloadFile(agentID: agentID, path: path, expectedDigest: nil)
            } else { throw NanocodexError.publication("Astra did not publish both model.step and model.cad.json. The current document is unchanged.") }
            defer { try? FileManager.default.removeItem(at: url) }
            return try Data(contentsOf: url)
        }
        async let preview = fetch("cad.json")
        async let step = fetch("step")
        return try await (preview, step)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func clearPending() throws {
        let url = root.appending(path: "generation.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        pending = nil
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "generation.json")
        if let pending { try JSONEncoder().encode(pending).write(to: url, options: .atomic) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
