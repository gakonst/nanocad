import SwiftUI

struct CADComposer: View {
    @Binding var text: String
    @Binding var selection: Set<String>
    var references: [String]
    var hasDrawing: Bool
    var busy: Bool
    var connected: Bool
    var onAttach: () -> Void
    var onSend: () -> Void
    var onStop: () -> Void
    var onConnect: () -> Void
    @State private var focused = false
    @State private var overflow = false
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !references.isEmpty || hasDrawing {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        if hasDrawing { Label("Markup", systemImage: "pencil.tip.crop.circle").foregroundStyle(.orange).padding(.horizontal, 10).padding(.vertical, 6).background(.orange.opacity(0.1), in: .capsule) }
                        ForEach(references, id: \.self) { reference in
                            HStack(spacing: 5) {
                                Image(systemName: "scope")
                                Text(reference.split(separator: "#").last.map { "#" + $0 } ?? reference)
                                Button {
                                    let ref = reference.split(separator: "#").last.map(String.init) ?? reference
                                    selection.remove(ref)
                                } label: { Image(systemName: "xmark").font(.caption2.bold()).padding(5) }
                                .accessibilityLabel("Remove \(reference)")
                            }.foregroundStyle(.teal).padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 3).background(.teal.opacity(0.1), in: .capsule)
                        }
                    }.font(.caption.monospaced()).padding(.horizontal, 12).padding(.top, 10)
                }.scrollIndicators(.hidden).accessibilityIdentifier("reference-chips")
            }
            HStack(alignment: .bottom, spacing: 2) {
                Button { focused = false; onAttach() } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44).contentShape(.rect)
                }.accessibilityLabel("Import STEP or preview").accessibilityIdentifier("import")
                editor
                Button {
                    if busy { onStop() }
                    else { focused = false; onSend() }
                } label: {
                    Image(systemName: busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(busy || canSend ? 1 : 0.18), in: .circle)
                        .frame(width: 44, height: 44).contentShape(.rect)
                }.disabled(!busy && !canSend).accessibilityLabel(busy ? "Stop generation" : "Send to Astra").accessibilityIdentifier("send")
                    .keyboardShortcut(.return, modifiers: .command)
            }.buttonStyle(.plain).padding(.horizontal, 4).padding(.bottom, 4).padding(.top, 4)
            HStack(spacing: 6) {
                Button(action: onConnect) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkle")
                        Text("Astra").fontWeight(.medium)
                        Circle().fill(connected ? Color.teal : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                    }.padding(.vertical, 6).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityLabel(connected ? "Astra connected" : "Connect Astra")
                Spacer()
                if overflow {
                    Button { focused = false; expanded = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 32, height: 30) }.accessibilityLabel("Expand message editor")
                } else { Text("Powered by Nanocodex").foregroundStyle(.tertiary) }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 6)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.primary.opacity(focused ? 0.18 : 0.09)))
        .shadow(color: .black.opacity(0.035), radius: 8, y: 2)
        .sheet(isPresented: $expanded) {
            NavigationStack {
                ChatComposerEditor(text: $text, focused: $focused, overflowing: $overflow, expandsToFill: true).padding()
                    .navigationTitle("Describe your idea").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { expanded = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Send") { expanded = false; focused = false; onSend() }.disabled(!canSend) }
                    }
            }.presentationDetents([.large])
        }
    }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var editor: some View {
        ChatComposerEditor(text: $text, focused: $focused, overflowing: $overflow)
            .accessibilityLabel("Describe a part or an edit").accessibilityIdentifier("composer")
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(selection.isEmpty ? "Describe a part or an edit…" : "What should change here?")
                        .font(.body).foregroundStyle(.tertiary).padding(.top, 8).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}
