import SwiftUI

struct TopologyInspector: View {
    let document: CADDocument
    @Binding var selection: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var category = 0
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Topology", selection: $category) {
                        Text("Bodies").tag(0)
                        Text("Faces").tag(1)
                        Text("Edges").tag(2)
                        Text("Points").tag(3)
                    }.pickerStyle(.segmented)
                    LabeledContent("Document", value: document.name)
                    LabeledContent("Units", value: "Millimeters")
                }
                Section {
                    if category == 0 {
                        ForEach(document.parts.filter { matches($0.id, $0.name) }) { part in
                            row(part.id, title: part.name, detail: "\(part.faceIDs.count) faces", symbol: "cube")
                        }
                    } else if category == 1 {
                        ForEach(document.faces.filter { matches($0.id) }) { face in
                            row(face.id, title: "Face \(shortID(face.id))", detail: "\(face.area.formatted(.number.precision(.fractionLength(2)))) mm²", symbol: "square.on.circle")
                        }
                    } else if category == 2 {
                        ForEach(document.edges.filter { matches($0.id) }) { edge in
                            row(edge.id, title: "Edge \(shortID(edge.id))", detail: "\(edge.length.formatted(.number.precision(.fractionLength(2)))) mm", symbol: "line.diagonal")
                        }
                    } else {
                        ForEach(document.vertices.filter { matches($0.id) }) { vertex in
                            row(vertex.id, title: "Point \(shortID(vertex.id))", detail: vertex.position.map { $0.formatted(.number.precision(.fractionLength(1))) }.joined(separator: ", ") + " mm", symbol: "circle.dotted")
                        }
                    }
                } header: { Text("Select geometry to include in your prompt") }
                footer: { Text("References belong to this STEP revision. Generating a new version clears the selection.") }
            }
            .searchable(text: $query, prompt: "Find a reference")
            .navigationTitle("Topology")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Clear") { selection.removeAll() }.disabled(selection.isEmpty) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func matches(_ id: String, _ name: String = "") -> Bool { query.isEmpty || id.localizedCaseInsensitiveContains(query) || name.localizedCaseInsensitiveContains(query) }
    private func shortID(_ id: String) -> String { id.split(separator: ".").last.map(String.init) ?? id }
    private func row(_ id: String, title: String, detail: String, symbol: String) -> some View {
        Button {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(selection.contains(id) ? Color.teal : Color.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary)
                    Text("#\(id) · \(detail)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selection.contains(id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selection.contains(id) ? Color.teal : Color.secondary)
            }.frame(minHeight: 44)
        }.accessibilityIdentifier("topology-\(id)").accessibilityValue(selection.contains(id) ? "Selected" : "Not selected")
    }
}
