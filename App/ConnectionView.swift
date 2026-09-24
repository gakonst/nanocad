import SwiftUI

struct ConnectionView: View {
    var onConnect: (NanocodexCredentials) -> Void
    var onDisconnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var origin = "https://nanocodex.xyz"
    @State private var apiKey = ""
    @State private var connecting = false
    @State private var hasConnection = false
    @State private var error: String?
    @State private var connectionTask: Task<Void, Never>?

    init(onConnect: @escaping (NanocodexCredentials) -> Void = { _ in }, onDisconnect: @escaping () -> Void = {}) {
        self.onConnect = onConnect; self.onDisconnect = onDisconnect
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.primary)
                        Text("Create with Astra").font(.title2.bold())
                        Text("Connect your Nanocodex account to create and refine CAD models. Your account runs Astra and generates the STEP and preview files.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                if hasConnection {
                    Section {
                        Label("Astra is connected", systemImage: "checkmark.circle.fill").foregroundStyle(.teal)
                        Button("Disconnect this device", role: .destructive) {
                            do { try ConnectionCredentials.remove(); hasConnection = false; onDisconnect(); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
                Section {
                    SecureField("Account API key", text: $apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("nanocodex-api-key")
                    Link("Open Nanocodex account", destination: URL(string: "https://nanocodex.xyz")!)
                } header: { Text("Nanocodex connection") } footer: {
                    Text("Use an account API key from Nanocodex settings. It is saved only in this device’s Keychain. NanoCAD never includes a shared API key.")
                }
                Section("Server") {
                    TextField("HTTPS origin", text: $origin)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("nanocodex-origin")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("connection-error") }
                }
                Section {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            if connecting { ProgressView().padding(.trailing, 8) }
                            Text(connecting ? "Connecting…" : "Connect account").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(connecting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("connect-account")
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { connectionTask?.cancel(); dismiss() } }
            }
            .task {
                if let saved = try? ConnectionCredentials.load() { origin = saved.origin; hasConnection = true }
            }
            .onDisappear { connectionTask?.cancel(); apiKey = "" }
        }
    }

    private func connect() {
        error = nil; connecting = true
        connectionTask = Task { @MainActor in
            defer { connecting = false }
            do {
                let credentials = try NanocodexCredentials(origin: origin, apiKey: apiKey)
                let client = NanocodexClient(credentials: credentials)
                defer { client.close() }
                try await client.validateConnection()
                try Task.checkCancellation()
                try ConnectionCredentials.save(credentials)
                apiKey = ""
                onConnect(credentials)
                dismiss()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
