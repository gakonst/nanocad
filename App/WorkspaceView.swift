import SwiftUI
import UniformTypeIdentifiers
import PencilKit

struct WorkspaceView: View {
    @State private var document: CADDocument?
    @State private var selection = Set<String>()
    @State private var mode: ViewportMode = .orbit
    @State private var prompt = ""
    @State private var showInspector = false
    @State private var showImport = false
    @State private var showConnection = false
    @State private var showActivity = false
    @State private var error: String?
    @State private var drawing = DrawingController()
    @StateObject private var viewport = ViewportController()
    @State private var drawingCamera: ViewportCameraState?
    @State private var generation = GenerationController()
    @State private var stepURL: URL?
    @State private var pendingImport: (Data, String)?
    @Environment(\.scenePhase) private var scenePhase
    private let persistence = WorkspacePersistence()

    var body: some View {
        ZStack {
            Color(red: 0.075, green: 0.10, blue: 0.135).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                stage
                bottomBar.frame(maxWidth: 680)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.teal)
        .task { loadWorkspace(); generation.onResult = { data, step in
            replaceDocument(try persistence.saveDocument(data, step: step)); stepURL = persistence.stepURL
        } }
        .onChange(of: generation.error) { _, value in if let value { error = value; generation.error = nil } }
        .onChange(of: selection) { _, _ in saveReview() }
        .onChange(of: prompt) { _, _ in saveReview() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveReview() } }
        .onChange(of: mode) { old, new in
            if new == .draw {
                if drawing.strokeCount > 0, let drawingCamera { viewport.restoreCamera(drawingCamera) }
                else { drawingCamera = viewport.cameraState }
                if drawing.strokeCount == 0 || drawing.referenceImage == nil { drawing.referenceImage = viewport.snapshot() }
            }
            if old == .draw { saveReview() }
        }
        .sheet(isPresented: $showInspector) {
            if let document { TopologyInspector(document: document, selection: $selection) }
        }
        .sheet(isPresented: $showConnection) { connectionSheet }
        .sheet(isPresented: $showActivity) { activitySheet }
        .onOpenURL { url in importFile(url) }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json, .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { importFile(url) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .alert("Couldn’t finish", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Menu {
                Button("New design", systemImage: "plus") { newDesign() }.disabled(generation.pending != nil)
                Button("Open STEP or preview", systemImage: "folder") { showImport = true }.disabled(generation.pending != nil)
                Button("Open sample", systemImage: "cube.transparent") { openSample() }.disabled(generation.pending != nil)
                if let stepURL { ShareLink(item: stepURL) { Label("Export STEP", systemImage: "square.and.arrow.up") } }
            } label: {
                Image(systemName: "square.stack.3d.up").font(.title3).frame(width: 48, height: 48)
            }.glassEffect(.regular.interactive(), in: .circle).accessibilityLabel("Design menu").accessibilityIdentifier("design-menu")
            VStack(alignment: .leading, spacing: 3) {
                Text("NanoCAD").font(.headline)
                Text(document == nil ? "A new dimension for your ideas" : displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.leading, 5)
            Spacer(minLength: 4)
            Button { showActivity = true } label: { Image(systemName: "bubble.left.and.text.bubble.right").font(.body).frame(width: 46, height: 46) }
                .glassEffect(.regular.interactive(), in: .circle).accessibilityLabel("Conversation").accessibilityIdentifier("conversation")
        }.foregroundStyle(.white).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
    }

    private var stage: some View {
        ZStack {
            if let document {
                CADViewport(document: document, mode: mode, selection: $selection, controller: viewport)
                if mode == .draw {
                    DrawingReviewLayer(controller: drawing)
                        .transition(.opacity)
                }
                VStack {
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(.teal).frame(width: 5, height: 5)
                            Text("STEP").fontWeight(.semibold)
                            Text("·  \(document.units)  ·  \(document.parts.count) \(document.parts.count == 1 ? "body" : "bodies")").foregroundStyle(.secondary)
                        }.font(.caption.monospaced()).padding(.horizontal, 12).padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                        Spacer()
                        Button { viewport.fitToModel() } label: { Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left").frame(width: 44, height: 44) }
                            .glassEffect(.regular.interactive(), in: .circle).accessibilityLabel("Fit model").accessibilityIdentifier("fit-model").disabled(mode == .draw)
                    }
                    Spacer()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.title).font(.subheadline.weight(.medium))
                            Text(mode.hint).font(.caption).foregroundStyle(.secondary)
                        }.allowsHitTesting(false)
                        Spacer()
                        Button { showInspector = true } label: {
                            HStack(spacing: 6) { Image(systemName: "square.3.layers.3d"); Text(selection.isEmpty ? "Topology" : "\(selection.count) selected") }
                                .font(.caption.weight(.medium)).padding(.horizontal, 12).frame(height: 44)
                        }.glassEffect(.regular.interactive(), in: .capsule).accessibilityIdentifier("topology")
                    }
                }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 16)
                .allowsHitTesting(true)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "cube.transparent").font(.system(size: 72, weight: .ultraLight)).foregroundStyle(.teal)
                    Text("Give your idea shape.").font(.system(.title, design: .rounded, weight: .semibold))
                    Text("Describe a part. Select its details.\nSketch what comes next.").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Explore a sample") { openSample() }.buttonStyle(.glass).padding(.top, 6)
                }.padding(24)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if document != nil {
                if mode == .draw { DrawingTools(controller: drawing).padding(.horizontal, 12) }
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 2) {
                        ForEach(ViewportMode.allCases) { item in
                            Button {
                                withAnimation(.snappy(duration: 0.2)) { mode = item }
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: item.symbol).font(.system(size: 19, weight: mode == item ? .semibold : .regular))
                                    Text(item.shortTitle).font(.system(size: 10, weight: .medium))
                                }.foregroundStyle(mode == item ? Color.teal : Color.white.opacity(0.72))
                                    .frame(maxWidth: .infinity).frame(height: 54)
                                    .background(mode == item ? Color.teal.opacity(0.13) : .clear, in: .rect(cornerRadius: 20))
                            }.buttonStyle(.plain).accessibilityLabel(item.title).accessibilityIdentifier("mode-\(item.rawValue)")
                                .accessibilityAddTraits(mode == item ? .isSelected : [])
                        }
                    }.padding(5).glassEffect(.regular, in: .rect(cornerRadius: 25))
                }.frame(maxWidth: 360).padding(.horizontal, 26)
            }
            if generation.busy || !generation.status.isEmpty {
                Button { showActivity = true } label: {
                    HStack(spacing: 8) {
                        if generation.busy { ProgressView().controlSize(.small) } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal) }
                        Text(generation.status).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up").font(.caption2)
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                }.buttonStyle(.plain).accessibilityIdentifier("generation-status")
            }
            CADComposer(text: $prompt, selection: $selection,
                        references: document?.promptReferences(selection) ?? [],
                        hasDrawing: drawing.strokeCount > 0, busy: generation.busy, connected: generation.connected,
                        onAttach: { if generation.pending == nil { showImport = true } else { showActivity = true } }, onSend: generate,
                        onStop: stop, onConnect: { showConnection = true })
                .padding(.horizontal, 12)
        }.padding(.bottom, 8).padding(.top, 6)
    }

    private var displayName: String {
        guard let name = document?.name else { return "Untitled" }
        return name.replacingOccurrences(of: ".step", with: "").replacingOccurrences(of: "-", with: " ").capitalized
    }
    private func loadWorkspace() {
        guard document == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
            try? FileManager.default.removeItem(at: persistence.root)
        }
        #endif
        do {
            if let saved = try persistence.loadDocument() { document = saved; stepURL = persistence.stepURL; restoreReview(saved) }
            else if !persistence.hasSavedWorkspace { openSample() }
        } catch { self.error = error.localizedDescription }
        drawing.onChange = { saveReview() }
    }
    private func openSample() {
        guard let jsonURL = Bundle.main.url(forResource: "precision-bracket.cad", withExtension: "json") ?? Bundle.main.url(forResource: "sample", withExtension: "json") else { error = "The bundled sample is missing."; return }
        do {
            let data = try Data(contentsOf: jsonURL)
            let step = Bundle.main.url(forResource: "precision-bracket", withExtension: "step") ?? Bundle.main.url(forResource: "sample", withExtension: "step")
            let doc = try persistence.saveDocument(data, step: try step.map { try Data(contentsOf: $0) })
            replaceDocument(doc)
            stepURL = persistence.stepURL
            generation.status = ""
        } catch { self.error = error.localizedDescription }
    }
    private func replaceDocument(_ value: CADDocument) {
        document = value; selection.removeAll(); drawing.load(nil); drawingCamera = nil; mode = .orbit
        viewport.fitToModel(); saveReview()
    }
    private func restoreReview(_ doc: CADDocument) {
        do {
            guard let review = try persistence.loadReview(for: doc.revision) else { return }
            selection = review.selected.intersection(doc.allReferences)
            drawing.load(review.drawing, image: review.drawingImage); drawingCamera = review.camera; prompt = review.prompt
        } catch { self.error = error.localizedDescription }
    }
    private func saveReview() {
        guard let document else { return }
        do { try persistence.save(SavedReview(revision: document.revision, selected: selection, drawing: drawing.canvas.drawing.dataRepresentation(), camera: drawingCamera, prompt: prompt, drawingImage: drawing.referenceImageData)) }
        catch { self.error = error.localizedDescription }
    }
    private func newDesign() {
        do { try persistence.clear() } catch { self.error = error.localizedDescription; return }
        document = nil; selection.removeAll(); drawing.load(nil); drawingCamera = nil; prompt = ""; stepURL = nil; generation.status = ""
    }
    private func importFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "json" {
                replaceDocument(try persistence.saveDocument(data, step: nil)); stepURL = nil
            } else if ["step", "stp"].contains(url.pathExtension.lowercased()) { importSTEP(data, name: url.lastPathComponent) }
            else { error = "Choose a STEP (.step or .stp) file or a NanoCAD .cad.json preview." }
        } catch { self.error = error.localizedDescription }
    }

    private var connectionSheet: some View {
        ConnectionView(onConnect: { credentials in
            generation.credentials = credentials
            if let (data, name) = pendingImport { pendingImport = nil; importSTEP(data, name: name) }
        }, onDisconnect: { generation.credentials = nil })
    }
    private var activitySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(generation.busy ? "Astra is working" : "Your design conversation", systemImage: "sparkle").font(.headline)
                    if generation.response.isEmpty { Text("Send a prompt to create or refine a model. Selected topology and markup are included with your request.").foregroundStyle(.secondary) }
                    else { Text(generation.response).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    if generation.canResume {
                        if generation.pending?.phase != "failed" || generation.pending?.stopRequested == true {
                            Button(generation.pending?.stopRequested == true ? "Retry stop" : "Resume generation") { generation.resume() }.buttonStyle(.borderedProminent).accessibilityIdentifier("resume-generation")
                        }
                        if generation.pending?.phase == "failed" {
                            Button("Dismiss failed generation") { generation.forgetFailedRun() }
                        }
                    }
                    if generation.pending != nil {
                        Button("Stop generation", role: .destructive) { generation.stop() }
                    }
                }.padding(24)
            }.navigationTitle("Astra").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showActivity = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func generate() {
        guard generation.connected else { showConnection = true; return }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let step = try stepURL.map { try Data(contentsOf: $0) }
            if document != nil && step == nil {
                error = "This preview has no source STEP. Import its STEP file to edit it, or choose New design."; return
            }
            var markup: Data?
            if drawing.strokeCount > 0 {
                if let drawingCamera { viewport.restoreCamera(drawingCamera) }
                if let image = drawing.referenceImage ?? viewport.snapshot() {
                    let composite = drawing.composite(on: image)
                    let ratio = min(1, 720 / max(composite.size.width, composite.size.height))
                    let size = CGSize(width: composite.size.width * ratio, height: composite.size.height * ratio)
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    markup = UIGraphicsImageRenderer(size: size, format: format).image { _ in composite.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.65)
                }
            }
            generation.selectedReferences = selection
            generation.start(prompt: prompt, document: document, step: step, markup: markup)
            if generation.busy { prompt = "" }
        } catch { self.error = error.localizedDescription }
    }
    private func importSTEP(_ data: Data, name: String) {
        guard generation.connected else { pendingImport = (data, name); showConnection = true; return }
        guard data.count <= 600_000, String(data: data, encoding: .utf8)?.contains("ISO-10303-21") == true else {
            error = "Choose a STEP text file smaller than 600 KB. Larger models can be prepared with the included desktop exporter."; return
        }
        generation.selectedReferences = []
        generation.start(prompt: "Open the imported STEP file \(name) for viewing. Preserve its geometry and export the native preview.", document: nil, step: data, importing: true)
    }
    private func stop() { generation.stop() }
}

private extension ViewportMode {
    var title: String {
        switch self { case .orbit: "Explore"; case .face: "Select faces"; case .edge: "Select edges"; case .vertex: "Select points"; case .draw: "Draw on model" }
    }
    var shortTitle: String {
        switch self { case .orbit: "Orbit"; case .face: "Faces"; case .edge: "Edges"; case .vertex: "Points"; case .draw: "Draw" }
    }
    var symbol: String {
        switch self { case .orbit: "rotate.3d"; case .face: "square.on.circle"; case .edge: "line.diagonal"; case .vertex: "circle.dotted"; case .draw: "pencil.tip.crop.circle" }
    }
    var hint: String {
        switch self {
        case .orbit: "Drag to orbit · Pinch to zoom"
        case .face: "Tap a surface to add it to your prompt"
        case .edge: "Tap an edge to refine its shape"
        case .vertex: "Tap a point for a precise reference"
        case .draw: "Sketch an idea with your finger or Pencil"
        }
    }
}
