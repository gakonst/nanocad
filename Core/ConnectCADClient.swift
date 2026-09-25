import CryptoKit
import Foundation

/// Files explicitly shared with this app's signed Connect tools. No arbitrary filesystem access.
actor ConnectFileTransfer {
    static let chunkSize = 32_768
    static let maxSize = 80_000_000
    struct Manifest: Codable, Equatable {
        let generationID: String
        let agentID: String
        let turnID: String
        let inputs: [String: String]
    }
    struct Output: Codable, Equatable { let size: Int; let digest: String }
    private let root: URL
    private let generationID: String
    private var prepared = false
    struct ReadReceipt: Codable, Sendable {
        let file: String
        let offset: Int
        let count: Int
        let digest: String
    }
    private var reads: [ReadReceipt] = []
    func readReceipts() -> [ReadReceipt] { reads }


    init(root: URL, generationID: String) throws {
        guard UUID(uuidString: generationID) != nil else { throw NanocodexError.invalidReference }
        self.root = root.appending(path: generationID, directoryHint: .isDirectory)
        self.generationID = generationID
    }

    func prepare(_ generation: PendingGeneration, agentID: String) throws {
        guard generation.creationID == generationID,
              generation.agentID == nil || generation.agentID == agentID else { throw NanocodexError.invalidReference }
        var inputs: [String: String] = [:]
        for input in generation.files {
            let allowed = ["/brain/tools/export_step.py": "export_step.py", "/brain/input/model.step": "model.step", "/brain/input/markup.jpg": "markup.jpg"]
            guard let name = allowed[input.path], inputs[name] == nil, input.data.count <= Self.maxSize else { throw NanocodexError.invalidReference }
            inputs[name] = Self.digest(input.data)
        }
        let manifest = Manifest(generationID: generationID, agentID: agentID, turnID: generation.turnID, inputs: inputs)
        let manifestURL = root.appending(path: "manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            guard try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) == manifest else { throw NanocodexError.integrityFailure }
        }
        try FileManager.default.createDirectory(at: root.appending(path: "input"), withIntermediateDirectories: true)
        for input in generation.files {
            let url = root.appending(path: "input/" + (input.path as NSString).lastPathComponent)
            try input.data.write(to: url, options: .atomic)
        }
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        prepared = true
    }

    func handle(name: String, input: Data) throws -> Data {
        guard prepared, let fields = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              fields["generation_id"] as? String == generationID else { throw NanocodexError.invalidReference }
        let response: [String: Any]
        switch name {
        case "nanocad_read_input": response = try read(fields)
        case "nanocad_write_output": response = try write(fields)
        default: throw NanocodexError.invalidReference
        }
        return try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func read(_ fields: [String: Any]) throws -> [String: Any] {
        guard Set(fields.keys) == Set(["generation_id", "file", "offset", "length"]),
              let file = fields["file"] as? String, ["export_step.py", "model.step", "markup.jpg"].contains(file),
              let offset = integer(fields["offset"]), let length = integer(fields["length"]),
              offset >= 0, (1...Self.chunkSize).contains(length) else { throw NanocodexError.invalidReference }
        let bytes = try Data(contentsOf: root.appending(path: "input/" + file))
        guard offset <= bytes.count else { throw NanocodexError.invalidReference }
        let end = min(bytes.count, offset + length)
        let receipt = ReadReceipt(file: file, offset: offset, count: end - offset, digest: Self.digest(bytes))
        reads.append(receipt)
        if reads.count > 4096 { reads.removeFirst(reads.count - 4096) }
        try JSONEncoder().encode(reads).write(to: root.appending(path: "read-receipts.json"), options: .atomic)
        return ["generation_id": generationID, "file": file, "offset": offset, "total_size": bytes.count,
                "sha256": Self.digest(bytes), "data_base64": bytes.subdata(in: offset..<end).base64EncodedString(), "eof": end == bytes.count]
    }

    private func write(_ fields: [String: Any]) throws -> [String: Any] {
        guard Set(fields.keys) == Set(["generation_id", "file", "offset", "total_size", "sha256", "data_base64"]),
              let file = fields["file"] as? String, ["model.step", "model.cad.json"].contains(file),
              let offset = integer(fields["offset"]), let size = integer(fields["total_size"]),
              (1...Self.maxSize).contains(size), offset >= 0, offset < size, offset % Self.chunkSize == 0,
              let hash = fields["sha256"] as? String, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let base64 = fields["data_base64"] as? String, base64.utf8.count <= 43_692,
              let bytes = Data(base64Encoded: base64), bytes.count == min(Self.chunkSize, size - offset) else {
            throw NanocodexError.invalidReference
        }
        let directory = root.appending(path: "output/" + file, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = Output(size: size, digest: hash), metadataURL = directory.appending(path: "metadata.json")
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            guard try JSONDecoder().decode(Output.self, from: Data(contentsOf: metadataURL)) == metadata else { throw NanocodexError.integrityFailure }
        } else { try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic) }
        let chunk = directory.appending(path: "\(offset).bin")
        if FileManager.default.fileExists(atPath: chunk.path) {
            guard try Data(contentsOf: chunk) == bytes else { throw NanocodexError.integrityFailure }
        } else { try bytes.write(to: chunk, options: .atomic) }
        return ["accepted": true, "generation_id": generationID, "file": file, "offset": offset, "bytes": bytes.count]
    }

    func result(agentID: String, turnID: String) throws -> (preview: Data, step: Data) {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appending(path: "manifest.json")))
        guard manifest.agentID == agentID, manifest.turnID == turnID else { throw NanocodexError.invalidReference }
        return (try completed("model.cad.json"), try completed("model.step"))
    }

    private func completed(_ file: String) throws -> Data {
        let directory = root.appending(path: "output/" + file)
        guard let data = try? Data(contentsOf: directory.appending(path: "metadata.json")),
              let metadata = try? JSONDecoder().decode(Output.self, from: data), (1...Self.maxSize).contains(metadata.size) else {
            throw NanocodexError.missingCADOutput
        }
        var bytes = Data(capacity: metadata.size)
        for offset in stride(from: 0, to: metadata.size, by: Self.chunkSize) {
            guard let chunk = try? Data(contentsOf: directory.appending(path: "\(offset).bin")),
                  chunk.count == min(Self.chunkSize, metadata.size - offset) else { throw NanocodexError.missingCADOutput }
            bytes.append(chunk)
        }
        guard Self.digest(bytes) == metadata.digest else { throw NanocodexError.integrityFailure }
        return bytes
    }
    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= Double(Self.maxSize),
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Connect's pre-provisioned agent plus a native reverse-tool file channel.
actor ConnectCADClient: GenerationClient {
    private let credentials: NanocodexCredentials
    private let client: NanocodexClient
    private var host: ConnectToolHost?
    private var transfer: ConnectFileTransfer?
    private var generation: PendingGeneration?
    private var closed = false
    private let requiresNativeExecution: Bool
    private let transferRoot: URL

    init(credentials: NanocodexCredentials, requiresNativeExecution: Bool = true, transferRoot: URL? = nil) {
        self.requiresNativeExecution = requiresNativeExecution
        self.transferRoot = transferRoot ?? URL.documentsDirectory.appending(path: "NanoCAD/ConnectTransfer", directoryHint: .isDirectory)
        self.credentials = credentials
        client = NanocodexClient(credentials: credentials)
    }

    func prepare(_ generation: PendingGeneration) async throws {
        guard !closed, let grant = credentials.connect else { throw NanocodexError.invalidCredential }
        try ConnectConfiguration.validate(grant)
        if requiresNativeExecution && grant.sandboxExecution != true && generation.stopRequested != true && generation.phase != "downloading" {
            throw ConnectError.executionApprovalRequired
        }
        guard generation.agentID == nil || generation.agentID == grant.agentID else {
            throw NanocodexError.publication("Reconnect the original NanoCAD conversation to resume this generation.")
        }
        self.generation = generation
        let transfer = try ConnectFileTransfer(root: transferRoot, generationID: generation.creationID)
        try await transfer.prepare(generation, agentID: grant.agentID)
        self.transfer = transfer
        // Stop and completed-file recovery need no live tool connection.
        if generation.stopRequested == true || generation.phase == "downloading" { return }
        guard let url = Bundle.main.url(forResource: "connect-tool-catalog", withExtension: "json") else { throw ConnectError.invalidCatalog }
        let host = ConnectToolHost(credentials: credentials, catalog: try Data(contentsOf: url), agentID: grant.agentID,
            turnID: generation.turnID, generationID: generation.creationID) { name, input in try await transfer.handle(name: name, input: input) }
        self.host = host
        try await host.start()
        try Task.checkCancellation()
        if generation.agentID == nil || generation.phase == "sending" { try await client.selectAstra(agentID: grant.agentID) }
    }

    func transferReadReceipts() async -> [ConnectFileTransfer.ReadReceipt] {
        await transfer?.readReceipts() ?? []
    }

    func createAgent(requestID: String, inputFiles: [NanocodexInputFile], instructions: String) async throws -> String {
        guard let grant = credentials.connect, generation?.creationID == requestID else { throw NanocodexError.invalidReference }
        return grant.agentID
    }

    func send(agentID: String, prompt: String, references: [String], revision: String?, requestID: String, turnID: String) async throws -> NanocodexTurnReceipt {
        guard let generation, generation.turnID == turnID else { throw NanocodexError.invalidReference }
        let files = generation.files.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
        let context = """
        \(NanocodexClient.cadInstructions)
        \(generation.instructions)
        NATIVE CONNECT FILE EXCHANGE — generation_id \(generation.creationID)
        This granted conversation may contain earlier models. Only inputs for the current generation ID are authoritative. Available input files: \(files).
        NanoCAD has attached the signed tools nanocad_read_input and nanocad_write_output. Discover them with tool_search if needed. They exchange bytes directly with the native app; account /files and /artifacts endpoints are not available to this grant. Keep each tool call within the supplied generation ID and current turn. Call both file tools from this root agent; do not delegate file transfer to subagents.
        Before modeling, use Code Mode to read each input in chunks of at most 32768 bytes (offset starts at 0). Each response has data_base64, total_size, sha256, eof. Assemble bytes and verify their SHA-256. Write export_step.py to /brain/tools/export_step.py and other inputs to /brain/input/ using exec_command with safely quoted base64, without printing file contents into model context. Do not guess, retype, or regenerate input bytes. The existing exporter is required.
        After creating and validating /brain/outputs/model.step and /brain/outputs/model.cad.json, deliver BOTH via nanocad_write_output before finishing. In Code Mode, use exec_command to obtain each file's base64 and sha256sum, then programmatically slice raw bytes into 32768-byte chunks (base64 is 43692 chars for a full chunk), and call the write tool with generation_id, file, offset, total_size, sha256 (whole file), data_base64 (this chunk). Last chunk may be smaller. Identical retries are safe; a conflicting digest/size/chunk is rejected. Each file must be <=80MB. Do not print base64 or claim completion before all chunks are acknowledged. Report the completed dimensions/change concisely.
        USER REQUEST:
        \(prompt)
        """
        return try await client.send(agentID: agentID, prompt: context, references: references, revision: revision, requestID: requestID, turnID: turnID)
    }

    func events(agentID: String, after: String, untilTurnID: String?, receive: @escaping @Sendable (NanocodexEvent) async -> Void) async throws {
        try await client.events(agentID: agentID, after: after, untilTurnID: untilTurnID, receive: receive)
    }
    func cancel(agentID: String, turnID: String) async throws { try await client.cancel(agentID: agentID, turnID: turnID) }
    func localResult(agentID: String, turnID: String) async throws -> (preview: Data, step: Data)? {
        guard let transfer else { throw NanocodexError.invalidResponse }
        return try await transfer.result(agentID: agentID, turnID: turnID)
    }
    func artifacts(agentID: String, turnID: String?) async throws -> NanocodexArtifactPage { throw NanocodexError.invalidReference }
    func download(agentID: String, artifact: NanocodexArtifact) async throws -> URL { throw NanocodexError.invalidReference }
    func downloadFile(agentID: String, path: String, expectedDigest: String?) async throws -> URL { throw NanocodexError.invalidReference }
    nonisolated func close() { Task { await shutdown() } }
    private func shutdown() async {
        closed = true
        await host?.stop()
        host = nil
        client.close()
    }
}
