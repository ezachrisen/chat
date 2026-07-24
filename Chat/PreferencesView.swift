import SwiftUI

struct ModelPreferencesView: View {
    @ObservedObject var store: LocalModelStore

    var body: some View {
        Form {
            Section {
                Text("Add each local model server you want to use. The server must provide OpenAI-compatible models and chat completions APIs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Local models") {
                if store.localModels.isEmpty {
                    ContentUnavailableView(
                        "No local models",
                        systemImage: "desktopcomputer",
                        description: Text("Add a model served by tools such as LM Studio, Ollama, or llama.cpp.")
                    )
                } else {
                    ForEach(store.localModels) { model in
                        LocalModelEditor(model: model, store: store)
                    }
                }

                Button {
                    store.addLocalModel()
                } label: {
                    Label("Add local model", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 360)
        .navigationTitle("Models")
    }
}

private struct LocalModelEditor: View {
    let model: LocalModel
    @ObservedObject var store: LocalModelStore
    @State private var bearerToken = ""
    @State private var availableModelIDs: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var discoveryVersion = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Display name", text: name)
                    .textFieldStyle(.roundedBorder)

                Spacer()

                Button(role: .destructive) {
                    store.remove(model)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove local model")
            }

            TextField("Server URL", text: endpoint)
                .textFieldStyle(.roundedBorder)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
#endif

            SecureField("Bearer token (optional)", text: $bearerToken)
                .textFieldStyle(.roundedBorder)
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .onChange(of: bearerToken) {
                    store.updateBearerToken(for: model, to: bearerToken)
                    resetDiscoveredModels()
                }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Picker("Model", selection: modelID) {
                    if model.modelID.isEmpty {
                        Text("Choose a model")
                            .tag("")
                    } else if !availableModelIDs.contains(model.modelID) {
                        Text(model.modelID)
                            .tag(model.modelID)
                    }

                    ForEach(availableModelIDs, id: \.self) { modelID in
                        Text(modelID)
                            .tag(modelID)
                    }
                }
                .pickerStyle(.menu)
                .disabled(availableModelIDs.isEmpty)

                Button {
                    Task {
                        await loadModels()
                    }
                } label: {
                    if isLoadingModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isLoadingModels)
                .help("Refresh models")
            }

            if let modelLoadError {
                Label(modelLoadError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Models are loaded from the server's OpenAI-compatible models API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            bearerToken = store.bearerToken(for: model)
        }
        .task {
            await loadModels()
        }
        .onChange(of: model.endpoint) {
            resetDiscoveredModels()
        }
    }

    private var name: Binding<String> {
        Binding(
            get: { model.name },
            set: { store.updateName(for: model, to: $0) }
        )
    }

    private var endpoint: Binding<String> {
        Binding(
            get: { model.endpoint },
            set: { store.updateEndpoint(for: model, to: $0) }
        )
    }

    private var modelID: Binding<String> {
        Binding(
            get: { model.modelID },
            set: { store.updateModelID(for: model, to: $0) }
        )
    }

    private func resetDiscoveredModels() {
        discoveryVersion = UUID()
        availableModelIDs = []
        modelLoadError = nil
    }

    private func loadModels() async {
        guard !isLoadingModels else { return }

        isLoadingModels = true
        modelLoadError = nil
        defer { isLoadingModels = false }
        let requestedVersion = discoveryVersion

        do {
            let configuration = store.configuration(for: model)
            let modelIDs = try await OpenAICompatibleClient(configuration: configuration).listModels()
            guard requestedVersion == discoveryVersion else { return }
            availableModelIDs = modelIDs

            if model.modelID.isEmpty, let firstModelID = modelIDs.first {
                store.updateModelID(for: model, to: firstModelID)
            }
        } catch {
            guard requestedVersion == discoveryVersion else { return }
            availableModelIDs = []
            modelLoadError = "Couldn't load models: \(error.localizedDescription)"
        }
    }
}
