import Foundation
import CoreFoundation

private final class ConnectSocketNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Hosted-tool metadata identifies the kernel runtime session/turn, not managed
/// HTTP agent/turn IDs. The authenticated grant socket scopes the public agent;
/// the unpredictable per-generation ID scopes the files. Only a request for that
/// generation can establish a runtime binding, retained across socket reconnects.
struct ConnectRuntimeBinding {
    let generationID: String
    private var session: String?
    private var turn: String?
    init(generationID: String) { self.generationID = generationID }
    mutating func accepts(session: String, turn: String, input: [String: Any]) -> Bool {
        guard input["generation_id"] as? String == generationID,
              !session.isEmpty, !turn.isEmpty,
              self.session == nil || self.session == session,
              self.turn == nil || self.turn == turn else { return false }
        self.session = session; self.turn = turn
        return true
    }
}

/// One turn's native reverse tool attachment. The owner must await start() before submitting the turn.
/// File mutation durability and idempotency belong to the supplied handler.
actor ConnectToolHost {
    typealias Handler = @Sendable (String, Data) async throws -> Data

    enum HostError: LocalizedError, Sendable, Equatable {
        case stopped, invalidConfiguration, invalidProtocol, handshakeTimeout, heartbeatTimeout, disconnected
        var errorDescription: String? {
            switch self {
            case .stopped: "The CAD tool connection is closed."
            case .invalidConfiguration: "The CAD tool connection configuration is invalid."
            case .invalidProtocol: "Nanocodex rejected the CAD tool connection protocol."
            case .handshakeTimeout: "The CAD tool connection did not become ready in time."
            case .heartbeatTimeout: "The CAD tool connection stopped responding."
            case .disconnected: "The CAD tool connection disconnected. Resume the existing turn to reconnect."
            }
        }
    }

    private let credentials: NanocodexCredentials
    private let catalog: Data
    private let agentID: String
    private let turnID: String
    private var runtimeBinding: ConnectRuntimeBinding
    private let handler: Handler
    private let client: NanocodexClient
    private let session: URLSession
    private let runtimeID = UUID().uuidString.lowercased()
    private var generation = UUID()
    private var stopped = false
    private var ready = false
    private var socket: URLSessionWebSocketTask?
    private var runner: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var handshake: Task<Void, Never>?
    private var readyWaiters: [CheckedContinuation<Void, any Error>] = []
    private var terminalError: HostError?
    private var pendingNonce: String?
    private var connectedAt: Date?
    private var transportError: HostError?
    private var calls: [String: Call] = [:]
    private var receipts: Set<String> = []
    // Keep cancelled, non-cooperative handlers counted until they actually return.
    private var executions: Set<UUID> = []
    private var toolNames: Set<String> = []

    private struct Call {
        let executionID: UUID
        let task: Task<Void, Never>
        let deadline: Task<Void, Never>
        let deadlineAt: Double
        let outputBudget: Int
    }

    init(credentials: NanocodexCredentials, catalog: Data, agentID: String, turnID: String, generationID: String,
         handler: @escaping Handler) {
        self.credentials = credentials
        self.catalog = catalog
        self.agentID = agentID
        self.turnID = turnID
        self.runtimeBinding = ConnectRuntimeBinding(generationID: generationID)
        self.handler = handler
        client = NanocodexClient(credentials: credentials)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 3_600
        session = URLSession(configuration: configuration, delegate: ConnectSocketNoRedirects(), delegateQueue: nil)
    }

    /// Waits for the server's ready frame, including a bounded number of transport retries.
    func start() async throws {
        try Task.checkCancellation()
        guard !stopped else { throw terminalError ?? .stopped }
        if ready { return }
        try validateConfiguration()
        ConnectDiagnostics.note("host.start")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                readyWaiters.append(continuation)
                if runner == nil {
                    runner = Task { [weak self] in await self?.run() }
                }
            }
        } onCancel: {
            Task { await self.stop() }
        }
        try Task.checkCancellation()
    }

    /// Closes transport immediately. The owner separately cancels durable server work.
    func stop() async {
        finish(.stopped)
    }

    private func validateConfiguration() throws {
        guard let grant = credentials.connect, grant.agentID == agentID,
              credentials.origin == ConnectConfiguration.apiOrigin,
              Self.identifier(agentID), UUID(uuidString: runtimeBinding.generationID) != nil, !turnID.isEmpty, turnID.utf8.count <= 256 else {
            throw HostError.invalidConfiguration
        }
        try ConnectConfiguration.validate(grant)
        guard let tools = try JSONSerialization.jsonObject(with: catalog) as? [[String: Any]], !tools.isEmpty else {
            throw HostError.invalidConfiguration
        }
        let names = tools.compactMap { $0["remote_name"] as? String }
        guard names.count == tools.count, names.allSatisfy(Self.identifier), Set(names).count == names.count else {
            throw HostError.invalidConfiguration
        }
        toolNames = Set(names)
    }

    private func run() async {
        var failures = 0
        while !stopped && !Task.isCancelled {
            let current = UUID()
            generation = current
            do {
                try await connectAndReceive(current)
                throw HostError.disconnected
            } catch {
                guard !stopped, generation == current else { return }
                let failure = transportError ?? (error as? HostError)
                ConnectDiagnostics.note("host.disconnect", ["domain": (error as NSError).domain,
                    "code": String((error as NSError).code), "close": String(socket?.closeCode.rawValue ?? -1),
                    "ready": String(ready), "protocol": String(failure == .invalidProtocol)])
                let policyClosed = socket?.closeCode == .policyViolation
                if let connectedAt, Date().timeIntervalSince(connectedAt) >= 30 { failures = 0 }
                disconnect()
                if policyClosed || failure == .invalidProtocol || failure == .invalidConfiguration {
                    finish(.invalidProtocol)
                    return
                }
                if case NanocodexError.http(let code) = error, code == 401 || code == 403 {
                    finish(.invalidConfiguration)
                    return
                }
                if error is ConnectError {
                    finish(.invalidConfiguration)
                    return
                }
                failures += 1
                guard failures <= 5 else { finish(failure ?? .disconnected); return }
                let delay = min(5.0, 0.25 * pow(2.0, Double(failures - 1)))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    private func connectAndReceive(_ current: UUID) async throws {
        try ensureActive(current)
        try validateConfiguration()
        let request = try client.request(path: "/v1/agents/" + agentID + "/tool-host/ticket", method: "POST")
        let (data, response) = try await session.data(for: request)
        try ensureActive(current)
        guard let response = response as? HTTPURLResponse else { throw HostError.invalidProtocol }
        guard (200..<300).contains(response.statusCode) else { throw NanocodexError.http(response.statusCode) }
        struct Ticket: Decodable { let ticket: String }
        guard data.count <= 16_384, let receipt = try? JSONDecoder().decode(Ticket.self, from: data),
              !receipt.ticket.isEmpty, receipt.ticket.utf8.count <= 8_192,
              let grant = credentials.connect else { throw HostError.invalidProtocol }
        var endpoint = URLComponents()
        endpoint.scheme = "wss"
        endpoint.host = "nanocodex-connect-api.gakonst.workers.dev"
        endpoint.path = "/v1/grants/" + grant.grantID + "/agents/" + agentID + "/tool-host"
        endpoint.queryItems = [URLQueryItem(name: "ticket", value: receipt.ticket)]
        guard let url = endpoint.url else { throw HostError.invalidConfiguration }
        var socketRequest = request
        socketRequest.url = url
        socketRequest.httpMethod = "GET"
        socketRequest.httpBody = nil
        let transport = session.webSocketTask(with: socketRequest)
        transport.maximumMessageSize = 2 * 1_024 * 1_024
        socket = transport
        transport.resume()
        handshake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await self?.failTransport(.handshakeTimeout, generation: current)
        }
        let tools = try JSONSerialization.jsonObject(with: catalog)
        try await send(["type": "catalog", "tools": tools, "capabilities": ["turn_metadata"], "runtime_id": runtimeID],
                       generation: current, requiresReady: false)
        while true {
            let message = try await transport.receive()
            try ensureActive(current)
            guard case .string(let text) = message else { throw HostError.invalidProtocol }
            try await receive(text, generation: current)
        }
    }

    private func receive(_ text: String, generation current: UUID) async throws {
        guard let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = frame["type"] as? String else { throw HostError.invalidProtocol }
        let allowed: Set<String>
        switch type {
        case "ready": allowed = ["type"]
        case "call": allowed = ["type", "session_id", "turn_id", "call_id", "model", "name", "input",
                                "output_token_budget", "output_byte_budget", "deadline_at"]
        case "cancel", "ack": allowed = ["type", "call_id"]
        case "pong": allowed = ["type", "nonce"]
        default: throw HostError.invalidProtocol
        }
        guard Set(frame.keys).isSubset(of: allowed) else { throw HostError.invalidProtocol }
        switch type {
        case "ready":
            guard !ready else { throw HostError.invalidProtocol }
            ready = true
            ConnectDiagnostics.note("host.ready")
            connectedAt = Date()
            handshake?.cancel(); handshake = nil
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0.resume() }
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self else { return }
                    await self.sendHeartbeat(generation: current)
                }
            }
        case "call":
            guard ready else { throw HostError.invalidProtocol }
            try await dispatch(frame, generation: current)
        case "cancel", "ack":
            guard ready, let callID = frame["call_id"] as? String, Self.identifier(callID) else {
                throw HostError.invalidProtocol
            }
            if type == "ack" {
                ConnectDiagnostics.note("host.ack")
                guard receipts.remove(callID) != nil else { throw HostError.invalidProtocol }
            } else if let call = calls.removeValue(forKey: callID) {
                call.task.cancel(); call.deadline.cancel()
                try await retainAndSend(callID: callID, outcome: Self.ambiguous("Tool execution was cancelled after dispatch."),
                                        generation: current)
            }
        case "pong":
            guard ready, let nonce = frame["nonce"] as? String, !nonce.isEmpty, nonce.utf8.count <= 128,
                  pendingNonce == nonce else { throw HostError.invalidProtocol }
            pendingNonce = nil
        default: throw HostError.invalidProtocol
        }
    }

    private func dispatch(_ frame: [String: Any], generation current: UUID) async throws {
        ConnectDiagnostics.note("host.call", [
            "sessionMatches": String(frame["session_id"] as? String == agentID),
            "turnMatches": String(frame["turn_id"] as? String == turnID),
            "knownTool": String((frame["name"] as? String).map(toolNames.contains) ?? false),
            "inputIsString": String(frame["input"] is String),
            "inputIsObject": String(frame["input"] is [String: Any]),
            "hasTurn": String(frame["turn_id"] != nil)])
        guard let sessionID = frame["session_id"] as? String, Self.identifier(sessionID),
              let incomingTurnID = frame["turn_id"] as? String, !incomingTurnID.isEmpty, incomingTurnID.utf8.count <= 256,
              let callID = frame["call_id"] as? String, Self.identifier(callID),
              let name = frame["name"] as? String, Self.identifier(name), toolNames.contains(name),
              frame["model"] is String, let input = frame["input"],
              input is String || input is [String: Any],
              Self.positiveInteger(frame["output_token_budget"]) != nil,
              let outputBudget = Self.positiveInteger(frame["output_byte_budget"]),
              let deadline = Self.positiveInteger(frame["deadline_at"]),
              calls[callID] == nil, !receipts.contains(callID) else { throw HostError.invalidProtocol }
        if Double(deadline) <= Self.nowMilliseconds {
            try await retainAndSend(callID: callID, outcome: ["status": "unavailable", "message": "Tool deadline elapsed before dispatch."],
                                    generation: current)
            return
        }
        guard executions.count < 32 else {
            try await retainAndSend(callID: callID, outcome: ["status": "unavailable", "message": "Native tool capacity is currently occupied."],
                                    generation: current)
            return
        }
        let inputData: Data
        if let string = input as? String {
            inputData = Data(string.utf8)
            guard (try JSONSerialization.jsonObject(with: inputData)) is [String: Any] else { throw HostError.invalidProtocol }
        } else { inputData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) }
        guard let fields = try JSONSerialization.jsonObject(with: inputData) as? [String: Any],
              runtimeBinding.accepts(session: sessionID, turn: incomingTurnID, input: fields) else {
            ConnectDiagnostics.note("host.binding_rejected")
            throw HostError.invalidProtocol
        }
        ConnectDiagnostics.note("host.binding_accepted")
        let executionID = UUID()
        executions.insert(executionID)
        let operation = handler
        let task = Task { [weak self] in
            let result: Result<Data, any Error>
            do {
                try Task.checkCancellation()
                result = .success(try await operation(name, inputData))
            } catch { result = .failure(error) }
            await self?.complete(callID: callID, executionID: executionID, result: result, generation: current)
        }
        let deadlineTask = Task { [weak self] in
            // Sleep in bounded slices even if the server supplies a distant safe-integer deadline.
            while !Task.isCancelled {
                let remaining = Double(deadline) / 1_000 - Date().timeIntervalSince1970
                if remaining <= 0 { break }
                do { try await Task.sleep(for: .seconds(min(remaining, 3_600))) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.expire(callID: callID, executionID: executionID, generation: current)
        }
        calls[callID] = Call(executionID: executionID, task: task, deadline: deadlineTask,
                             deadlineAt: Double(deadline), outputBudget: outputBudget)
    }

    private func complete(callID: String, executionID: UUID, result: Result<Data, any Error>, generation current: UUID) async {
        executions.remove(executionID)
        guard !stopped, generation == current, let call = calls[callID], call.executionID == executionID else { return }
        calls.removeValue(forKey: callID)
        call.deadline.cancel()
        var outcome: [String: Any]
        if Self.nowMilliseconds >= call.deadlineAt {
            outcome = Self.ambiguous("Tool execution crossed its admitted deadline after dispatch.")
        } else {
            do {
                let output: [String: Any]
                switch result {
                case .success(let bytes):
                    guard bytes.count <= call.outputBudget else { throw HostError.invalidProtocol }
                    let value = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
                    let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
                    output = ["output": String(decoding: encoded, as: UTF8.self), "success": true,
                              "structured_result": value, "metadata": NSNull(), "process_trace": NSNull()]
                case .failure:
                    // Do not forward exception descriptions: they may contain local paths or authorization data.
                    output = ["output": "The native CAD tool failed.", "success": false,
                              "structured_result": NSNull(), "metadata": NSNull(), "process_trace": NSNull()]
                }
                guard try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes]).count <= call.outputBudget else {
                    throw HostError.invalidProtocol
                }
                outcome = ["status": "completed", "output": output]
            } catch {
                outcome = Self.ambiguous("Tool result was invalid or exceeded the admitted byte budget after dispatch.")
            }
        }
        ConnectDiagnostics.note("host.result", ["status": outcome["status"] as? String ?? "unknown"])
        do { try await retainAndSend(callID: callID, outcome: outcome, generation: current) }
        catch { failTransport(.disconnected, generation: current) }
    }

    private func expire(callID: String, executionID: UUID, generation current: UUID) async {
        guard !stopped, generation == current, let call = calls[callID], call.executionID == executionID else { return }
        calls.removeValue(forKey: callID)
        call.task.cancel(); call.deadline.cancel()
        do {
            try await retainAndSend(callID: callID, outcome: Self.ambiguous("Tool execution crossed its admitted deadline after dispatch."),
                                    generation: current)
        } catch { failTransport(.disconnected, generation: current) }
    }

    private func retainAndSend(callID: String, outcome: [String: Any], generation current: UUID) async throws {
        try ensureActive(current)
        receipts.insert(callID)
        try await send(["type": "result", "call_id": callID, "outcome": outcome], generation: current)
    }

    private func sendHeartbeat(generation current: UUID) async {
        guard !stopped, generation == current, ready else { return }
        guard pendingNonce == nil else { failTransport(.heartbeatTimeout, generation: current); return }
        let nonce = UUID().uuidString.lowercased()
        pendingNonce = nonce
        do { try await send(["type": "ping", "nonce": nonce], generation: current) }
        catch { failTransport(.disconnected, generation: current) }
    }

    private func send(_ frame: [String: Any], generation current: UUID, requiresReady: Bool = true) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys, .withoutEscapingSlashes])
        try ensureActive(current)
        guard let socket, socket.state == .running, !requiresReady || ready else { throw HostError.disconnected }
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        try ensureActive(current)
    }

    private func ensureActive(_ current: UUID) throws {
        try Task.checkCancellation()
        guard !stopped, current == generation else { throw HostError.stopped }
    }

    private func failTransport(_ error: HostError, generation current: UUID) {
        guard !stopped, generation == current else { return }
        transportError = error
        socket?.cancel(with: .goingAway, reason: nil)
    }

    private func disconnect(code: URLSessionWebSocketTask.CloseCode = .goingAway) {
        generation = UUID()
        ready = false
        heartbeat?.cancel(); heartbeat = nil
        handshake?.cancel(); handshake = nil
        for call in calls.values { call.task.cancel(); call.deadline.cancel() }
        calls.removeAll()
        receipts.removeAll()
        pendingNonce = nil
        connectedAt = nil
        transportError = nil
        socket?.cancel(with: code, reason: nil)
        socket = nil
    }

    private func finish(_ error: HostError) {
        guard !stopped else { return }
        stopped = true
        ConnectDiagnostics.note("host.stop", ["reason": String(describing: error)])
        terminalError = error
        runner?.cancel(); runner = nil
        disconnect(code: error == .invalidProtocol ? .policyViolation : .normalClosure)
        session.invalidateAndCancel()
        client.close()
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    private static func ambiguous(_ message: String) -> [String: Any] { ["status": "ambiguous", "message": message] }
    private static var nowMilliseconds: Double { Date().timeIntervalSince1970 * 1_000 }
    private static func identifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) != nil
    }
    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 1, value <= 9_007_199_254_740_991, value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
}
