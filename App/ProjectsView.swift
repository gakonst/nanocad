import SwiftUI

struct ProjectsView: View {
    let store: CADProjectStore
    var summary: (CADProject) -> String? = { _ in nil }
    var onSelect: (CADProject) -> Void
    var compact = false
    var onClose: () -> Void = {}
    @State private var error: String?
    @State private var renaming: CADProject?
    @State private var name = ""
    @State private var search = ""
    @State private var thumbnailRefresh = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NanoCAD").font(.title2.bold())
                    Text("Projects").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if compact {
                    Button(action: onClose) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                        .accessibilityLabel("Close projects").accessibilityIdentifier("close-projects")
                }
            }.padding(20)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search projects", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("project-search")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search").accessibilityIdentifier("clear-project-search")
                }
            }.padding(12).background(.white.opacity(0.06), in: .rect(cornerRadius: 12)).padding(.horizontal, 16)
            List {
                Section {
                    ForEach(store.projects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { project in
                        HStack(spacing: 12) {
                                ProjectThumbnailView(root: store.root(for: project), refresh: thumbnailRefresh)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.name).foregroundStyle(.primary)
                                    if let status = summary(project) {
                                        Text(status).font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text(project.createdAt, format: .dateTime.month().day().year())
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if project.id == store.activeID {
                                    Image(systemName: "checkmark").foregroundStyle(.teal)
                                        .accessibilityLabel("Current project")
                                }
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        // A tap recognizer fails on movement. A native row Button
                        // can activate when the parent's simultaneous swipe ends.
                        .onTapGesture { select(project) }
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(project.id == store.activeID ? [.isSelected] : [])
                        .accessibilityLabel(project.name)
                        .accessibilityAction { select(project) }
                        .listRowBackground(project.id == store.activeID ? Color.teal.opacity(0.13) : Color.clear)
                        .accessibilityIdentifier("project-\(project.id)")
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                name = project.name
                                renaming = project
                            }
                        }
                    }
                }
                if !search.isEmpty && !store.projects.contains(where: { $0.name.localizedCaseInsensitiveContains(search) }) {
                    Text("No matching projects").foregroundStyle(.secondary)
                        .accessibilityIdentifier("project-search-empty")
                        .listRowBackground(Color.clear)
                }
                Section {
                    Button { create() } label: { Label("New Project", systemImage: "plus") }
                        .accessibilityIdentifier("new-project")
                } footer: {
                    Text("Each project keeps its own model, conversation, and Nanocodex connection.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("projects-error") }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("projects-sidebar")
            .task {
                do { try store.load() } catch { self.error = error.localizedDescription }
            }
            .onReceive(NotificationCenter.default.publisher(for: .nanocadDocumentSaved)) { _ in thumbnailRefresh += 1 }
            .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Project name", text: $name)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    guard let project = renaming else { return }
                    do { try store.rename(project, to: name) } catch { self.error = error.localizedDescription }
                    renaming = nil
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { if compact { onClose() } }
    }

    private func select(_ project: CADProject) {
        do {
            try store.select(project)
            onSelect(project)
        } catch { self.error = error.localizedDescription }
    }

    private func create() {
        do {
            let project = try store.create()
            onSelect(project)
        } catch { self.error = error.localizedDescription }
    }
}
