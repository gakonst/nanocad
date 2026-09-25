import Foundation
import Observation
import UIKit

/// Opt-in, physical-device validation of the same native Connect client used by NanoCAD.
/// Launch with exactly one of --validate-connect-transfer or --validate-connect-cad.
/// No flag means no validation work, credential access, recovery, or server cancellation.
///
/// Every launch gets an isolated Documents/NanoCAD/Validation/<runUUID>/ directory,
/// plus Validation/latest-report.json. Operation IDs and cancellation intent are saved
/// before admission/cancellation. Reports contain fixture metadata, bounded redacted
/// status text, and native artifact metrics; never credentials or raw tool arguments.
/// The Keychain grant is loaded and used only inside the app. A previous uncertain
/// validation or active saved user generation blocks admission of another turn.
///
/// Transfer mode sends a public exporter padded past two chunk boundaries. Astra must
/// actually read, assemble, and hash it, and return a machine-readable attestation.
/// CAD mode requests a 40 × 30 × 8 mm plate with a centered Ø6 mm through hole. Native
/// onResult validates CADDocument, STEP identity/hash, preview bounds, and hole edges,
/// and saves both received artifacts. This is live integration evidence, not a mock
/// transport test; a model attestation alone does not prove server-side CAD validity.
/// Root-owned Connect diagnostics supply independent reverse-tool transport evidence.
///
/// A 15-minute deadline cancels observation AND explicitly cancels durable server work.
/// Process termination cannot execute cancellation: its saved IDs remain marked for
/// reconciliation and prevent a later flagged launch from silently starting a new turn.
@MainActor @Observable
final class ConnectValidationRunner {
    enum Mode: String, Codable, Sendable {
        case transfer, cad
        static var requested: Mode? {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--validate-connect-transfer") { return .transfer }
            if arguments.contains("--validate-connect-cad") { return .cad }
            return nil
        }
    }

    struct FileEvidence: Codable, Sendable {
        var name: String
        var bytes: Int
        var sha256: String
    }
    struct TransferAttestation: Codable, Sendable {
        struct File: Codable, Sendable {
            var file: String
            var total_size: Int
            var sha256: String
            var reassembled_sha256: String
            var chunk_offsets: [Int]
            var verified: Bool
        }
        var validation: String
        var generation_id: String
        var read_tool: String
        var files: [File]
    }
    struct CADMetrics: Codable, Sendable {
        var onResultInvocations: Int
        var documentName: String
        var revision: String
        var units: String
        var faces: Int
        var edges: Int
        var vertices: Int
        var parts: Int
        var triangles: Int
        var minimumMM: [Double]
        var maximumMM: [Double]
        var dimensionsMM: [Double]
        var matchingHoleBoundaryEdges: Int
        var nativeDecodeValidated: Bool
        var stepDigestMatchesPreview: Bool
    }
    struct Report: Codable, Sendable {
        var schemaVersion = 1
        var runID: String
        var mode: Mode
        var startedAt = Date()
        var finishedAt: Date?
        var requestedModel = "gpt-6-astra"
        var state = "preparing"
        var stage = "checkpoint"
        var creationID: String
        var requestID: String
        var turnID: String
        var agentID: String?
        var cursor = "0"
        var admissionAttempted = false
        var receiptVerified = false
        var terminalEvent: String?
        var cancellation = "not_requested"
        var cancellationReason: String?
        var eventCounts: [String: Int] = [:]
        var toolNames: [String] = []
        var inputs: [FileEvidence] = []
        var outputs: [FileEvidence] = []
        var transferAttestation: TransferAttestation?
        var nativeReadReceipts: [ConnectFileTransfer.ReadReceipt] = []
        var cad: CADMetrics?
        var statusText: String?
        var failures: [String] = []
        var streamReconnects = 0
        var requiresReconciliation: Bool {
            admissionAttempted && terminalEvent == nil && cancellation != "confirmed"
        }
    }

    private(set) var document: CADDocument?
    private(set) var status = "Waiting to validate Connect"
    private(set) var report: Report?
    private(set) var running = false
    private(set) var reportWriteFailed = false
    private var started = false
    private var work: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var client: (any GenerationClient)?
    private var runRoot: URL?
    private var response = ""
    private var eventCheckpointError: String?
    private var stopReason: String?
    private let validationRoot = URL.documentsDirectory.appending(path: "NanoCAD/Validation", directoryHint: .isDirectory)

    /// Called only by the validation-only launch view. Repeated SwiftUI tasks/scenes
    /// cannot admit another turn in the same process.
    func runOnce(mode: Mode) async {
        guard !started else { return }
        started = true
        running = true
        let priorIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = priorIdleTimerSetting }
        work = Task { await perform(mode: mode) }
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            self?.stop(reason: "timeout")
        }
        await withTaskCancellationHandler {
            await work?.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop(reason: "validation_task_cancelled") }
        }
        watchdog?.cancel()
        watchdog = nil
        work = nil
        running = false
    }

    func stop(reason: String = "user_cancelled") {
        guard running, stopReason == nil, report?.finishedAt == nil else { return }
        stopReason = reason
        report?.cancellationReason = reason
        report?.cancellation = "requested"
        status = "Cancelling validation…"
        // A failed disk write must never prevent an explicit server stop.
        persistBestEffort()
        work?.cancel()
    }

    private func perform(mode: Mode) async {
        defer { client?.close(); client = nil }
        do {
            let previous = try previousReport()
            // Preserve the prior latest report until it has a known terminal state.
            // Replacing it with a new blocked report would lose the admission lock.
            if let previous, previous.requiresReconciliation {
                throw ValidationError.failed("Previous validation turn \(previous.turnID) has an uncertain server outcome; reconcile its saved report before starting another run.")
            }
            let runID = UUID().uuidString
            runRoot = validationRoot.appending(path: runID, directoryHint: .isDirectory)
            let generationID = UUID().uuidString, requestID = UUID().uuidString, turnID = UUID().uuidString
            report = Report(runID: runID, mode: mode, creationID: generationID, requestID: requestID, turnID: turnID)
            try checkpoint(stage: "preflight", status: "Checking isolated validation run…")
            guard !(ProcessInfo.processInfo.arguments.contains("--validate-connect-transfer") &&
                    ProcessInfo.processInfo.arguments.contains("--validate-connect-cad")) else {
                throw ValidationError.failed("Use exactly one validation launch flag.")
            }
            try ensureUserTurnIsTerminal()
            try Task.checkCancellation()
            guard let credentials = try ConnectionCredentials.load(), let grant = credentials.connect else {
                throw ValidationError.failed("Connect validation requires the existing device Keychain Connect grant.")
            }
            guard let root = runRoot, let exporterURL = Bundle.main.url(forResource: "export_step", withExtension: "py") else {
                throw ValidationError.failed("The bundled CAD exporter is missing.")
            }
            var exporter = try Data(contentsOf: exporterURL)
            if mode == .transfer {
                // Public comments preserve a valid Python exporter while exercising
                // offsets 0, 32768, and 65536, including a non-full final chunk.
                for index in 0..<900 {
                    exporter.append(contentsOf: "\n# NanoCAD public transfer fixture \(runID) row \(index)".utf8)
                }
                exporter.append(10)
            }
            report?.inputs = [.init(name: "export_step.py", bytes: exporter.count, sha256: ConnectFileTransfer.digest(exporter))]
            report?.agentID = grant.agentID
            let generation = PendingGeneration(creationID: generationID, requestID: requestID, turnID: turnID,
                prompt: mode == .transfer ? transferPrompt(generationID: generationID) : Self.cadPrompt,
                references: [], revision: nil,
                files: [.init(path: "/brain/tools/export_step.py", data: exporter)],
                instructions: mode == .transfer ? Self.transferInstructions : Self.cadInstructions)
            try JSONEncoder().encode(generation).write(to: root.appending(path: "generation.json"), options: .atomic)
            // The optional root preserves production defaults while containing all
            // validation manifests, input bytes and output chunks in this run.
            let connection = ConnectCADClient(credentials: credentials, requiresNativeExecution: mode == .cad,
                                              transferRoot: root.appending(path: "transfer", directoryHint: .isDirectory))
            client = connection
            try checkpoint(stage: "prepare", status: "Connecting native tools and selecting Astra…")
            try await connection.prepare(generation)
            try Task.checkCancellation()
            try checkpoint(stage: "createAgent", status: "Preparing granted conversation…")
            let agentID = try await connection.createAgent(requestID: generation.creationID,
                inputFiles: generation.files.map { .init(path: $0.path, data: $0.data) }, instructions: generation.instructions)
            guard agentID == grant.agentID else { throw NanocodexError.invalidReference }
            try Task.checkCancellation()
            report?.admissionAttempted = true
            try checkpoint(stage: "send", status: "Sending validation request to Astra…")
            let receipt = try await connection.send(agentID: agentID, prompt: generation.prompt, references: [], revision: nil,
                                                    requestID: requestID, turnID: turnID)
            guard receipt.agentID == agentID, receipt.turnID == turnID, receipt.requestID == requestID else {
                throw NanocodexError.invalidResponse
            }
            report?.receiptVerified = true
            try checkpoint(stage: "events", status: "Astra is running \(mode.rawValue) validation…")
            try await observe(connection, agentID: agentID, turnID: turnID)
            try Task.checkCancellation()
            guard report?.terminalEvent == "turn_completed" else {
                throw ValidationError.failed("Validation ended with \(report?.terminalEvent ?? "no terminal event"): \(Self.safeText(response))")
            }
            report?.nativeReadReceipts = await connection.transferReadReceipts()
            if mode == .transfer {
                try checkpoint(stage: "verifyTransfer", status: "Checking Astra’s transfer attestation…")
                let attestation = try validateTransferResponse(response, generationID: generationID, bytes: exporter)
                report?.transferAttestation = attestation
            } else {
                try verifyNativeInputCoverage(exporter)
                try checkpoint(stage: "localResult", status: "Opening delivered STEP and preview…")
                guard let result = try await connection.localResult(agentID: agentID, turnID: turnID) else {
                    throw ValidationError.failed("The native client returned no local CAD artifacts.")
                }
                try Task.checkCancellation()
                try checkpoint(stage: "onResult", status: "Validating native CAD geometry and STEP hash…")
                try onResult(preview: result.preview, step: result.step, root: root)
            }
            report?.state = "passed"
            report?.finishedAt = Date()
            try checkpoint(stage: "complete", status: mode == .transfer ? "Transfer validation passed" : "STEP hash and native preview validated")
        } catch {
            let cancelled = Task.isCancelled || stopReason != nil || error is CancellationError
            report?.failures.append(eventCheckpointError ?? Self.safeError(error))
            if let connection = client as? ConnectCADClient {
                report?.nativeReadReceipts = await connection.transferReadReceipts()
            }
            // A stream/send failure can leave durable execution running. Explicitly
            // stop that exact saved turn; never retry admission with another ID.
            if report?.terminalEvent == nil, report?.agentID != nil, client != nil {
                await cancelServer(reason: stopReason ?? "validation_failed")
            }
            report?.state = cancelled ? (stopReason == "timeout" ? "timed_out" : "cancelled") : "failed"
            report?.finishedAt = Date()
            status = report?.cancellation == "unconfirmed" ? "Validation stopped · server cancellation unconfirmed" :
                cancelled ? "Validation \(stopReason == "timeout" ? "timed out" : "cancelled")" : "Validation failed · \(Self.safeError(error))"
            persistBestEffort()
        }
    }

    private func observe(_ connection: any GenerationClient, agentID: String, turnID: String) async throws {
        while report?.terminalEvent == nil {
            try Task.checkCancellation()
            do {
                try await connection.events(agentID: agentID, after: report?.cursor ?? "0", untilTurnID: turnID) { [weak self] event in
                    await self?.receive(event)
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if let eventCheckpointError { throw ValidationError.failed(eventCheckpointError) }
                guard Self.canReconnect(error), (report?.streamReconnects ?? 0) < 8 else { throw error }
                report?.streamReconnects += 1
                report?.failures.append("Event stream reconnect: " + Self.safeError(error))
                try checkpoint(stage: "events", status: "Reconnecting to the existing validation turn…")
                try await Task.sleep(for: .seconds(2))
            }
            if let eventCheckpointError { throw ValidationError.failed(eventCheckpointError) }
        }
    }

    private func receive(_ event: NanocodexEvent) {
        guard eventCheckpointError == nil else { return }
        report?.cursor = event.cursor
        if event.turnID == report?.turnID {
            let type = Self.safeText(event.type, limit: 80)
            if report?.eventCounts[type] != nil || (report?.eventCounts.count ?? 0) < 40 {
                report?.eventCounts[type, default: 0] += 1
            }
            if let name = event.toolName {
                let safeName = Self.safeText(name, limit: 160)
                if report?.toolNames.contains(safeName) == false, (report?.toolNames.count ?? 0) < 100 {
                    report?.toolNames.append(safeName)
                }
                status = "Astra · \(safeName)"
            }
            switch event.type {
            case "assistant.delta": response = String((response + event.text).suffix(32_768))
            case "assistant.message": if !event.text.isEmpty { response = String(event.text.prefix(32_768)) }
            case "turn_completed", "turn_failed", "turn_cancelled":
                report?.terminalEvent = event.type
                if !event.text.isEmpty { response = String(event.text.prefix(32_768)) }
                report?.statusText = Self.safeText(response)
            default: break
            }
        }
        do { try persist() } catch {
            eventCheckpointError = "Unable to persist the validation event cursor."
            reportWriteFailed = true
            work?.cancel()
        }
    }

    private func cancelServer(reason: String) async {
        guard cancellationTask == nil, let client, let agentID = report?.agentID, let turnID = report?.turnID else { return }
        report?.cancellation = "requested"
        report?.cancellationReason = reason
        persistBestEffort()
        // An unstructured task is intentional: the observer's cancelled context
        // must not immediately cancel the HTTP request that stops durable work.
        let task = Task { @MainActor in
            do {
                try await client.cancel(agentID: agentID, turnID: turnID)
                self.report?.cancellation = "confirmed"
            } catch {
                self.report?.cancellation = "unconfirmed"
                self.report?.failures.append("Server cancellation: " + Self.safeError(error))
            }
            self.persistBestEffort()
        }
        cancellationTask = task
        await task.value
    }

    private func verifyNativeInputCoverage(_ bytes: Data) throws {
        let digest = ConnectFileTransfer.digest(bytes)
        let receipts = (report?.nativeReadReceipts ?? []).filter { $0.file == "export_step.py" && $0.digest == digest }
        var covered = 0
        for receipt in receipts.sorted(by: { $0.offset < $1.offset }) {
            guard receipt.offset <= covered else { break }
            covered = max(covered, receipt.offset + receipt.count)
        }
        guard covered == bytes.count else {
            throw ValidationError.failed("Native nanocad_read_input receipts do not cover the current CAD exporter input.")
        }
    }

    private func validateTransferResponse(_ text: String, generationID: String, bytes: Data) throws -> TransferAttestation {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), let firstNewline = json.firstIndex(of: "\n"), json.hasSuffix("```") {
            json = String(json[json.index(after: firstNewline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let attestation = try JSONDecoder().decode(TransferAttestation.self, from: Data(json.utf8))
        let offsets = Array(stride(from: 0, to: bytes.count, by: ConnectFileTransfer.chunkSize))
        guard attestation.validation == "nanocad-connect-transfer-v1", attestation.generation_id == generationID,
              attestation.read_tool == "nanocad_read_input", attestation.files.count == 1, let file = attestation.files.first,
              file.file == "export_step.py", file.total_size == bytes.count, file.verified,
              file.sha256 == ConnectFileTransfer.digest(bytes), file.reassembled_sha256 == file.sha256,
              file.chunk_offsets == offsets, offsets.count >= 3 else {
            throw ValidationError.failed("Astra’s input transfer attestation did not match the native fixture’s chunks and SHA-256.")
        }
        let receipts = report?.nativeReadReceipts ?? []
        guard offsets.allSatisfy({ offset in
            receipts.contains { $0.file == "export_step.py" && $0.offset == offset &&
                $0.count == min(ConnectFileTransfer.chunkSize, bytes.count - offset) && $0.digest == file.sha256 }
        }) else {
            throw ValidationError.failed("Native nanocad_read_input receipts do not cover every attested fixture chunk.")
        }
        return attestation
    }

    /// Native artifact delivery boundary: records metrics only after validation and
    /// atomic local writes succeed. This never calls WorkspacePersistence/onResult.
    private func onResult(preview: Data, step: Data, root: URL) throws {
        let document = try CADDocument.decode(preview)
        let digest = ConnectFileTransfer.digest(step)
        guard document.name == "model.step", document.revision == digest,
              String(decoding: step.prefix(256), as: UTF8.self).contains("ISO-10303-21"),
              String(decoding: step.suffix(256), as: UTF8.self).contains("END-ISO-10303-21") else {
            throw NanocodexError.integrityFailure
        }
        var minimum = [Double](repeating: .infinity, count: 3)
        var maximum = [Double](repeating: -.infinity, count: 3)
        for face in document.faces {
            for index in stride(from: 0, to: face.positions.count, by: 3) {
                for axis in 0..<3 {
                    let value = Double(face.positions[index + axis])
                    minimum[axis] = min(minimum[axis], value)
                    maximum[axis] = max(maximum[axis], value)
                }
            }
        }
        let dimensions = zip(maximum, minimum).map { $0 - $1 }
        guard zip(dimensions, [40.0, 30.0, 8.0]).allSatisfy({ abs($0 - $1) < 0.1 }),
              minimum.allSatisfy({ abs($0) < 0.1 }), document.parts.count == 1 else {
            throw ValidationError.failed("Native preview bounds or part count differ from the requested 40 × 30 × 8 mm plate.")
        }
        // The saved preview's circular edge polylines provide an independent native
        // check of two centered Ø6 boundaries, one at each plate surface. Exact
        // BREP volume/validity checks still belong to the server CAD kernel.
        let holeEdges = document.edges.filter { edge in
            guard edge.points.count >= 18, abs(edge.length - 6 * .pi) < 0.2 else { return false }
            let z = Double(edge.points[2])
            guard abs(z) < 0.05 || abs(z - 8) < 0.05 else { return false }
            return stride(from: 0, to: edge.points.count, by: 3).allSatisfy { index in
                let x = Double(edge.points[index]) - 20, y = Double(edge.points[index + 1]) - 15
                return abs(sqrt(x * x + y * y) - 3) < 0.1 && abs(Double(edge.points[index + 2]) - z) < 0.05
            }
        }
        let holeLevels = Set(holeEdges.map { Int(Double($0.points[2]).rounded()) })
        guard holeLevels == Set([0, 8]) else {
            throw ValidationError.failed("Native preview does not contain both centered Ø6 mm hole boundaries.")
        }
        try step.write(to: root.appending(path: "model.step"), options: .atomic)
        try preview.write(to: root.appending(path: "model.cad.json"), options: .atomic)
        report?.outputs = [.init(name: "model.step", bytes: step.count, sha256: digest),
                           .init(name: "model.cad.json", bytes: preview.count, sha256: ConnectFileTransfer.digest(preview))]
        self.document = document
        report?.cad = CADMetrics(onResultInvocations: 1, documentName: document.name, revision: document.revision, units: document.units,
            faces: document.faces.count, edges: document.edges.count, vertices: document.vertices.count, parts: document.parts.count,
            triangles: document.faces.reduce(0) { $0 + $1.indices.count / 3 }, minimumMM: minimum, maximumMM: maximum,
            dimensionsMM: dimensions, matchingHoleBoundaryEdges: holeEdges.count,
            nativeDecodeValidated: true, stepDigestMatchesPreview: true)
    }

    private func ensureUserTurnIsTerminal() throws {
        struct SavedPhase: Decodable { var phase: String; var stopRequested: Bool? }
        let url = URL.documentsDirectory.appending(path: "NanoCAD/generation.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let saved = try JSONDecoder().decode(SavedPhase.self, from: Data(contentsOf: url))
        guard ["failed", "downloading"].contains(saved.phase), saved.stopRequested != true else {
            throw ValidationError.failed("A saved user generation may still be active. Finish or stop it before Connect validation.")
        }
    }
    private func previousReport() throws -> Report? {
        let url = validationRoot.appending(path: "latest-report.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Report.self, from: Data(contentsOf: url))
    }
    private func checkpoint(stage: String, status: String) throws {
        report?.stage = stage
        self.status = status
        try persist()
    }
    private func persist() throws {
        guard let report, let root = runRoot else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(report)
        try bytes.write(to: root.appending(path: "report.json"), options: .atomic)
        try bytes.write(to: validationRoot.appending(path: "latest-report.json"), options: .atomic)
    }
    private func persistBestEffort() {
        do { try persist() } catch { reportWriteFailed = true }
    }
    private static func canReconnect(_ error: any Error) -> Bool {
        if case NanocodexError.streamEnded = error { return true }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(error.code)
        }
        return false
    }
    private static func safeText(_ text: String, limit: Int = 4096) -> String {
        String(text.prefix(limit * 2))
            .replacingOccurrences(of: #"(?i)\bBearer\s+\S+|https?://\S+|[A-Za-z0-9_\-+/=]{32,}"#, with: "[redacted]", options: .regularExpression)
            .prefix(limit).description
    }
    private static func safeError(_ error: any Error) -> String {
        // Foundation decoding/transport diagnostics can include source bytes/URLs.
        if error is DecodingError { return "The validation response or saved metadata could not be decoded." }
        if let value = error as? URLError { return "Network error (\(value.code.rawValue))." }
        if error is CancellationError { return "Validation observation was cancelled." }
        if let value = error as? ValidationError { return safeText(value.localizedDescription) }
        if let value = error as? NanocodexError { return safeText(value.localizedDescription) }
        if let value = error as? CADValidationError { return value.localizedDescription }
        if let value = error as? ConnectToolHost.HostError { return value.localizedDescription }
        return "Validation operation failed (\((error as NSError).code)); see the recorded stage and native transport diagnostics."
    }
    private enum ValidationError: LocalizedError {
        case failed(String)
        var errorDescription: String? { switch self { case .failed(let message): message } }
    }

    private func transferPrompt(generationID: String) -> String {
        """
        Run a native input-transfer diagnostic only. Discover and CALL nanocad_read_input for generation_id \(generationID), file export_step.py.
        Use offset 0 and length 32768, continue at offsets 32768, 65536, etc. until eof. In Code Mode assemble every decoded data_base64 chunk, verify each response's offset/total_size/sha256, then independently compute SHA-256 of the assembled bytes and compare it to the returned whole-file sha256. Do not print base64. Never guess or copy an earlier turn's digest. This fixture is unique to this run.
        Do not model CAD, mount an execution hand, install software, or call nanocad_write_output in this diagnostic. A CAD output pair is not requested in transfer mode.
        Return ONLY the following JSON object with actual measured values and every ordered chunk offset:
        {"validation":"nanocad-connect-transfer-v1","generation_id":"\(generationID)","read_tool":"nanocad_read_input","files":[{"file":"export_step.py","total_size":0,"sha256":"actual whole-file digest","reassembled_sha256":"independently computed digest","chunk_offsets":[0,32768,65536],"verified":true}]}
        If reading or hashing fails, report the failing tool name and concise error; never claim verified true.
        """
    }
    private static let transferInstructions = """
    This turn is an explicitly authorized native Connect input-transfer diagnostic. Its final user request defines the task. The usual CAD generation, exporter execution, and output publication steps are inapplicable to this transfer-only request. Use actual signed native input tools and Code Mode byte/digest operations.
    """
    private static let cadPrompt = """
    Create one solid rectangular plate, exactly 40 mm along X, 30 mm along Y, and 8 mm thick along Z, occupying X=0..40, Y=0..30, Z=0..8. Cut one straight circular Ø6 mm through hole along Z, centered at X=20, Y=15, through the full thickness. No fillets, chamfers, extra parts or marks. Use build123d and true BREP solids. Reopen the saved STEP with the CAD kernel and verify one valid solid, the exact bounds, and volume (40*30 - pi*3*3)*8 cubic mm within numeric tolerance. Use only this turn's delivered exporter bytes, run the exporter on that exact saved STEP, then deliver model.step and model.cad.json to the native app through nanocad_write_output. Finish with the actual dimension and CAD validity/volume checks concisely.
    """
    private static let cadInstructions = """
    NanoCAD provides its actual STEP-to-preview exporter at /brain/tools/export_step.py via nanocad_read_input. Verify and preserve its bytes. Mount provider cf_sandbox. Use its preinstalled uv to install Python 3.12 and cadgen==0.6.6 (which includes build123d) in a container-local /opt/nanocad environment; keep dependency caches in /opt and only task inputs/outputs in /brain. Then create the requested real CAD solid, and save /brain/outputs/model.step. Run python /brain/tools/export_step.py /brain/outputs/model.step --out /brain/outputs/model.cad.json. Never synthesize preview JSON. Use the mounted hand's real working directory for commands; its native tools can access /brain. Validate saved STEP geometry before export, and deliver both exact files through the signed native write tool before completing.
    """
}
