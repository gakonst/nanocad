import SwiftUI

struct ProjectsView: View {
    let store: CADProjectStore
    var summary: (CADProject) -> String? = { _ in nil }
    var onSelect: (CADProject) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var renaming: CADProject?
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.projects) { project in
                        Button { select(project) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "cube.transparent").foregroundStyle(.teal)
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
                            }.padding(.vertical, 4)
                        }
                        .accessibilityIdentifier("project-\(project.id)")
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                name = project.name
                                renaming = project
                            }
                        }
                    }
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
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task {
                do { try store.load() } catch { self.error = error.localizedDescription }
            }
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
    }

    private func select(_ project: CADProject) {
        do {
            try store.select(project)
            onSelect(project)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func create() {
        do {
            let project = try store.create()
            onSelect(project)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
