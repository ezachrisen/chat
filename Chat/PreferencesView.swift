import Combine
import SwiftUI
import SwiftData

#if os(macOS)
import AppKit
#endif

enum PreferencesSection: String, CaseIterable, Identifiable {
    case agents
    case models
    case skills
    case textToSpeech

    var id: Self { self }

    var title: String {
        switch self {
        case .agents:
            return "Agents"
        case .models:
            return "Models"
        case .skills:
            return "Skills"
        case .textToSpeech:
            return "Text to Speech"
        }
    }

    var systemImage: String {
        switch self {
        case .agents:
            return "person.2"
        case .models:
            return "cpu"
        case .skills:
            return "book"
        case .textToSpeech:
            return "waveform"
        }
    }
}

@MainActor
final class PreferencesNavigation: ObservableObject {
    @Published var selection: PreferencesSection = .agents
}

enum OpenUITheme {
    static let background = Color(red: 1, green: 1, blue: 1)
    static let foreground = Color(red: 26 / 255, green: 28 / 255, blue: 31 / 255)
    static let foregroundMuted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
    static let foregroundSubtle = Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255)
    static let accent = Color(red: 51 / 255, green: 156 / 255, blue: 1)
    static let accentSoft = accent.opacity(0.15)
    static let surface = Color.white
    static let sidebar = Color(red: 247 / 255, green: 247 / 255, blue: 248 / 255)
    static let surfaceActive = Color(red: 236 / 255, green: 236 / 255, blue: 236 / 255)
    static let surfaceMuted = Color(red: 243 / 255, green: 244 / 255, blue: 246 / 255)
    static let border = Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255)
    static let borderSubtle = Color(red: 239 / 255, green: 239 / 255, blue: 239 / 255)
    static let primary = foreground
    static let danger = Color(red: 225 / 255, green: 29 / 255, blue: 72 / 255)
    static let warningBackground = Color(red: 254 / 255, green: 243 / 255, blue: 226 / 255)
    static let warningForeground = Color(red: 146 / 255, green: 64 / 255, blue: 14 / 255)
    static let warningBorder = Color(red: 245 / 255, green: 217 / 255, blue: 168 / 255)
}

struct PreferencesView: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject var skillCatalog: SkillCatalog
    @ObservedObject var replyFilterStore: ReplyFilterStore
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var navigation: PreferencesNavigation

    var body: some View {
        HStack(spacing: 0) {
            OpenUIPreferencesSidebar(selection: $navigation.selection)

            Group {
                switch navigation.selection {
                case .agents:
                    AgentsPreferencesView(
                        store: agentStore,
                        localModelStore: localModelStore,
                        textToSpeechToolStore: textToSpeechToolStore,
                        skillCatalog: skillCatalog,
                        chatStore: chatStore
                    )
                case .models:
                    ModelPreferencesView(store: localModelStore, replyFilterStore: replyFilterStore)
                case .skills:
                    SkillPreferencesView(catalog: skillCatalog)
                case .textToSpeech:
                    TextToSpeechPreferencesView(store: textToSpeechToolStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OpenUITheme.background)
        }
        .tint(OpenUITheme.accent)
        .foregroundStyle(OpenUITheme.foreground)
        .frame(
            minWidth: 940,
            idealWidth: 1_080,
            maxWidth: .infinity,
            minHeight: 640,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .preferredColorScheme(.light)
#if os(macOS)
        .background(
            PreferencesWindowConfigurator()
                .frame(width: 0, height: 0)
        )
#endif
    }
}

#if os(macOS)
private struct PreferencesWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window,
                  context.coordinator.configuredWindow !== window else {
                return
            }

            context.coordinator.configuredWindow = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.resizable)
            window.minSize = NSSize(width: 940, height: 640)

            guard let visibleFrame = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
                return
            }

            let size = NSSize(
                width: floor(visibleFrame.width * 2 / 3),
                height: floor(visibleFrame.height * 2 / 3)
            )
            let origin = NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            )
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    final class Coordinator {
        weak var configuredWindow: NSWindow?
    }
}
#endif

private struct OpenUIPreferencesSidebar: View {
    @Binding var selection: PreferencesSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OpenUITheme.foreground)
                .padding(.horizontal, 12)

            Text("SETTINGS")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(OpenUITheme.foregroundSubtle)
                .padding(.top, 28)
                .padding(.bottom, 8)
                .padding(.horizontal, 12)

            VStack(spacing: 4) {
                ForEach(PreferencesSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.systemImage)
                                .font(.system(size: 16, weight: .regular))
                                .frame(width: 20)

                            Text(section.title)
                                .font(.system(size: 14, weight: selection == section ? .medium : .regular))

                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(OpenUITheme.foreground)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                        .background(
                            selection == section ? OpenUITheme.surfaceActive : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
            }

            Spacer()

            Text("Local-first conversations")
                .font(.system(size: 12))
                .foregroundStyle(OpenUITheme.foregroundSubtle)
                .padding(.horizontal, 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 24)
        .frame(width: 224)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(OpenUITheme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(OpenUITheme.borderSubtle)
                .frame(width: 1)
        }
    }
}

struct OpenUIPageHeader: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(OpenUITheme.foreground)

            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(OpenUITheme.foregroundMuted)
        }
    }
}

struct OpenUISectionHeader: View {
    let title: String
    var description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OpenUITheme.foreground)

            if let description {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(OpenUITheme.foregroundMuted)
            }
        }
    }
}

struct OpenUISettingsRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder let control: () -> Control

    init(
        title: String,
        description: String,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.description = description
        self.control = control
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                labels
                    .frame(width: 240, alignment: .leading)

                Spacer(minLength: 0)

                control()
            }

            VStack(alignment: .leading, spacing: 10) {
                labels

                control()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OpenUITheme.foreground)

            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(OpenUITheme.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OpenUIDivider: View {
    var body: some View {
        Rectangle()
            .fill(OpenUITheme.borderSubtle)
            .frame(height: 1)
    }
}

struct OpenUICardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(OpenUITheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(OpenUITheme.border, lineWidth: 1)
            }
    }
}

extension View {
    func openUICard() -> some View {
        modifier(OpenUICardModifier())
    }

    func openUIInput() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(OpenUITheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(OpenUITheme.border, lineWidth: 1)
            }
    }
}

struct OpenUIPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(OpenUITheme.primary, in: Capsule())
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}

struct OpenUISecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(OpenUITheme.foreground)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(OpenUITheme.surface, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(OpenUITheme.border, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.68 : 1)
    }
}

struct OpenUIDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(OpenUITheme.danger)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(OpenUITheme.surface, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(OpenUITheme.border, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.68 : 1)
    }
}

struct ModelPreferencesView: View {
    @ObservedObject var store: LocalModelStore
    @ObservedObject var replyFilterStore: ReplyFilterStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .top, spacing: 24) {
                    OpenUIPageHeader(
                        title: "Models",
                        description: "Configure local servers and the reply filters that strip hidden control text from each model."
                    )

                    Spacer()

                    Button {
                        store.addLocalModel()
                    } label: {
                        Label("Add model", systemImage: "plus")
                    }
                    .buttonStyle(OpenUIPrimaryButtonStyle())
                }

                AppleFoundationModelEditor(replyFilterStore: replyFilterStore)

                if store.localModels.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(OpenUITheme.accent)

                        Text("No local models")
                            .font(.system(size: 15, weight: .semibold))

                        Text("Add a model served by LM Studio, Ollama, llama.cpp, or another OpenAI-compatible server.")
                            .font(.system(size: 13))
                            .foregroundStyle(OpenUITheme.foregroundMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .openUICard()
                } else {
                    VStack(spacing: 16) {
                        ForEach(store.localModels) { model in
                            LocalModelEditor(
                                model: model,
                                store: store,
                                replyFilterStore: replyFilterStore
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
        .background(OpenUITheme.background)
    }
}

struct TextToSpeechPreferencesView: View {
    @ObservedObject var store: TextToSpeechToolStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .top, spacing: 24) {
                    OpenUIPageHeader(
                        title: "Text to Speech",
                        description: "Configure command-line tools that can turn text into speech."
                    )

                    Spacer()

                    Button {
                        store.addTool()
                    } label: {
                        Label("Add tool", systemImage: "plus")
                    }
                    .buttonStyle(OpenUIPrimaryButtonStyle())
                }

                if store.tools.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(OpenUITheme.accent)

                        Text("No text-to-speech tools")
                            .font(.system(size: 15, weight: .semibold))

                        Text("Add a command-line tool to make it available for text-to-speech features.")
                            .font(.system(size: 13))
                            .foregroundStyle(OpenUITheme.foregroundMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .openUICard()
                } else {
                    VStack(spacing: 16) {
                        ForEach(store.tools) { tool in
                            TextToSpeechToolEditor(tool: tool, store: store)
                        }
                    }
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
        .background(OpenUITheme.background)
    }
}

private struct TextToSpeechToolEditor: View {
    let tool: TextToSpeechTool
    @ObservedObject var store: TextToSpeechToolStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OpenUITheme.accent)
                    .frame(width: 34, height: 34)
                    .background(OpenUITheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OpenUITheme.foreground)

                    Text(tool.path.isEmpty ? "Enter a CLI path to finish setup" : tool.path)
                        .font(.system(size: 12))
                        .foregroundStyle(OpenUITheme.foregroundSubtle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button(role: .destructive) {
                    store.remove(tool)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(OpenUIDangerButtonStyle())
            }
            .padding(16)

            OpenUIDivider()

            OpenUISettingsRow(
                title: "Name",
                description: "The name used to identify this text-to-speech tool."
            ) {
                TextField("Text-to-speech tool", text: name)
                    .openUIInput()
                    .frame(width: 330)
            }

            OpenUIDivider()

            OpenUISettingsRow(
                title: "CLI path",
                description: "Absolute path to the command-line executable."
            ) {
                TextField("/path/to/text-to-speech-cli", text: path)
                    .openUIInput()
                    .frame(width: 330)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
            }
        }
        .openUICard()
    }

    private var name: Binding<String> {
        Binding(
            get: { tool.name },
            set: { store.updateName(for: tool, to: $0) }
        )
    }

    private var path: Binding<String> {
        Binding(
            get: { tool.path },
            set: { store.updatePath(for: tool, to: $0) }
        )
    }
}

private struct AppleFoundationModelEditor: View {
    @ObservedObject var replyFilterStore: ReplyFilterStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "applelogo")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OpenUITheme.accent)
                    .frame(width: 34, height: 34)
                    .background(OpenUITheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Foundation Model")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OpenUITheme.foreground)

                    Text("On-device Apple Intelligence")
                        .font(.system(size: 12))
                        .foregroundStyle(OpenUITheme.foregroundSubtle)
                }

                Spacer()
            }
            .padding(16)

            OpenUIDivider()

            ReplyFilterPatternsEditor(
                modelIdentifier: ChatModelIdentifier.appleFoundation,
                store: replyFilterStore
            )
        }
        .openUICard()
    }
}

private struct ReplyFilterPatternsEditor: View {
    let modelIdentifier: String
    @ObservedObject var store: ReplyFilterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Reply filters")
                .font(.system(size: 14, weight: .medium))

            Text("One regular expression per line. Matches are removed from the visible reply. Lines starting with # are ignored.")
                .font(.system(size: 13))
                .foregroundStyle(OpenUITheme.foregroundMuted)

            TextEditor(text: patternsText)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 92, maxHeight: 160)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(OpenUITheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(OpenUITheme.border, lineWidth: 1)
                }
        }
        .padding(16)
    }

    private var patternsText: Binding<String> {
        Binding(
            get: { store.patternsText(for: modelIdentifier) },
            set: { store.updatePatternsText(for: modelIdentifier, text: $0) }
        )
    }
}

private struct LocalModelEditor: View {
    let model: LocalModel
    @ObservedObject var store: LocalModelStore
    @ObservedObject var replyFilterStore: ReplyFilterStore
    @State private var bearerToken = ""
    @State private var availableModelIDs: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var discoveryVersion = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OpenUITheme.accent)
                    .frame(width: 34, height: 34)
                    .background(OpenUITheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OpenUITheme.foreground)

                    Text(model.modelID.isEmpty ? "Choose a server model to finish setup" : model.modelID)
                        .font(.system(size: 12))
                        .foregroundStyle(OpenUITheme.foregroundSubtle)
                        .lineLimit(1)
                }

                Spacer()

                Button(role: .destructive) {
                    store.remove(model)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(OpenUIDangerButtonStyle())
            }
            .padding(16)

            OpenUIDivider()

            OpenUISettingsRow(
                title: "Display name",
                description: "The name shown in agent model menus."
            ) {
                TextField("Local model", text: name)
                    .openUIInput()
                    .frame(width: 330)
            }

            OpenUIDivider()

            OpenUISettingsRow(
                title: "Server URL",
                description: "Base URL for the OpenAI-compatible API."
            ) {
                TextField("http://127.0.0.1:1234/v1", text: endpoint)
                    .openUIInput()
                    .frame(width: 330)
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
#endif
            }

            OpenUIDivider()

            OpenUISettingsRow(
                title: "Bearer token",
                description: "Optional credential stored in the system keychain."
            ) {
                SecureField("Optional", text: $bearerToken)
                    .openUIInput()
                    .frame(width: 330)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .onChange(of: bearerToken) {
                        store.updateBearerToken(for: model, to: bearerToken)
                        resetDiscoveredModels()
                    }
            }

            OpenUIDivider()

            OpenUISettingsRow(
                title: "Server model",
                description: "Loaded from the server's models API."
            ) {
                HStack(spacing: 8) {
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
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 270)
                    .disabled(availableModelIDs.isEmpty)

                    Button {
                        Task {
                            await loadModels()
                        }
                    } label: {
                        if isLoadingModels {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 16, height: 16)
                        }
                    }
                    .buttonStyle(OpenUISecondaryButtonStyle())
                    .disabled(isLoadingModels)
                    .help("Refresh models")
                }
            }

            if let modelLoadError {
                OpenUIDivider()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")

                    Text(modelLoadError)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(OpenUITheme.warningForeground)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(OpenUITheme.warningBackground)
                .overlay {
                    Rectangle()
                        .stroke(OpenUITheme.warningBorder, lineWidth: 1)
                }
            }

            OpenUIDivider()

            ReplyFilterPatternsEditor(
                modelIdentifier: ChatModelIdentifier.localModelID(model.id),
                store: replyFilterStore
            )
        }
        .openUICard()
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

#Preview("Preferences") {
    PreferencesViewPreview()
}

private struct PreferencesViewPreview: View {
    private let modelContainer: ModelContainer
    private let agentStore: AgentStore
    private let localModelStore: LocalModelStore
    private let textToSpeechToolStore: TextToSpeechToolStore
    private let skillCatalog: SkillCatalog
    private let replyFilterStore: ReplyFilterStore
    private let chatStore: ChatStore
    private let navigation = PreferencesNavigation()

    init() {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(
                for: Agent.self,
                AgentHeartbeat.self,
                HeartbeatRun.self,
                LocalModel.self,
                ReplyFilterSet.self,
                TextToSpeechTool.self,
                StoredChat.self,
                StoredGroupChatParticipant.self,
                StoredChatMessage.self,
                configurations: configuration
            )
            let context = container.mainContext
            let localModel = LocalModel(
                name: "Studio Qwen",
                endpoint: "http://127.0.0.1:1234/v1",
                modelID: "qwen3-8b"
            )
            context.insert(localModel)

            for name in ["Joe", "Maya", "Rowan", "Sam"] {
                context.insert(
                    Agent(
                        name: name,
                        soul: "Be a thoughtful participant in the conversation.",
                        modelIdentifier: ChatModelIdentifier.localModelID(localModel.id)
                    )
                )
            }
            try context.save()

            let agentStore = AgentStore(modelContext: context)
            let localModelStore = LocalModelStore(modelContext: context)
            let textToSpeechToolStore = TextToSpeechToolStore(modelContext: context)
            let skillCatalog = SkillCatalog()
            let replyFilterStore = ReplyFilterStore(modelContext: context)
            modelContainer = container
            self.agentStore = agentStore
            self.localModelStore = localModelStore
            self.textToSpeechToolStore = textToSpeechToolStore
            self.skillCatalog = skillCatalog
            self.replyFilterStore = replyFilterStore
            chatStore = ChatStore(
                agentStore: agentStore,
                localModelStore: localModelStore,
                skillCatalog: skillCatalog,
                replyFilterStore: replyFilterStore,
                modelContext: context
            )
        } catch {
            fatalError("Failed to create Preferences preview: \(error.localizedDescription)")
        }
    }

    var body: some View {
        PreferencesView(
            agentStore: agentStore,
            localModelStore: localModelStore,
            textToSpeechToolStore: textToSpeechToolStore,
            skillCatalog: skillCatalog,
            replyFilterStore: replyFilterStore,
            chatStore: chatStore,
            navigation: navigation
        )
        .modelContainer(modelContainer)
    }
}
