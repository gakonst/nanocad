import Foundation

/// Only user-visible messages and tool activity belong here. Reasoning events are never retained.
struct GenerationTranscriptEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case user, commentary, assistant, final, toolCall, toolResult, error, notice }
    var id: String
    var kind: Kind
    var text: String
    var toolName: String?
    var details: String?
    var turnID: String
    var isError = false
    var itemID: String?
    var modelCallIndex: Int?
    var phase: String?
    var callID: String?
    var isComplete = true

    var title: String {
        switch kind {
        case .user: "You"
        case .commentary: "Astra · Update"
        case .assistant: "Astra"
        case .final: "Astra · Answer"
        case .toolCall: "Tool call"
        case .toolResult: isError ? "Tool failed" : text == "Cancelled" ? "Tool cancelled" : "Tool result"
        case .error: "Generation needs attention"
        case .notice: "Generation status"
        }
    }
}

/// A bounded, independent checkpoint: clearing a pending request never clears its transcript.
struct GenerationTranscript: Codable, Sendable {
    static let maximumEntries = 4_000
    static let maximumBytes = 8_000_000
    static let maximumFileBytes = 24_000_000
    private(set) var entries: [GenerationTranscriptEntry] = []
    private(set) var omittedEntries = 0
    private var cursors: [String: String] = [:]

    var notice: String? {
        var notes = [String]()
        if omittedEntries > 0 { notes.append("Earlier transcript history was omitted (\(omittedEntries) entries). The app retains up to 4,000 entries and 8 MB of transcript text.") }
        if entries.contains(where: { $0.text.contains(TranscriptRedaction.truncation) || $0.details?.contains(TranscriptRedaction.truncation) == true }) {
            notes.append("Some long entries were shortened; each text or detail field retains up to 100,000 characters.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
    func cursor(for turnID: String) -> String { cursors[turnID] ?? "0" }
    static func isNewer(_ cursor: String, than previous: String) -> Bool {
        // Decimal cursors can exceed JavaScript/Swift integer precision. Compare normalized strings.
        let lhs = String(cursor.drop(while: { $0 == "0" })), rhs = String(previous.drop(while: { $0 == "0" }))
        return lhs.count == rhs.count ? lhs > rhs : lhs.count > rhs.count
    }
    func latestCommentary(for turnID: String) -> String? {
        entries.last(where: { $0.turnID == turnID && $0.kind == .commentary && !$0.text.isEmpty }).map { Self.summary($0.text) }
    }
    func assistantResponse(for turnID: String) -> String {
        let messages = entries.filter { $0.turnID == turnID && [.assistant, .commentary, .final].contains($0.kind) }
        return messages.last(where: { $0.kind == .final })?.text ?? messages.last?.text ?? ""
    }
    private static func summary(_ text: String) -> String {
        let plain = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return plain.count > 180 ? String(plain.prefix(179)) + "…" : plain
    }
    mutating func recordUser(_ prompt: String, turnID: String) {
        let id = "user:" + turnID
        guard !entries.contains(where: { $0.id == id }) else { return }
        entries.append(.init(id: id, kind: .user, text: TranscriptRedaction.text(prompt), turnID: turnID))
        trim()
    }
    mutating func recordStatus(_ text: String, turnID: String, error: Bool = false) {
        let safe = TranscriptRedaction.text(text)
        guard entries.last?.turnID != turnID || entries.last?.text != safe else { return }
        entries.append(.init(id: UUID().uuidString, kind: error ? .error : .notice, text: safe, turnID: turnID, isError: error))
        trim()
    }

    /// Returns false for a replayed cursor. Other turns/control frames advance only this observer's checkpoint.
    @discardableResult mutating func receive(_ event: NanocodexEvent, for observedTurnID: String) -> Bool {
        guard Self.isNewer(event.cursor, than: cursor(for: observedTurnID)) else { return false }
        cursors[observedTurnID] = event.cursor
        guard event.turnID == observedTurnID else { return true }
        let turnID = observedTurnID
        switch event.type {
        case "assistant.delta", "assistant.message":
            guard event.phase == nil || ["commentary", "final_answer", "final"].contains(event.phase!) else { break }
            let kind: GenerationTranscriptEntry.Kind = event.phase == "commentary" ? .commentary : ["final_answer", "final"].contains(event.phase ?? "") ? .final : .assistant
            let complete = event.type == "assistant.message"
            // A final message can supply the phase absent from its earlier deltas. Explicit phases never merge.
            let match = entries.lastIndex { row in
                guard row.turnID == turnID, [.assistant, .commentary, .final].contains(row.kind),
                      row.modelCallIndex == event.modelCallIndex,
                      row.phase == event.phase || (!row.isComplete && (row.phase == nil || event.phase == nil)) else { return false }
                if let rowItem = row.itemID, let eventItem = event.itemID { return rowItem == eventItem }
                // Older streams can omit an item ID until the completed message.
                // Bind only an unfinished row; never merge distinct completed items.
                return !row.isComplete
            }
            if let index = match {
                if !complete && entries[index].isComplete { break }
                entries[index].text = TranscriptRedaction.text(complete ? event.text : entries[index].text + event.text)
                if event.phase != nil { entries[index].kind = kind; entries[index].phase = event.phase }
                if let itemID = event.itemID { entries[index].itemID = itemID }
                entries[index].isComplete = complete
            } else if !event.text.isEmpty {
                entries.append(.init(id: "message:\(turnID):\(event.cursor)", kind: kind, text: TranscriptRedaction.text(event.text), turnID: turnID,
                    itemID: event.itemID, modelCallIndex: event.modelCallIndex, phase: event.phase, isComplete: complete))
            }
        case "tool.call", "tool.result":
            let result = event.type == "tool.result"
            let call = entries.last { $0.turnID == turnID && $0.kind == .toolCall && event.callID != nil && $0.callID == event.callID }
            let toolName = event.toolName ?? call?.toolName
            let failed = event.toolFailed
            let label = !result ? GenerationProgress.summary(toolName: toolName, arguments: event.arguments)
                : failed ? "Failed" : event.toolStatus == "cancelled" ? "Cancelled" : event.toolStatus == "completed" ? "Completed" : "Result received"
            entries.append(.init(id: "tool:\(turnID):\(event.cursor)", kind: result ? .toolResult : .toolCall, text: label,
                toolName: toolName, details: (result ? event.result : event.arguments).map(TranscriptRedaction.text), turnID: turnID,
                isError: failed, modelCallIndex: event.modelCallIndex, callID: event.callID))
        case "turn_completed":
            let safe = TranscriptRedaction.text(event.text)
            if !safe.isEmpty {
                if let index = entries.lastIndex(where: { $0.turnID == turnID && [.assistant, .final].contains($0.kind) && (!$0.isComplete || $0.text == safe) }) {
                    entries[index].kind = .final; entries[index].text = safe; entries[index].isComplete = true
                } else {
                    entries.append(.init(id: "final:\(turnID):\(event.cursor)", kind: .final, text: safe, turnID: turnID))
                }
            }
        case "turn_failed", "turn_cancelled":
            recordStatus(event.text.isEmpty ? (event.type == "turn_cancelled" ? "Generation cancelled." : "Generation failed.") : event.text,
                turnID: turnID, error: event.type == "turn_failed")
        default: break
        }
        trim(preservingCursor: observedTurnID)
        return true
    }

    private mutating func trim(preservingCursor turnID: String? = nil) {
        var bytes = entries.reduce(0) { $0 + $1.text.utf8.count + ($1.details?.utf8.count ?? 0) }
        var remove = 0
        while entries.count - remove > Self.maximumEntries || bytes > Self.maximumBytes {
            guard remove < entries.count else { break }
            bytes -= entries[remove].text.utf8.count + (entries[remove].details?.utf8.count ?? 0)
            remove += 1
        }
        if remove > 0 { entries.removeFirst(remove); omittedEntries += remove }
        var retainedTurns = Set(entries.map(\.turnID))
        if let turnID { retainedTurns.insert(turnID) }
        cursors = cursors.filter { retainedTurns.contains($0.key) }
    }
}

/// Remove known secret/file fields before storage, including JSON nested inside strings and shell arguments.
enum TranscriptRedaction {
    static let truncation = "[Transcript content truncated]"
    private static let limit = 100_000
    private static let secretKeys: Set<String> = ["authorization", "proxyauthorization", "cookie", "setcookie", "apikey", "accesstoken", "refreshtoken", "idtoken", "token", "password", "passwd", "secret", "clientsecret", "privatekey", "credential", "credentials"]
    private static let fileKeys: Set<String> = ["database64", "base64", "filebase64", "imagebase64", "audiobase64", "imagedata", "audiodata", "imageurl", "audiourl", "blob"]
    private static func key(_ value: String) -> String { value.lowercased().filter(\.isLetter) }
    static func details(_ value: Any) -> String {
        let safe = sanitize(value)
        if let string = safe as? String { return text(string) }
        guard let bytes = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return "[Unprintable tool detail]" }
        return text(String(decoding: bytes, as: UTF8.self))
    }
    private static func sanitize(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.mapValues { $0 }.reduce(into: [String: Any]()) { result, pair in
                let name = key(pair.key)
                if secretKeys.contains(name) || name.hasSuffix("apikey") || name.hasSuffix("accesstoken") { result[pair.key] = "[Redacted]" }
                else if fileKeys.contains(name) || name.hasSuffix("base64") { result[pair.key] = "[File payload omitted]" }
                else if name == "data", let type = object["type"] as? String, ["image", "audio"].contains(type) { result[pair.key] = "[File payload omitted]" }
                else { result[pair.key] = sanitize(pair.value) }
            }
        }
        if let array = value as? [Any] { return array.map(sanitize) }
        if let string = value as? String {
            if let bytes = string.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: bytes), json is [String: Any] || json is [Any] { return details(json) }
            return text(string)
        }
        return value
    }
    static func text(_ value: String) -> String {
        var safe = value
        let rules: [(String, String)] = [
            (#"(?i)data:[a-z0-9.+/-]+;base64,[a-z0-9+/=_-]*"#, "[File payload omitted]"),
            (#"(?i)([\"']?(?:data_base64|file_base64|image_base64|audio_base64)[\"']?\s*[:=]\s*)[\"'][^\"']*[\"']"#, "$1\"[File payload omitted]\""),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [Redacted]"),
            (#"(?i)([\"']?(?:authorization|proxy-authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|password|passwd|secret|client[_-]?secret|private[_-]?key)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;}]+)"#, "$1\"[Redacted]\""),
            (#"\b(?:ncx_live_|ncg_|ncc_|sk-)[A-Za-z0-9_-]+"#, "[Redacted]"),
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#, "[Redacted private key]"),
            (#"[A-Za-z0-9+/=_-]{256,}"#, "[Encoded payload omitted]")
        ]
        for (pattern, replacement) in rules { safe = safe.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        if safe.count > limit { safe = String(safe.prefix(limit)) + "\n" + truncation }
        return safe
    }
}

enum GenerationProgress {
    static func summary(toolName: String?, arguments: String?) -> String {
        let name = (toolName ?? "").lowercased(), detail = (arguments ?? "").lowercased()
        if name.contains("nanocad_read_input") || name.contains("read_file") || name.contains("view_image") { return "Reading model" }
        if name.contains("nanocad_write_output") { return "Receiving model" }
        if name.contains("mount") || name.contains("environment") || name.contains("tool_search") { return "Preparing workspace" }
        if name.contains("exec_command") {
            if detail.contains("uv ") || detail.contains("pip install") || detail.contains("mkdir ") { return "Preparing workspace" }
            if detail.contains("export_step.py") { return "Preparing model preview" }
            if detail.contains("build123d") || detail.contains("model.py") { return "Updating geometry" }
            return "Running model tools"
        }
        if name.contains("write_stdin") || name.contains("wait") { return "Waiting for model tools" }
        return "Working on your model"
    }
}
