import CryptoKit
import Foundation

/// Inputs are durably uploaded before admission; output artifacts belong to the
/// completed turn. The phone is only an observer after the request is accepted.
actor DurableConnectCADClient: GenerationClient {
    private let credentials: NanocodexCredentials
    private let client: NanocodexClient
    private let session: URLSession
    private var generation: PendingGeneration?
    private var uploaded: [String: InputReceipt] = [:]
    private var legacy: ConnectCADClient?
    private var closed = false

    struct InputReceipt: Decodable, Sendable {
        let path: String
        let sha256: String
        let size: Int
    }

    init(credentials: NanocodexCredentials, configuration: URLSessionConfiguration = .ephemeral) {
        self.credentials = credentials
        client = NanocodexClient(credentials: credentials, configuration: configuration)
        session = URLSession(configuration: configuration, delegate: NoCloudRedirects(), delegateQueue: nil)
    }

    func prepare(_ generation: PendingGeneration) async throws {
        guard !closed, let grant = credentials.connect else { throw NanocodexError.invalidCredential }
        try ConnectConfiguration.validate(grant)
        guard generation.agentID == nil || generation.agentID == grant.agentID else {
            throw NanocodexError.publication("Reconnect this project’s original Nanocodex conversation to continue.")
        }
        self.generation = generation
        // An already admitted old build's request must keep its original protocol
        // and identifiers. Completed results can also recover from cloud artifacts.
        if generation.transport != "cloud", generation.phase != "failed" {
            let old = ConnectCADClient(credentials: credentials)
            legacy = old
            try await old.prepare(generation)
            return
        }
        if generation.stopRequested != true && generation.phase != "downloading" && grant.sandboxExecution != true {
            throw ConnectError.executionApprovalRequired
        }
    }

    func createAgent(requestID: String, inputFiles: [NanocodexInputFile], instructions: String) async throws -> String {
        if let legacy { return try await legacy.createAgent(requestID: requestID, inputFiles: inputFiles, instructions: instructions) }
        guard let generation, generation.creationID == requestID, let grant = credentials.connect else { throw NanocodexError.invalidReference }
        try await client.selectAstra(agentID: grant.agentID)
        try await uploadInputs(inputFiles, generationID: generation.creationID, agentID: grant.agentID)
        return grant.agentID
    }

    private func uploadInputs(_ files: [NanocodexInputFile], generationID: String, agentID: String) async throws {
        guard files.count <= 8 else { throw NanocodexError.inputTooLarge }
        try await withThrowingTaskGroup(of: (String, InputReceipt).self) { group in
            for file in files {
                group.addTask {
                    try Task.checkCancellation()
                    return (file.path, try await self.upload(file, generationID: generationID, agentID: agentID))
                }
            }
            for try await (path, receipt) in group { uploaded[path] = receipt }
        }
    }

    private func upload(_ file: NanocodexInputFile, generationID: String, agentID: String) async throws -> InputReceipt {
        let names = ["/brain/tools/export_step.py": "export_step.py", "/brain/tools/cad-skill.json": "cad-skill.json", "/brain/tools/cad_project.py": "cad_project.py", "/brain/input/model.step": "model.step", "/brain/input/markup.jpg": "markup.jpg"]
        guard let name = names[file.path], UUID(uuidString: generationID) != nil,
              file.data.count <= 600_000 else { throw NanocodexError.inputTooLarge }
        let digest = SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()
        let body = try JSONSerialization.data(withJSONObject: ["data_base64": file.data.base64EncodedString(), "sha256": digest], options: [.sortedKeys])
        let request = try client.request(path: "/v1/agents/\(agentID)/inputs/\(generationID)/\(name)", method: "PUT", body: body)
        let (bytes, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw NanocodexError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw NanocodexError.http(response.statusCode) }
        let receipt = try JSONDecoder().decode(InputReceipt.self, from: bytes)
        guard receipt.sha256 == digest, receipt.size == file.data.count,
              receipt.path.hasPrefix("/brain/"), receipt.path.hasSuffix("/\(generationID)/\(name)"),
              !receipt.path.contains(".."), !receipt.path.contains("\\"),
              receipt.path.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw NanocodexError.integrityFailure }
        return receipt
    }

    func send(agentID: String, prompt: String, references: [String], revision: String?, requestID: String, turnID: String) async throws -> NanocodexTurnReceipt {
        if let legacy { return try await legacy.send(agentID: agentID, prompt: prompt, references: references, revision: revision, requestID: requestID, turnID: turnID) }
        guard let generation, let grant = credentials.connect, agentID == grant.agentID,
              generation.turnID == turnID else { throw NanocodexError.invalidReference }
        // Admission may be retried after the app was killed between upload and
        // receipt persistence. Immutable identical PUTs safely recover receipts.
        if uploaded.count != generation.files.count {
            try await uploadInputs(generation.files.map { .init(path: $0.path, data: $0.data) },
                                   generationID: generation.creationID, agentID: agentID)
        }
        let inputLines = generation.files.compactMap { file -> String? in
            guard let receipt = uploaded[file.path] else { return nil }
            return "\(receipt.path) (\(receipt.size) bytes; SHA-256 \(receipt.sha256)) → \(file.path)"
        }.joined(separator: "\n")
        let outputRoot = "/brain/connect/" + grant.grantID + "/outputs/" + generation.turnID
        let instructions = (NanocodexClient.cadInstructions + "\n" + generation.instructions)
            .replacingOccurrences(of: "/brain/outputs/model.", with: outputRoot + "/model.")
        let context = """
        \(instructions)
        DURABLE PROJECT WORKSPACE
        This request is fully uploaded. Continue working if the phone disconnects. Use the persistent Cloudflare sandbox named cad-\(grant.conversationID.lowercased()) with provider cf_sandbox, reusing its installed /opt/nanocad environment for subsequent edits. Do not use native app file tools: the phone does not need to stay open. Read these exact uploaded inputs from /brain, verify their SHA-256, and copy each to its indicated working path before modeling:
        \(inputLines)
        Save this generation's final pair at \(outputRoot)/model.step and \(outputRoot)/model.cad.json. Only those outputs belong to this request. The platform publishes them as immutable turn artifacts. Both should remain below 1 MB; adjust preview tessellation when needed while preserving STEP geometry. Do not finish until both files are saved and validated. Do not send file contents through app tools or the transcript.
        LIVE MODEL PREVIEWS
        After each meaningful valid modeling step, publish a native preview checkpoint. Run the shipped exporter with --checkpoint-dir \(outputRoot)/checkpoints --checkpoint-revision N, increasing N from 1 for this request. It writes a verified STEP/preview pair and publishes the manifest last. Publish an initial valid shape early and further checkpoints as you add requested features; these are real geometry, not placeholders. Also save the final pair at the exact final paths above. Checkpoints never replace final publication.
        Send a brief plain-language progress update when beginning inspection, modeling, and validation. Explain what is actually happening without tool names or invented progress percentages.
        USER REQUEST:
        \(prompt)
        """
        return try await client.send(agentID: agentID, prompt: context, references: references, revision: revision, requestID: requestID, turnID: turnID)
    }

    func checkpoint(agentID: String, turnID: String, after: Int) async throws -> CADCheckpoint? {
        guard let generation, generation.transport == "cloud", generation.turnID == turnID,
              credentials.connect?.agentID == agentID else { return nil }
        let request = try client.request(path: "/v1/agents/\(agentID)/checkpoints?turn_id=\(turnID)&after=\(max(0, after))")
        let (bytes, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw NanocodexError.invalidResponse }
        if [204, 304, 404].contains(response.statusCode) { return nil }
        guard response.statusCode == 200 else { throw NanocodexError.http(response.statusCode) }
        guard bytes.count <= 2_800_000 else { throw NanocodexError.inputTooLarge }
        let checkpoint = try JSONDecoder().decode(CADCheckpoint.self, from: bytes)
        _ = try checkpoint.validated(for: turnID)
        return checkpoint
    }

    func events(agentID: String, after: String, untilTurnID: String?, receive: @escaping @Sendable (NanocodexEvent) async -> Void) async throws {
        try await client.events(agentID: agentID, after: after, untilTurnID: untilTurnID, receive: receive)
    }
    func cancel(agentID: String, turnID: String) async throws { try await client.cancel(agentID: agentID, turnID: turnID) }
    func localResult(agentID: String, turnID: String) async throws -> (preview: Data, step: Data)? {
        if let legacy {
            do { return try await legacy.localResult(agentID: agentID, turnID: turnID) }
            catch NanocodexError.missingCADOutput { return nil }
        }
        return nil
    }
    func artifacts(agentID: String, turnID: String?) async throws -> NanocodexArtifactPage {
        guard let generation, turnID == generation.turnID else { throw NanocodexError.invalidReference }
        let page: NanocodexArtifactPage
        do { page = try await client.artifacts(agentID: agentID, turnID: turnID) }
        catch NanocodexError.http(let code) where generation.transport != "cloud" && [403, 404].contains(code) {
            // An old phone-hosted turn may have no server publication. It has
            // finished, so expose a fresh retry instead of looping on recovery.
            throw NanocodexError.missingCADOutput
        }
        let sourceRoot = generation.transport == "cloud" ? "/brain/connect/" + (credentials.connect?.grantID ?? "") + "/outputs/" + generation.turnID : "/brain/outputs"
        let data = page.data.filter { $0.turnID == turnID && [sourceRoot + "/model.step", sourceRoot + "/model.cad.json"].contains($0.path) }
            .map { artifact in NanocodexArtifact(id: artifact.id, turnID: artifact.turnID,
                path: "/brain/outputs/" + (artifact.path as NSString).lastPathComponent, digest: artifact.digest, size: artifact.size) }
        return NanocodexArtifactPage(data: data, publications: page.publications.filter { $0.turnID == turnID })
    }
    func download(agentID: String, artifact: NanocodexArtifact) async throws -> URL { try await client.download(agentID: agentID, artifact: artifact) }
    func downloadFile(agentID: String, path: String, expectedDigest: String?) async throws -> URL {
        throw NanocodexError.missingCADOutput
    }
    nonisolated func close() { client.close(); session.invalidateAndCancel(); Task { await shutdown() } }
    private func shutdown() { closed = true; legacy?.close(); legacy = nil }
}

private final class NoCloudRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
