import Foundation
import UIKit
import Observation
import CryptoKit

protocol GenerationClient: Sendable {
    func prepare(_ generation: PendingGeneration) async throws
    func localResult(agentID: String, turnID: String) async throws -> (preview: Data, step: Data)?
    func createAgent(requestID: String, inputFiles: [NanocodexInputFile], instructions: String) async throws -> String
    func send(agentID: String, prompt: String, references: [String], revision: String?, requestID: String, turnID: String) async throws -> NanocodexTurnReceipt
    func events(agentID: String, after: String, untilTurnID: String?, receive: @escaping @Sendable (NanocodexEvent) async -> Void) async throws
    func checkpoint(agentID: String, turnID: String, after: Int) async throws -> CADCheckpoint?
    func cancel(agentID: String, turnID: String) async throws
    func artifacts(agentID: String, turnID: String?) async throws -> NanocodexArtifactPage
    func download(agentID: String, artifact: NanocodexArtifact) async throws -> URL
    func downloadFile(agentID: String, path: String, expectedDigest: String?) async throws -> URL
    func close()
}
extension GenerationClient {
    func checkpoint(agentID: String, turnID: String, after: Int) async throws -> CADCheckpoint? { nil }
    func prepare(_ generation: PendingGeneration) async throws {}
    func localResult(agentID: String, turnID: String) async throws -> (preview: Data, step: Data)? { nil }
}
extension NanocodexClient: GenerationClient {}

struct PendingGeneration: Codable, Sendable {
    struct File: Codable, Sendable { var path: String; var data: Data }
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
    // Missing in old checkpoints: keep their admitted native-tool transport.
    var transport: String? = "cloud"
}

@MainActor @Observable
final class GenerationController {
    var credentials: NanocodexCredentials?
    var busy = false
    var status = ""
    var response = ""
    var error: String?
    var pending: PendingGeneration?
    private(set) var livePreview: LiveCADPreview?
    var previewRevision: Int { livePreview?.revision ?? 0 }
    var onResult: ((Data, Data) throws -> Void)?
    private var history = GenerationTranscript()
    private var transcriptLoadError: String?
    var transcript: [GenerationTranscriptEntry] { history.entries }
    var transcriptNotice: String? { transcriptLoadError ?? history.notice }
    var statusSummary: String {
        guard busy, error == nil, let pending, pending.phase == "running", pending.stopRequested != true,
              status != "A model tool reported a problem" else { return status }
        return history.latestCommentary(for: pending.turnID) ?? status
    }
    private var work: Task<Void, Never>?
    private var observationPaused = false
    private var resumeAfterObservation = false
    private let makeClient: (NanocodexCredentials) -> any GenerationClient
    private let root: URL
    var connected: Bool { credentials != nil }
    var readyForCAD: Bool {
        guard let credentials else { return false }
        guard let grant = credentials.connect else { return true }
        return grant.sandboxExecution == true && grant.expiresAt > Date().timeIntervalSince1970
    }
    var canResume: Bool { pending != nil && !busy }
    private var observationPausedStatus: String {
        pending?.transport == "cloud" ? "Progress disconnected · Tap to reconnect" : "Generation paused · Tap to resume"
    }

    init(root: URL? = nil, loadCredentials: () throws -> NanocodexCredentials? = { try ConnectionCredentials.load() },
         makeClient: @escaping (NanocodexCredentials) -> any GenerationClient = { credentials in
             if credentials.connect != nil { return DurableConnectCADClient(credentials: credentials) }
             return NanocodexClient(credentials: credentials)
         }) {
        self.root = root ?? URL.documentsDirectory.appending(path: "NanoCAD", directoryHint: .isDirectory)
        self.makeClient = makeClient
        do { credentials = try loadCredentials() } catch { self.error = error.localizedDescription }
        let transcriptURL = self.root.appending(path: "transcript.json")
        if FileManager.default.fileExists(atPath: transcriptURL.path) {
            do {
                let size = try transcriptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= GenerationTranscript.maximumFileBytes else {
                    throw NanocodexError.publication("The saved transcript exceeds the 24 MB loading limit and has not been loaded or replaced.")
                }
                history = try JSONDecoder().decode(GenerationTranscript.self, from: Data(contentsOf: transcriptURL))
                if let turn = history.entries.last?.turnID { response = history.assistantResponse(for: turn) }
            } catch {
                transcriptLoadError = "The saved transcript could not be restored. " + error.localizedDescription
                self.error = transcriptLoadError
            }
        }
        let url = self.root.appending(path: "generation.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                pending = try JSONDecoder().decode(PendingGeneration.self, from: Data(contentsOf: url))
                if let pending {
                    let recorded = history.assistantResponse(for: pending.turnID)
                    response = recorded.isEmpty ? pending.response : recorded
                    history.recordUser(safeTranscriptText(pending.prompt), turnID: pending.turnID)
                    if history.cursor(for: pending.turnID) == "0", pending.cursor != "0" {
                        history.recordStatus("This run began before transcript recording was available. Earlier messages may be unavailable.", turnID: pending.turnID)
                        if !pending.response.isEmpty { history.recordStatus(pending.response, turnID: pending.turnID) }
                    }
                }
                if let pending, pending.phase != "failed", pending.transport == "cloud",
                   let data = try? Data(contentsOf: self.root.appending(path: "checkpoint.json")), data.count <= 2_800_000,
                   let checkpoint = try? JSONDecoder().decode(CADCheckpoint.self, from: data) {
                    livePreview = try? checkpoint.validated(for: pending.turnID)
                }
                status = pending?.stopRequested == true ? "Stop unconfirmed · Tap to retry" : pending?.phase == "failed" ? "Generation failed" : observationPausedStatus
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
            files += try CADAgentProfile.inputs()
            if let step { files.append(.init(path: "/brain/input/model.step", data: step)) }
            if let markup { files.append(.init(path: "/brain/input/markup.jpg", data: markup)) }
            // The cloud input is named model.step; cadgen resolves refs by that filename.
            var inputDocument = document
            inputDocument?.name = "model.step"
            let references = inputDocument?.promptReferences(selectedReferences) ?? []
            let revision = step.map(Self.digest)
            let instructions = """
            NanoCAD ships its real STEP-to-preview exporter at /brain/tools/export_step.py. Use it; do not synthesize preview JSON. Mount provider cf_sandbox. Reuse its /opt/nanocad/venv interpreter when compatible; otherwise use preinstalled uv to install Python 3.12 and cadgen[snapshot]==0.6.6 in a container-local /opt/nanocad environment (avoid putting dependencies on the /brain or /workspace FUSE mount), and run python /brain/tools/export_step.py /brain/outputs/model.step --out /brain/outputs/model.cad.json. The native hand can access /brain. If its namespace cannot, transfer only these task inputs using available file tools. Use build123d for real CAD modeling, then export the saved STEP before the preview. The exporter uses cadgen's exact topology references.
            \(step != nil ? "The current document is /brain/input/model.step. Any selected reference filename refers to those exact bytes, originally named \(document?.name ?? "imported.step"). Its exact SHA-256 revision is \(revision ?? ""). Verify it before resolving model.step references with cadgen.read_scene. Preserve dimensions not requested to change." : "Create a new CAD model from the user's brief; use millimeters and record any dimensional assumptions.")
            \(markup != nil ? "An annotated viewport image is at /brain/input/markup.jpg. Open it with view_image and use its marks as visual context for the user's request." : "")
            \(importing ? "This is an import for viewing: preserve the original STEP bytes by copying /brain/input/model.step to /brain/outputs/model.step; export only the preview. Do not modify the geometry." : "Check the resulting saved STEP is valid with positive volume where a solid was requested. Export the final STEP and JSON only when checks pass.")
            Write a concise completion explaining the actual model change and dimensions. Both output files must exist at the specified paths.
            \(CADAgentProfile.instructions)
            """
            pending = PendingGeneration(prompt: prompt, references: references, revision: revision, files: files, instructions: instructions, origin: credentials?.origin)
            if let pending { history.recordUser(safeTranscriptText(prompt), turnID: pending.turnID) }
            try persist()
            response = ""
            resume()
        } catch { self.error = error.localizedDescription }
    }
    var selectedReferences: Set<String> = []

    /// Leaving the foreground only disconnects this observer. Stop is the sole
    /// action that requests durable server cancellation.
    func pauseObservation() {
        observationPaused = true
        resumeAfterObservation = false
        work?.cancel()
    }

    func resumeWhenForeground() {
        observationPaused = false
        guard let pending, pending.phase != "failed" || pending.stopRequested == true else { return }
        if busy {
            // A foreground transition can arrive before the cancelled observer's
            // defer runs. Join it, then consume this one resume request.
            if work?.isCancelled == true { resumeAfterObservation = true }
            return
        }
        resume()
    }

    func resume() {
        guard !busy, let saved = pending, let credentials else { return }
        guard saved.phase != "failed" || saved.stopRequested == true else { return }
        guard saved.origin == nil || saved.origin == credentials.origin else {
            error = "Reconnect to the original Nanocodex server to resume this generation."; return
        }
        // Retry a failed disk checkpoint before making another remote request.
        history.recordUser(safeTranscriptText(saved.prompt), turnID: saved.turnID)
        do { try persist() } catch { self.error = error.localizedDescription; return }
        resumeAfterObservation = false
        busy = true; error = nil
        let client = makeClient(credentials)
        let stopping = saved.stopRequested == true
        work = Task {
            let keepsNativeToolsAvailable = credentials.connect != nil && saved.transport != "cloud"
            let previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
            if keepsNativeToolsAvailable { UIApplication.shared.isIdleTimerDisabled = true }
            defer {
                if keepsNativeToolsAvailable { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting }
                busy = false; client.close(); work = nil
                // Stop joins the cancelled observer before using a new client. Its
                // persisted intent survives relaunch and never resubmits the turn.
                if !stopping && pending?.stopRequested == true { resume() }
                else if resumeAfterObservation && !observationPaused {
                    resumeAfterObservation = false
                    resume()
                }
            }
            do {
                try Task.checkCancellation()
                guard var current = pending else { return }
                if current.agentID == nil {
                    status = stopping ? "Reconciling workspace before stopping…"
                        : credentials.connect != nil && current.transport == "cloud" ? "Uploading your model…" : "Preparing CAD workspace…"
                }
                try await client.prepare(current)
                try Task.checkCancellation()
                if current.agentID == nil {
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
                    history.recordStatus("Stopped", turnID: current.turnID)
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
                    status = "Working on your model…"
                    let previewTask = Task { [weak self] in
                        await self?.observePreviews(client: client, agentID: agentID, turnID: current.turnID)
                    }
                    defer { previewTask.cancel() }
                    try await client.events(agentID: agentID, after: current.cursor, untilTurnID: current.turnID) { [weak self] event in
                        await self?.receive(event)
                    }
                    previewTask.cancel()
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
                history.recordStatus("Model ready", turnID: current.turnID)
                try clearPending()
                status = "Model ready"
            } catch {
                if case NanocodexError.missingCADOutput = error {
                    pending?.phase = "failed"
                    livePreview = nil
                    try? persist()
                }
                if Task.isCancelled || error is CancellationError {
                    status = pending?.stopRequested == true ? "Stopping…" : observationPausedStatus
                } else {
                    self.error = error.localizedDescription
                    if let pending {
                        history.recordStatus(safeTranscriptText(error.localizedDescription), turnID: pending.turnID, error: true)
                        try? persist()
                    }
                    status = stopping ? "Stop unconfirmed · Tap to retry" : pending?.phase == "failed" ? "Generation failed" : "Needs attention · Tap to resume"
                }
            }
        }
    }

    private func observePreviews(client: any GenerationClient, agentID: String, turnID: String) async {
        guard pending?.transport == "cloud" else { return }
        while !Task.isCancelled, pending?.turnID == turnID, pending?.phase == "running", pending?.stopRequested != true {
            do {
                if let checkpoint = try await client.checkpoint(agentID: agentID, turnID: turnID, after: previewRevision) {
                    try Task.checkCancellation()
                    guard pending?.turnID == turnID, pending?.phase == "running", pending?.stopRequested != true else { return }
                    if checkpoint.revision <= previewRevision {
                        try await Task.sleep(for: .seconds(2)); continue
                    }
                    let verified = try checkpoint.validated(for: turnID)
                    try JSONEncoder().encode(checkpoint).write(to: root.appending(path: "checkpoint.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    livePreview = verified
                }
                try await Task.sleep(for: .seconds(2))
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                // A preview is optional. A transient/torn checkpoint never ends the turn.
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func receive(_ event: NanocodexEvent) {
        guard var current = pending, current.stopRequested != true,
              GenerationTranscript.isNewer(event.cursor, than: current.cursor) else { return }
        current.cursor = event.cursor
        var safeEvent = event
        // The parser removes known secret fields; also mask this connection's exact credentials.
        safeEvent.arguments = event.arguments.map(safeTranscriptText)
        safeEvent.result = event.result.map(safeTranscriptText)
        let accepted = history.receive(safeEvent.withText(safeTranscriptText(event.text)), for: current.turnID)
        if accepted || event.isTerminal, event.turnID == current.turnID {
            switch event.type {
            case "assistant.delta", "assistant.message": response = history.assistantResponse(for: current.turnID)
            case "tool.call": status = GenerationProgress.summary(toolName: event.toolName, arguments: safeEvent.arguments)
            case "tool.result":
                if event.toolFailed { status = "A model tool reported a problem" }
            case "turn_completed":
                response = history.assistantResponse(for: current.turnID)
                current.phase = "downloading"
            case "turn_failed", "turn_cancelled":
                response = event.text.isEmpty ? "The generation was stopped or failed." : safeTranscriptText(event.text)
                current.phase = "failed"
                livePreview = nil
            default: break
            }
        }
        current.response = response; pending = current
        do { try persist() } catch { self.error = error.localizedDescription }
    }

    private func safeTranscriptText(_ text: String) -> String {
        var result = text
        for secret in [credentials?.apiKey, credentials?.connect?.token].compactMap({ $0 }) where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[Redacted]")
        }
        return TranscriptRedaction.text(result)
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

    func retryFailedRun() {
        guard let previous = pending, previous.phase == "failed", !busy else { return }
        let next = PendingGeneration(prompt: previous.prompt, references: previous.references,
            revision: previous.revision, files: previous.files, instructions: previous.instructions,
            origin: credentials?.origin)
        pending = next
        history.recordUser(safeTranscriptText(next.prompt), turnID: next.turnID)
        do { try persist() } catch { pending = previous; self.error = error.localizedDescription; return }
        response = ""; resume()
    }

    func forgetFailedRun() {
        guard pending?.phase == "failed", !busy else { return }
        do { try clearPending(); status = "" } catch { self.error = error.localizedDescription }
    }

    private func downloadResult(client: any GenerationClient, agentID: String, turnID: String) async throws -> (Data, Data) {
        if let local = try await client.localResult(agentID: agentID, turnID: turnID) { return (local.preview, local.step) }
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
            } else { throw NanocodexError.missingCADOutput }
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
        try persistTranscript()
        let url = root.appending(path: "generation.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        pending = nil
        livePreview = nil
        try? FileManager.default.removeItem(at: root.appending(path: "checkpoint.json"))
    }
    private func persistTranscript() throws {
        // Never replace an unreadable transcript with a fresh, misleadingly complete history.
        if let transcriptLoadError { throw NanocodexError.publication(transcriptLoadError) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(history).write(to: root.appending(path: "transcript.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func persist() throws {
        // Write visible history before advancing the pending cursor. A crash between the two
        // checkpoints replays safely through the transcript's own per-turn cursor.
        try persistTranscript()
        let url = root.appending(path: "generation.json")
        if let pending { try JSONEncoder().encode(pending).write(to: url, options: .atomic) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
