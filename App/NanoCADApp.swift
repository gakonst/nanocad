import SwiftUI

@main
struct NanoCADApp: App {
    @State private var validation = ConnectValidationRunner()
    private let validationMode = ConnectValidationRunner.Mode.requested

    var body: some Scene {
        WindowGroup {
            if let validationMode {
                ConnectValidationView(runner: validation, mode: validationMode)
            } else {
                WorkspaceView()
            }
        }
    }
}

/// Present only for an explicit validation launch. The normal workspace is never
/// constructed here, so it cannot change the user's document or admit a parallel turn.
private struct ConnectValidationView: View {
    let runner: ConnectValidationRunner
    let mode: ConnectValidationRunner.Mode
    @StateObject private var viewport = ViewportController()
    @State private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect \(mode.rawValue) validation").font(.title2.bold())
            Text(runner.status).accessibilityIdentifier("connect-validation-status")
            if let report = runner.report {
                Text("Run \(report.runID)").font(.caption.monospaced()).textSelection(.enabled)
                Text("Stage: \(report.stage) · \(report.state)").font(.caption)
                if let metrics = report.cad {
                    Text("\(metrics.faces) faces · \(metrics.triangles) triangles · STEP hash verified")
                }
                if let failure = report.failures.last {
                    Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if runner.reportWriteFailed {
                Text("The validation report could not be saved.").foregroundStyle(.red)
            }
            if runner.running {
                ProgressView()
                Button("Cancel validation", role: .destructive) { runner.stop() }
                    .accessibilityIdentifier("cancel-connect-validation")
            }
            if let document = runner.document {
                CADViewport(document: document, mode: .face, selection: $selection, controller: viewport)
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .accessibilityIdentifier("connect-validation-viewport")
                Text("Tap a face to inspect the generated model").font(.caption).foregroundStyle(.secondary)
            }
            Text("Reports and received files: Documents/NanoCAD/Validation")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await runner.runOnce(mode: mode) }
    }
}
