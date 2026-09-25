import SwiftUI

@main
struct NanoCADApp: App {
    @State private var validation = ConnectValidationRunner()
    @State private var projects = CADProjectStore()
    @State private var showProjects = false
    @State private var drawerTranslation: CGFloat = 0
    @State private var horizontalDrag: Bool?
    @GestureState private var drawerDragging = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var projectError: String?
    @State private var projectStartupHandled = false
    @State private var validationMode = ConnectValidationRunner.Mode.requested

    var body: some Scene {
        WindowGroup {
            Group {
                if let validationMode {
                    ConnectValidationView(runner: validation, mode: validationMode, onDone: { self.validationMode = nil })
                } else if let project = projects.activeProject {
                    GeometryReader { geometry in
                        let wide = sizeClass == .regular && geometry.size.width >= 700
                        let width = max(0, min(geometry.size.width - 24, 420))
                        let reveal = min(width, max(0, showProjects ? width + drawerTranslation : drawerTranslation))
                        ZStack(alignment: .leading) {
                            if !wide && (showProjects || drawerTranslation > 0) {
                                sidebar(compact: true).frame(width: width, height: geometry.size.height)
                                    .allowsHitTesting(showProjects).accessibilityHidden(!showProjects)
                                    .transition(.opacity)
                            }
                            HStack(spacing: 0) {
                                if wide { sidebar(compact: false).frame(width: 300); Divider() }
                                WorkspaceView(project: project, root: projects.root(for: project),
                                    onProjects: { setSidebar(!showProjects) },
                                    onNewProject: {
                                        do { _ = try projects.create() } catch { projectError = error.localizedDescription }
                                    })
                                    .id(project.id)
                            }
                            .transaction { $0.animation = nil }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .background(Color(red: 0.075, green: 0.10, blue: 0.135))
                            .clipShape(.rect(cornerRadius: !wide && reveal > 0 ? 28 : 0))
                            .shadow(color: .black.opacity(!wide && reveal > 0 ? 0.2 : 0), radius: 16, x: -4)
                            .overlay {
                                if !wide && showProjects {
                                    Color.clear.contentShape(Rectangle()).onTapGesture { closeSidebar() }
                                        .accessibilityLabel("Close projects").accessibilityAddTraits(.isButton)
                                        .accessibilityIdentifier("projects-scrim")
                                }
                            }
                            .accessibilityHidden(!wide && showProjects)
                            .offset(x: wide ? 0 : reveal)
                        }
                        .clipped()
                        .contentShape(Rectangle())
                        .simultaneousGesture(DragGesture(minimumDistance: 16)
                            .updating($drawerDragging) { _, active, _ in active = true }
                            .onChanged { value in
                                guard !wide else { return }
                                if horizontalDrag == nil {
                                    horizontalDrag = (showProjects || value.startLocation.x <= 28)
                                        && abs(value.translation.width) > abs(value.translation.height) * 1.5
                                        && (showProjects || value.translation.width > 0)
                                }
                                guard horizontalDrag == true else { return }
                                dismissKeyboard()
                                drawerTranslation = showProjects ? max(-width, min(0, value.translation.width))
                                    : min(width, max(0, value.translation.width))
                            }.onEnded { value in
                                defer { horizontalDrag = nil }
                                guard horizontalDrag == true else { return }
                                setSidebar(showProjects
                                    ? !(value.translation.width < -width * 0.25 || value.predictedEndTranslation.width < -width * 0.5)
                                    : value.translation.width > width * 0.25 || value.predictedEndTranslation.width > width * 0.5)
                            })
                        .onChange(of: drawerDragging) { _, active in
                            guard !active else { return }
                            // GestureState may reset before onEnded. Let that callback
                            // settle the drawer before cleaning up a cancelled gesture.
                            Task { @MainActor in
                                await Task.yield()
                                guard !drawerDragging else { return }
                                horizontalDrag = nil
                                if drawerTranslation != 0 { setSidebar(showProjects) }
                            }
                        }
                        .onChange(of: geometry.size.width) { _, _ in
                            horizontalDrag = nil
                            drawerTranslation = 0
                        }
                        .onChange(of: wide) { _, _ in
                            horizontalDrag = nil
                            drawerTranslation = 0
                            showProjects = false
                        }
                        .background(Color(red: 0.075, green: 0.10, blue: 0.135))
                        .preferredColorScheme(.dark).tint(.teal)
                    }
                } else { ProgressView("Opening your projects…") }
            }
            .task {
                guard !projectStartupHandled else { return }
                projectStartupHandled = true
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
                    try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: "NanoCAD"))
                }
                #endif
                do { try projects.load() } catch { projectError = error.localizedDescription }
            }
            .alert("Couldn’t open project", isPresented: Binding(get: { projectError != nil }, set: { if !$0 { projectError = nil } })) {
                Button("OK", role: .cancel) { projectError = nil }
            } message: { Text(projectError ?? "") }
        }
    }
    private var sidebarAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.92) }
    private func dismissKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
    private func setSidebar(_ visible: Bool) {
        dismissKeyboard()
        withAnimation(sidebarAnimation) { drawerTranslation = 0; showProjects = visible }
    }
    private func closeSidebar() { setSidebar(false) }
    private func sidebar(compact: Bool) -> some View {
        ProjectsView(store: projects, onSelect: { _ in closeSidebar() },
                     compact: compact, onClose: closeSidebar)
    }

}

/// Present only for an explicit validation launch. The normal workspace is never
/// constructed here, so it cannot change the user's document or admit a parallel turn.
private struct ConnectValidationView: View {
    let runner: ConnectValidationRunner
    let mode: ConnectValidationRunner.Mode
    var onDone: () -> Void
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
            if !runner.running, runner.report?.finishedAt != nil {
                Button("Return to NanoCAD", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("finish-connect-validation")
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
