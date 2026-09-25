import SwiftUI

/// The compact workspace shows the current update; this sheet retains the
/// conversation and makes the underlying tool activity available on demand.
struct GenerationActivityView: View {
    let generation: GenerationController
    var onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if generation.busy {
                            HStack(alignment: .top, spacing: 10) {
                                ProgressView().controlSize(.small).padding(.top, 3)
                                Text(generation.statusSummary).font(.subheadline)
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("activity-current-update")
                        }
                        if generation.transcript.isEmpty {
                            if generation.response.isEmpty {
                                ContentUnavailableView("Your design conversation", systemImage: "bubble.left.and.text.bubble.right",
                                    description: Text("Your prompts, Astra’s updates, and completed changes appear here."))
                            } else {
                                Text(generation.response).textSelection(.enabled)
                            }
                        }
                        ForEach(generation.transcript) { entry in
                            TranscriptRow(entry: entry).id(entry.id)
                        }
                        if let notice = generation.transcriptNotice {
                            Text(notice).font(.caption).foregroundStyle(.secondary)
                        }
                        controls
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }.padding(20)
                }
                .accessibilityIdentifier("generation-transcript")
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .safeAreaInset(edge: .bottom) {
                    if generation.busy {
                        Button {
                            withAnimation(.snappy) { reader.scrollTo("conversation-bottom", anchor: .bottom) }
                        } label: {
                            Label("Latest activity", systemImage: "arrow.down")
                                .font(.caption.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 10)
                        }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule).padding(.bottom, 8)
                    }
                }
            }
            .navigationTitle("Astra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var controls: some View {
        if generation.canResume {
            if generation.pending?.phase != "failed" || generation.pending?.stopRequested == true {
                Button(generation.pending?.stopRequested == true ? "Retry stop" : "Resume generation") { generation.resume() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("resume-generation")
            }
            if generation.pending?.phase == "failed" {
                Button("Retry generation", action: onRetry)
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("retry-generation")
                Button("Dismiss failed generation") { generation.forgetFailedRun() }
            }
        }
        if generation.pending != nil {
            Button("Stop generation", role: .destructive) { generation.stop() }
        }
    }
}

private struct TranscriptRow: View {
    let entry: GenerationTranscriptEntry
    @State private var expanded = false

    private var isTool: Bool { entry.kind == .toolCall || entry.kind == .toolResult }
    private var symbol: String {
        switch entry.kind {
        case .user: "person.crop.circle"
        case .toolCall: "gearshape"
        case .toolResult: entry.isError ? "exclamationmark.circle" : "checkmark.circle"
        case .error: "exclamationmark.circle"
        case .notice: "info.circle"
        default: "sparkles"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(entry.isError ? Color.orange : entry.kind == .user ? Color.secondary : Color.teal)
                Text(entry.title).fontWeight(.semibold)
                Spacer(minLength: 0)
            }.font(.caption)
            if !entry.text.isEmpty {
                Text(entry.text)
                    .font(isTool ? .callout : .body)
                    .foregroundStyle(isTool ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let details = entry.details, !details.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    ScrollView(.horizontal) {
                        Text(details).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 8)
                } label: {
                    Text(entry.toolName.map { "Details · \($0)" } ?? "Details").font(.caption)
                }.tint(.secondary)
            }
        }
        .padding(isTool ? 12 : 0)
        .background(isTool ? Color.secondary.opacity(0.07) : .clear, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}
