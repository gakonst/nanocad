import Foundation

/// Bounded protocol metadata only. Never pass credentials, request URLs, tool inputs,
/// response bodies, or arbitrary error descriptions to this recorder.
enum ConnectDiagnostics {
    private static let recorder = Recorder()
    static func note(_ event: String, _ fields: [String: String] = [:]) {
        let instant = Date().timeIntervalSince1970
        Task { await recorder.append(event, fields, instant: instant) }
    }
    private actor Recorder {
        func append(_ event: String, _ fields: [String: String], instant: Double) {
            do {
                let root = URL.documentsDirectory.appending(path: "NanoCAD", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let url = root.appending(path: "connect-transport.jsonl")
                let row: [String: Any] = ["time": instant, "event": event, "fields": fields]
                var retained = (try? Data(contentsOf: url)) ?? Data()
                if retained.count > 96_000 {
                    retained = Data(retained.suffix(48_000))
                    if let newline = retained.firstIndex(of: 10) { retained = Data(retained.suffix(from: retained.index(after: newline))) }
                }
                retained.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                retained.append(10)
                try retained.write(to: url, options: .atomic)
            } catch { /* Diagnostics must not affect modeling or expose error details. */ }
        }
    }
}
