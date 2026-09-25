import SwiftUI

struct ConnectionView: View {
    var onConnect: (NanocodexCredentials) -> Void
    var onDisconnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var origin = "https://nanocodex.gakonst.workers.dev"
    @State private var apiKey = ""
    @State private var connecting = false
    @State private var savedConnection: NanocodexCredentials?
    @State private var error: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var authorization = ConnectAuthorization()

    init(onConnect: @escaping (NanocodexCredentials) -> Void = { _ in }, onDisconnect: @escaping () -> Void = {}) {
        self.onConnect = onConnect; self.onDisconnect = onDisconnect
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(.teal)
                        Text("Create with Astra").font(.title2.bold())
                        Text("Bring your ideas to life with your Nanocodex account. Approve NanoCAD once, then prompt, select, and refine.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }
                if let savedConnection {
                    Section {
                        Label(savedConnection.connect == nil ? "Account connected" : "Nanocodex Connect is ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.teal)
                        if let grant = savedConnection.connect, grant.sandboxExecution != true {
                            Button("Enable CAD creation", action: connectWithNanocodex)
                                .disabled(connecting).accessibilityIdentifier("upgrade-cad-connection")
                            Text("Approve an isolated Cloudflare sandbox so Astra can build real CAD geometry.")
                                .foregroundStyle(.secondary)
                        }
                        Button("Disconnect", role: .destructive, action: disconnect)
                            .disabled(connecting).accessibilityIdentifier("disconnect-account")
                    } footer: {
                        Text(savedConnection.connect == nil ? "Your account key is saved in this device’s Keychain." : "Disconnect revokes NanoCAD’s approval and removes the connection from this device.")
                    }
                } else {
                    Section {
                        Button { connectWithNanocodex() } label: {
                            HStack(spacing: 10) {
                                Spacer()
                                if connecting { ProgressView() }
                                else { Image(systemName: "sparkles") }
                                Text(connecting ? "Connecting…" : "Connect with Nanocodex").fontWeight(.semibold)
                                Spacer()
                            }.padding(.vertical, 8)
                        }
                        .disabled(connecting)
                        .accessibilityIdentifier("connect-nanocodex")
                    } footer: {
                        Text("A secure sign-in sheet opens for your approval. NanoCAD receives access to its own CAD conversation and model files.")
                    }
                    Section {
                        Label("Create and refine with Astra", systemImage: "cube.transparent")
                        Label("Use your selected geometry and drawings", systemImage: "pencil.tip.crop.circle")
                        Label("Keep NanoCAD open while creating", systemImage: "iphone")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("connection-error") }
                }
                Section {
                    DisclosureGroup("Advanced connection") {
                        SecureField("Account API key", text: $apiKey)
                            .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("nanocodex-api-key")
                        TextField("HTTPS origin", text: $origin)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("nanocodex-origin")
                        Button("Connect account key", action: connectWithKey)
                            .disabled(connecting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("connect-account")
                    }
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { connectionTask?.cancel(); authorization.cancel(); dismiss() }
                }
            }
            .task {
                if let saved = try? ConnectionCredentials.load() { origin = saved.origin; savedConnection = saved }
            }
            .onDisappear { connectionTask?.cancel(); authorization.cancel(); apiKey = "" }
        }
    }

    private func connectWithNanocodex() {
        runConnection { try await authorization.connect() }
    }

    private func connectWithKey() {
        runConnection { try NanocodexCredentials(origin: origin, apiKey: apiKey) }
    }

    private func runConnection(_ credentials: @escaping @MainActor () async throws -> NanocodexCredentials) {
        error = nil; connecting = true
        connectionTask = Task { @MainActor in
            defer { connecting = false }
            do {
                let value = try await credentials()
                let client = NanocodexClient(credentials: value)
                defer { client.close() }
                try await client.validateConnection()
                try Task.checkCancellation()
                try ConnectionCredentials.save(value)
                apiKey = ""
                onConnect(value)
                dismiss()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func disconnect() {
        guard let savedConnection else { return }
        error = nil; connecting = true
        connectionTask = Task { @MainActor in
            defer { connecting = false }
            do {
                let client = NanocodexClient(credentials: savedConnection)
                defer { client.close() }
                do { try await client.revokeConnection() }
                catch NanocodexError.http(let status) where status == 401 || status == 404 { /* already inactive */ }
                try ConnectionCredentials.remove()
                self.savedConnection = nil; onDisconnect(); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
