import Combine
import ShadSwift
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

    var icon: ShadIcon {
        switch self {
        case .agents:
            return .users
        case .models:
            return .custom("cpu")
        case .skills:
            return .custom("book")
        case .textToSpeech:
            return .custom("waveform")
        }
    }
}

@MainActor
final class PreferencesNavigation: ObservableObject {
    @Published var selection: PreferencesSection = .agents
}

struct PreferencesView: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject var skillCatalog: SkillCatalog
    @ObservedObject var replyFilterStore: ReplyFilterStore
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var heartbeatScheduler: HeartbeatScheduler
    @ObservedObject var navigation: PreferencesNavigation
    @StateObject private var sidebar = ShadSidebarState(isOpen: true, width: 224, iconWidth: 48)

    var body: some View {
        ShadSidebarProvider(state: sidebar) {
            ShadPreferencesSidebar(selection: $navigation.selection)

            ShadSidebarInset {
                switch navigation.selection {
                case .agents:
                    AgentsPreferencesView(
                        store: agentStore,
                        localModelStore: localModelStore,
                        textToSpeechToolStore: textToSpeechToolStore,
                        skillCatalog: skillCatalog,
                        chatStore: chatStore,
                        heartbeatScheduler: heartbeatScheduler
                    )
                case .models:
                    ModelPreferencesView(store: localModelStore, replyFilterStore: replyFilterStore)
                case .skills:
                    SkillPreferencesView(catalog: skillCatalog)
                case .textToSpeech:
                    TextToSpeechPreferencesView(store: textToSpeechToolStore)
                }
            }
        }
        .frame(
            minWidth: 940,
            idealWidth: 1_080,
            maxWidth: .infinity,
            minHeight: 640,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .shadTheme(ChatShadTheme.theme)
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

private struct ShadPreferencesSidebar: View {
    @Binding var selection: PreferencesSection
    @Environment(\.shadTheme) private var theme

    var body: some View {
        ShadSidebar(collapsible: .none) {
            ShadSidebarHeader {
                Text("Chat")
                    .font(theme.font(theme.typography.lg, theme.typography.semibold))
                    .foregroundStyle(theme.colors.sidebarForeground)
                    .padding(theme.spacing.md)
            }

            ShadSidebarContent {
                ShadSidebarGroup("SETTINGS") {
                    ShadSidebarMenu {
                        ForEach(PreferencesSection.allCases) { section in
                            ShadSidebarMenuItem {
                                ShadSidebarMenuButton(
                                    section.title,
                                    icon: section.icon,
                                    isActive: selection == section
                                ) {
                                    selection = section
                                }
                                .accessibilityAddTraits(selection == section ? .isSelected : [])
                            }
                        }
                    }
                }
            }

            ShadSidebarFooter {
                Text("Local-first conversations")
                    .font(theme.font(theme.typography.xs))
                    .foregroundStyle(theme.colors.sidebarForeground.opacity(0.6))
                    .padding(theme.spacing.md)
            }
        }
    }
}

struct ShadSettingsPageHeader: View {
    let title: String
    let description: String
    @Environment(\.shadTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            Text(title)
                .font(theme.font(theme.typography.xxl, theme.typography.semibold))
                .foregroundStyle(theme.colors.foreground)

            Text(description)
                .font(theme.font(theme.typography.sm))
                .foregroundStyle(theme.colors.mutedForeground)
        }
    }
}

struct ShadSettingsSectionHeader: View {
    let title: String
    var description: String?
    @Environment(\.shadTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            Text(title)
                .font(theme.font(theme.typography.base, theme.typography.semibold))
                .foregroundStyle(theme.colors.foreground)

            if let description {
                Text(description)
                    .font(theme.font(theme.typography.sm))
                    .foregroundStyle(theme.colors.mutedForeground)
            }
        }
    }
}

struct ShadSettingsRow<Control: View>: View {
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
        ShadItem(size: .sm) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var labels: some View {
        ShadItemContent {
            ShadItemTitle(title)
            ShadItemDescription(description)
        }
    }
}

extension View {
    func shadSettingsCard() -> some View {
        ShadCard(spacing: 0) {
            self
        }
    }
}

struct ModelPreferencesView: View {
    @ObservedObject var store: LocalModelStore
    @ObservedObject var replyFilterStore: ReplyFilterStore
    @Environment(\.shadTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .top, spacing: 24) {
                    ShadSettingsPageHeader(
                        title: "Models",
                        description: "Use an on-device model, your ChatGPT subscription, or an OpenAI-compatible local server."
                    )

                    Spacer()

                    ShadButton("Add model", icon: .plus) {
                        store.addLocalModel()
                    }
                }

                AppleFoundationModelEditor(replyFilterStore: replyFilterStore)

                ChatGPTSubscriptionModelEditor(store: store)

                if store.localModels.isEmpty {
                    VStack(spacing: 12) {
                        ShadIconView(.custom("desktopcomputer"), size: theme.typography.xxl)
                            .foregroundStyle(theme.colors.primary)

                        Text("No local models")
                            .font(theme.font(theme.typography.base, theme.typography.semibold))

                        Text("Add a model served by LM Studio, Ollama, llama.cpp, or another OpenAI-compatible server.")
                            .font(theme.font(theme.typography.sm))
                            .foregroundStyle(theme.colors.mutedForeground)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .shadSettingsCard()
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
        .background(theme.colors.background)
    }
}

struct TextToSpeechPreferencesView: View {
    @ObservedObject var store: TextToSpeechToolStore
    @Environment(\.shadTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .top, spacing: 24) {
                    ShadSettingsPageHeader(
                        title: "Text to Speech",
                        description: "Configure command-line tools that can turn text into speech."
                    )

                    Spacer()

                    ShadButton("Add tool", icon: .plus) {
                        store.addTool()
                    }
                }

                if store.tools.isEmpty {
                    VStack(spacing: 12) {
                        ShadBlueIconTile(systemName: "waveform")

                        Text("No text-to-speech tools")
                            .font(theme.font(theme.typography.base, theme.typography.semibold))

                        Text("Add a command-line tool to make it available for text-to-speech features.")
                            .font(theme.font(theme.typography.sm))
                            .foregroundStyle(theme.colors.mutedForeground)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .shadSettingsCard()
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
        .background(theme.colors.background)
    }
}

private struct TextToSpeechToolEditor: View {
    let tool: TextToSpeechTool
    @ObservedObject var store: TextToSpeechToolStore
    @Environment(\.shadTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ShadBlueIconTile(systemName: "waveform")

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.displayName)
                        .font(theme.font(theme.typography.base, theme.typography.semibold))
                        .foregroundStyle(theme.colors.foreground)

                    Text(tool.path.isEmpty ? "Enter a CLI path to finish setup" : tool.path)
                        .font(theme.font(theme.typography.xs))
                        .foregroundStyle(theme.colors.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                ShadButton("Remove", variant: .destructive, size: .sm, icon: .trash) {
                    store.remove(tool)
                }
            }
            .padding(16)

            ShadSeparator()

            ShadSettingsRow(
                title: "Name",
                description: "The name used to identify this text-to-speech tool."
            ) {
                ShadInput("Text-to-speech tool", text: name)
                    .frame(width: 330)
                    .accessibilityLabel("Tool name")
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "CLI path",
                description: "Absolute path to the command-line executable."
            ) {
                ShadInput("/path/to/text-to-speech-cli", text: path)
                    .frame(width: 330)
                    .accessibilityLabel("CLI path")
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
            }
        }
        .shadSettingsCard()
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

private struct ChatGPTSubscriptionModelEditor: View {
    @ObservedObject var store: LocalModelStore
    @Environment(\.shadTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ShadBlueIconTile(systemName: "bubble.left.and.bubble.right")

                VStack(alignment: .leading, spacing: 2) {
                    Text("ChatGPT subscription")
                        .font(theme.font(theme.typography.base, theme.typography.semibold))
                        .foregroundStyle(theme.colors.foreground)

                    Text(statusText)
                        .font(theme.font(theme.typography.xs))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                        .accessibilityIdentifier("chatgpt-provider-status")
                }

                Spacer()

                actionButton
            }
            .padding(16)

            ShadSeparator()

            ShadSettingsRow(
                title: "Subscription access",
                description: "Uses Codex-managed ChatGPT sign-in and your plan limits. Chat never reads or stores your account tokens."
            ) {
                Text(accountSummary)
                    .font(theme.font(theme.typography.sm, theme.typography.medium))
                    .foregroundStyle(theme.colors.foreground)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 330, alignment: .trailing)
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "Available models",
                description: "Fetched from the models enabled for your ChatGPT account. Choose one in an agent's Identity settings."
            ) {
                Text(modelSummary)
                    .font(theme.font(theme.typography.sm))
                    .foregroundStyle(theme.colors.mutedForeground)
                    .frame(width: 330, alignment: .trailing)
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "Codex executable",
                description: "Leave blank to find Codex in the ChatGPT app or your PATH. Set an absolute path to override discovery."
            ) {
                HStack(spacing: 8) {
                    ShadInput(
                        "Automatic",
                        text: executablePath,
                        onSubmit: refresh
                    )
                    .frame(width: 270)
                    .accessibilityLabel("Codex executable path")
                    .disabled(store.chatGPTConnectionState.isBusy)

                    ShadButton(
                        icon: .refresh,
                        variant: .outline,
                        size: .icon,
                        accessibilityLabel: "Refresh ChatGPT connection",
                        isLoading: store.chatGPTConnectionState.isBusy
                    ) {
                        refresh()
                    }
                    .disabled(store.chatGPTConnectionState.isBusy)
                }
            }

            if let issueText {
                ShadSeparator()

                ShadItem(variant: .muted, size: .sm) {
                    ShadIconView(.triangleAlert, size: theme.typography.base)
                        .foregroundStyle(theme.colors.warning)
                    ShadItemContent {
                        Text(issueText)
                            .font(theme.font(theme.typography.sm))
                            .foregroundStyle(theme.colors.warning)
                    }
                }
                .accessibilityIdentifier("chatgpt-provider-error")
            }
        }
        .shadSettingsCard()
        .task {
            await store.refreshChatGPT()
        }
        .accessibilityIdentifier("chatgpt-provider-card")
    }

    @ViewBuilder
    private var actionButton: some View {
        switch store.chatGPTConnectionState {
        case .connected:
            ShadButton(
                "Refresh",
                variant: .outline,
                size: .sm,
                icon: .refresh,
                isLoading: store.chatGPTConnectionState.isBusy
            ) {
                refresh()
            }
            .disabled(store.chatGPTConnectionState.isBusy)
            .accessibilityIdentifier("chatgpt-provider-refresh")
        case .checking:
            ShadButton("Checking", variant: .outline, size: .sm, isLoading: true) {}
                .disabled(true)
        case .connecting:
            ShadButton("Connecting", variant: .outline, size: .sm, isLoading: true) {}
                .disabled(true)
        default:
            ShadButton("Connect ChatGPT", size: .sm) {
                Task {
                    await store.connectChatGPT()
                }
            }
            .accessibilityIdentifier("chatgpt-provider-connect")
        }
    }

    private var executablePath: Binding<String> {
        Binding(
            get: { store.configuredCodexExecutablePath },
            set: { store.updateCodexExecutablePath($0) }
        )
    }

    private var statusText: String {
        switch store.chatGPTConnectionState {
        case .idle:
            return "Ready to check your Codex sign-in"
        case .checking:
            return "Checking your ChatGPT account…"
        case .signedOut:
            return "Not connected"
        case .connecting:
            return "Finish signing in in your browser…"
        case .connected(let account):
            return account.email.map { "Connected as \($0)" } ?? "Connected"
        case .unavailable:
            return "Codex is unavailable"
        case .failed:
            return "Connection needs attention"
        }
    }

    private var statusColor: Color {
        switch store.chatGPTConnectionState {
        case .connected:
            return theme.colors.success
        case .unavailable, .failed:
            return theme.colors.warning
        default:
            return theme.colors.mutedForeground
        }
    }

    private var accountSummary: String {
        switch store.chatGPTConnectionState {
        case .connected(let account):
            return account.planType.map(prettyPlanName) ?? "ChatGPT"
        case .signedOut:
            return "Sign in required"
        default:
            return "—"
        }
    }

    private var modelSummary: String {
        guard !store.chatGPTModels.isEmpty else {
            return "Connect to load models"
        }
        let count = store.chatGPTModels.count
        return "\(count) \(count == 1 ? "model" : "models")"
    }

    private var issueText: String? {
        switch store.chatGPTConnectionState {
        case .unavailable(let message), .failed(let message):
            return message
        default:
            return nil
        }
    }

    private func prettyPlanName(_ plan: String) -> String {
        plan
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + String($0.dropFirst()) }
            .joined(separator: " ")
    }

    private func refresh() {
        Task {
            await store.refreshChatGPT()
        }
    }
}

private struct AppleFoundationModelEditor: View {
    @ObservedObject var replyFilterStore: ReplyFilterStore
    @Environment(\.shadTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ShadBlueIconTile(systemName: "applelogo")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Foundation Model")
                        .font(theme.font(theme.typography.base, theme.typography.semibold))
                        .foregroundStyle(theme.colors.foreground)

                    Text("On-device Apple Intelligence · \(ConversationCompaction.contextWindow(for: .appleFoundation)) token context")
                        .font(theme.font(theme.typography.xs))
                        .foregroundStyle(theme.colors.mutedForeground)
                }

                Spacer()
            }
            .padding(16)

            ShadSeparator()

            ReplyFilterPatternsEditor(
                modelIdentifier: ChatModelIdentifier.appleFoundation,
                store: replyFilterStore
            )
        }
        .shadSettingsCard()
    }
}

private struct ReplyFilterPatternsEditor: View {
    let modelIdentifier: String
    @ObservedObject var store: ReplyFilterStore

    var body: some View {
        ShadField {
            ShadFieldLabel("Reply filters")
            ShadFieldDescription(
                "One regular expression per line. Matches are removed from the visible reply. Lines starting with # are ignored."
            )

            ShadTextarea("One regular expression per line", text: patternsText, minHeight: 92, maxHeight: 160)
                .accessibilityLabel("Reply filters")
                .shadTheme { fieldTheme in
                    fieldTheme.typography.fontName = fieldTheme.typography.monoFontName
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
    @State private var contextTokenLimitText = ""
    @Environment(\.shadTheme) private var theme

    init(
        model: LocalModel,
        store: LocalModelStore,
        replyFilterStore: ReplyFilterStore
    ) {
        self.model = model
        _store = ObservedObject(wrappedValue: store)
        _replyFilterStore = ObservedObject(wrappedValue: replyFilterStore)
        _contextTokenLimitText = State(initialValue: String(model.resolvedContextTokenLimit))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ShadBlueIconTile(systemName: "cpu")

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(theme.font(theme.typography.base, theme.typography.semibold))
                        .foregroundStyle(theme.colors.foreground)

                    Text(model.modelID.isEmpty ? "Choose a server model to finish setup" : model.modelID)
                        .font(theme.font(theme.typography.xs))
                        .foregroundStyle(theme.colors.mutedForeground)
                        .lineLimit(1)
                }

                Spacer()

                ShadButton("Remove", variant: .destructive, size: .sm, icon: .trash) {
                    store.remove(model)
                }
            }
            .padding(16)

            ShadSeparator()

            ShadSettingsRow(
                title: "Display name",
                description: "The name shown in agent model menus."
            ) {
                ShadInput("Local model", text: name)
                    .frame(width: 330)
                    .accessibilityLabel("Display name")
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "Server URL",
                description: "Base URL for the OpenAI-compatible API."
            ) {
                ShadInput("http://127.0.0.1:1234/v1", text: endpoint)
                    .frame(width: 330)
                    .accessibilityLabel("Server URL")
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
#endif
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "Bearer token",
                description: "Optional credential stored in the system keychain."
            ) {
                ShadInput("Optional", text: $bearerToken, isSecure: true)
                    .frame(width: 330)
                    .accessibilityLabel("Bearer token")
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .onChange(of: bearerToken) {
                        store.updateBearerToken(for: model, to: bearerToken)
                        resetDiscoveredModels()
                    }
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "Server model",
                description: "Loaded from the server's models API."
            ) {
                HStack(spacing: 8) {
                    ShadSelect(
                        selection: optionalModelID,
                        options: serverModelOptions,
                        placeholder: "Choose a model",
                        width: 270
                    )
                    .disabled(availableModelIDs.isEmpty)
                    .accessibilityLabel("Server model")
                    .accessibilityValue(model.modelID.isEmpty ? "No model selected" : model.modelID)

                    ShadButton(
                        icon: .refresh,
                        variant: .outline,
                        size: .icon,
                        accessibilityLabel: "Refresh models",
                        isLoading: isLoadingModels
                    ) {
                        Task {
                            await loadModels()
                        }
                    }
                    .disabled(isLoadingModels)
                    .help("Refresh models")
                }
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "Context window",
                description: "Token limit of the loaded model. Chat uses this to summarize older history. Default 8192 if unset."
            ) {
                ShadField(isInvalid: contextTokenLimitError != nil, spacing: theme.spacing.xs) {
                    ShadInput(
                        "8192",
                        text: $contextTokenLimitText,
                        isInvalid: contextTokenLimitError != nil,
                        onSubmit: normalizeContextTokenLimit
                    )
                    .accessibilityLabel("Context window")
                    .onChange(of: contextTokenLimitText) {
                        updateContextTokenLimitIfValid()
                    }

                    ShadFieldError(contextTokenLimitError)
                }
                .frame(width: 240)
            }

            if let modelLoadError {
                ShadSeparator()

                ShadItem(variant: .muted, size: .sm) {
                    ShadIconView(.triangleAlert, size: theme.typography.base)
                        .foregroundStyle(theme.colors.warning)
                    ShadItemContent {
                        Text(modelLoadError)
                            .font(theme.font(theme.typography.sm))
                            .foregroundStyle(theme.colors.warning)
                    }
                }
            }

            ShadSeparator()

            ReplyFilterPatternsEditor(
                modelIdentifier: ChatModelIdentifier.localModelID(model.id),
                store: replyFilterStore
            )
        }
        .shadSettingsCard()
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

    private var optionalModelID: Binding<String?> {
        Binding(
            get: { model.modelID.isEmpty ? nil : model.modelID },
            set: { value in
                guard let value else { return }
                modelID.wrappedValue = value
            }
        )
    }

    private var serverModelOptions: [ShadSelectOption<String>] {
        var identifiers = availableModelIDs
        if !model.modelID.isEmpty, !identifiers.contains(model.modelID) {
            identifiers.insert(model.modelID, at: 0)
        }
        return identifiers.map { ShadSelectOption($0, value: $0) }
    }

    private var contextTokenLimitError: String? {
        guard let value = Int(contextTokenLimitText) else {
            return "Enter a whole number."
        }
        guard (ConversationCompaction.minimumContextTokens...ConversationCompaction.maximumContextTokens).contains(value) else {
            return "Enter \(ConversationCompaction.minimumContextTokens)...\(ConversationCompaction.maximumContextTokens)."
        }
        return nil
    }

    private func updateContextTokenLimitIfValid() {
        guard contextTokenLimitError == nil, let value = Int(contextTokenLimitText) else { return }
        store.updateContextTokenLimit(for: model, to: value)
    }

    private func normalizeContextTokenLimit() {
        updateContextTokenLimitIfValid()
        contextTokenLimitText = String(model.resolvedContextTokenLimit)
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
    private let heartbeatScheduler: HeartbeatScheduler
    private let navigation = PreferencesNavigation()

    init() {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ChatModelContainer.make(configuration: configuration)
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
            heartbeatScheduler = HeartbeatScheduler(agentStore: agentStore, chatStore: chatStore)
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
            heartbeatScheduler: heartbeatScheduler,
            navigation: navigation
        )
        .modelContainer(modelContainer)
    }
}
