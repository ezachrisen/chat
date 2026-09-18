import SwiftUI
import SwiftData
import ShadSwift

/// One place to see what Chat can access. Connecting and revoking happen on
/// each service's tab in Settings → Tools; selecting a name goes there.
struct AppleServicesPreferencesView: View {
    @ObservedObject var navigation: PreferencesNavigation
    @ObservedObject private var connections = AppleServiceConnections.shared
    @ObservedObject private var calendar = CalendarDirectory.shared
    @Environment(\.shadTheme) private var theme

    private static let services: [AppleServiceID] = [.reminders, .notes, .messages, .mail, .contacts, .phone]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                ShadSettingsPageHeader(
                    title: "Apple Services",
                    description: "What Chat can access on this Mac. Select a service to connect it or revoke access in Settings → Tools."
                )
                VStack(spacing: 0) {
                    row("Calendar", isConnected: calendar.hasFullAccess, tab: .calendar)
                    ForEach(Self.services) { service in
                        ShadSeparator()
                        row(service.title, isConnected: connections.connectedServices.contains(service), tab: .tab(for: service))
                    }
                }
                .shadSettingsCard()
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
        .background(theme.colors.background)
        .onAppear {
            connections.refresh()
            calendar.refresh()
        }
    }

    private func row(_ title: String, isConnected: Bool, tab: ToolPreferencesTab) -> some View {
        HStack(spacing: 12) {
            Button { navigation.showTools(tab) } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(theme.font(theme.typography.sm, theme.typography.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.colors.mutedForeground)
                }
                .foregroundStyle(theme.colors.foreground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            .help("Open \(title) in Settings → Tools")
            .accessibilityLabel("Open \(title) settings")
            Spacer()
            AppleServiceStatusChip(isConnected: isConnected)
        }
        .padding(16)
    }
}

/// Green "Connected" or neutral "Not connected" capsule.
struct AppleServiceStatusChip: View {
    let isConnected: Bool

    var body: some View {
        Label(isConnected ? "Connected" : "Not connected", systemImage: isConnected ? "checkmark.circle.fill" : "circle.dashed")
            .chatSystemFont(.caption1, weight: .semibold)
            .foregroundStyle(isConnected ? Color.green : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((isConnected ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
    }
}

/// One service's connection state: the green chip when connected, Connect otherwise,
/// and Revoke access to stop Chat from using the service.
struct AppleServiceConnectionRow: View {
    let service: AppleServiceID
    @ObservedObject private var connections = AppleServiceConnections.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(service.title).chatSystemFont(.headline, weight: .semibold)
                Text(connections.statuses[service] ?? "Not connected").chatSystemFont(.caption1).foregroundStyle(.secondary)
            }
            Spacer()
            if connections.busy.contains(service) { ProgressView().controlSize(.small) }
            if connections.connectedServices.contains(service) {
                AppleServiceStatusChip(isConnected: true)
                ShadButton("Revoke access", variant: .outline, size: .sm) {
                    connections.revoke(service)
                    AppleServiceRuntime.shared.revokeInFlight()
                }
                .accessibilityLabel("Revoke \(service.title) access")
            } else {
                ShadButton("Connect", variant: .outline, size: .sm) {
                    Task { await connections.connect(service) }
                }
                .disabled(connections.busy.contains(service))
                .accessibilityLabel("Connect \(service.title)")
            }
        }
    }
}

/// Connection card shown under a service's tab in Settings → Tools.
struct AppleServiceConnectionView: View {
    let service: AppleServiceID
    @ObservedObject private var connections = AppleServiceConnections.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppleServiceConnectionRow(service: service)
            Text("Connect this Mac, then choose what each agent can access in its Tools settings. Retrieved content may be sent to that agent's selected model and included in saved replies.")
                .chatSystemFont(.callout)
                .foregroundStyle(.secondary)
            Text(revokeNote)
                .chatSystemFont(.caption1)
                .foregroundStyle(.secondary)
            if service == .messages {
                Text("Messages history is separate from sending. To read local history, enable Full Disk Access for Chat, restart Chat, and enable History for the agent. Rich message content may be unavailable.")
                    .chatSystemFont(.caption1)
                    .foregroundStyle(.secondary)
            }
            if service == .notes {
                Text("Notes with rich formatting are protected from replacement.").chatSystemFont(.caption1).foregroundStyle(.secondary)
            }
            if service == .mail || service == .messages {
                Text("\(service.title) accepts files deliberately imported for the agent; other attachments remain in the Apple app.").chatSystemFont(.caption1).foregroundStyle(.secondary)
            }
            Text("With an agent's Debug log on, saved diagnostics include \(service.title) requests and the bounded results returned to that agent; with it off, they omit request and result content.")
                .chatSystemFont(.caption1)
                .foregroundStyle(.secondary)
            if service == .phone {
                Text("Phone opens the system calling app. Call history, call control and agent voice calls are unavailable.").chatSystemFont(.caption1).foregroundStyle(.secondary)
            }
            HStack {
                if let pane = privacyPane {
                    ShadButton("Open \(pane.title) settings", variant: .outline, size: .sm) { openPrivacy(pane.anchor) }
                }
                if service == .messages {
                    ShadButton("Open Full Disk Access settings", variant: .outline, size: .sm) { openPrivacy("Privacy_AllFiles") }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { connections.refresh() }
    }

    /// The macOS privacy pane that holds this service's permission. Phone needs none.
    private var privacyPane: (title: String, anchor: String)? {
        switch service {
        case .reminders: ("Reminders", "Privacy_Reminders")
        case .contacts: ("Contacts", "Privacy_Contacts")
        case .notes, .mail, .messages: ("Automation", "Privacy_Automation")
        case .phone: nil
        }
    }

    private var revokeNote: String {
        let note = "Revoke access stops every agent from using \(service.title) right away."
        guard let pane = privacyPane else { return note }
        return note + " To also remove the macOS permission, turn off Chat in System Settings → Privacy & Security → \(pane.title)."
    }
}

private func openPrivacy(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
}

struct AgentAppleServicesView: View {
    let agent: Agent
    let service: AppleServiceID
    @ObservedObject private var actions = AppleActionStore.shared
    @State private var resources: [AppleServiceRecord] = []
    @State private var status: String?
    @State private var loading = false
    @State private var nextOffset: Int?
    @State private var sendingText = ""
    @State private var identitiesText = ""
    @State private var importedFiles: [AppleAttachment] = []
    private var grant: AppleServiceGrant { agent.appleServiceGrants[service.rawValue] ?? AppleServiceGrant() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Allow \(service.title)", isOn: binding(\.enabled))
            if grant.enabled {
                if service != .phone {
                    Toggle("Read all \(service.scopeLabel.lowercased())", isOn: binding(\.allowsAll))
                    HStack {
                        Text(grant.allowsAll ? "Includes newly added resources." : "Choose the resources this agent may use.").chatSystemFont(.caption1).foregroundStyle(.secondary)
                        Spacer()
                        Button(loading ? "Loading…" : "Choose \(service.scopeLabel.lowercased())") { Task { await loadResources(append: false) } }.disabled(loading)
                    }
                    ForEach(resources) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Toggle(item.title.isEmpty ? (item.fields["participants"] ?? "Untitled") : item.title, isOn: resourceBinding(item.id)).disabled(grant.allowsAll)
                                if let source = item.fields["account_name"] ?? item.fields["parent"] { Text(source).chatSystemFont(.caption1).foregroundStyle(.secondary) }
                            }
                            if service == .messages {
                                Toggle("Allow sending", isOn: destinationBinding(item.id)).toggleStyle(.checkbox)
                            }
                        }
                    }
                    if nextOffset != nil { Button("Load more") { Task { await loadResources(append: true) } }.disabled(loading) }
                    if !grant.allowsAll, resources.isEmpty { Text("\(grant.resourceIDs.count) service resources.").chatSystemFont(.caption1) }
                }
                if [.reminders, .contacts, .notes, .mail].contains(service) {
                    Toggle("Allow changes", isOn: binding(\.allowsChanges))
                }
                if service == .reminders { Toggle("Allow deleting reminders", isOn: binding(\.allowsDeletion)) }
                Toggle("Allow scheduled use", isOn: binding(\.allowsBackground))
                Toggle("Allow use when another agent asks", isOn: binding(\.allowsDelegation))
                if service == .messages { Toggle("Read local message history (requires Full Disk Access)", isOn: binding(\.allowsHistory)) }
                if service == .phone || service == .mail || service == .messages {
                    Text(service == .phone ? "Numbers this agent may call without another approval" : "Addresses or numbers this agent may message without another approval").chatSystemFont(.caption1)
                    TextField(service == .phone ? "+14155550123, one per line" : "person@example.com, one per line", text: $sendingText, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder)
                    Button("Save destinations") { saveDestinations() }
                }
                if service == .mail {
                    Text("Allowed sending addresses (one per line)").chatSystemFont(.caption1)
                    TextField("Your address as configured in Mail", text: $identitiesText, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                    Button("Save sending addresses") { saveIdentities() }
                }
                if service == .mail || service == .messages {
                    Text("Files available to this agent (24 hours)").chatSystemFont(.caption1)
                    Button("Choose a file…") { importAttachment() }
                    ForEach(importedFiles) { file in
                        HStack {
                            Text(file.name).chatSystemFont(.caption1)
                            Spacer()
                            Button("Remove") {
                                do { try AppleAttachmentStore.shared.remove(file.id, agentID: agent.id); refreshFiles() }
                                catch { status = error.localizedDescription }
                            }
                        }
                    }
                }
                Text("Sending or calling outside a saved destination grant produces an action for review below. Edits require the Changes grant; deleting requires its own grant.").chatSystemFont(.caption1).foregroundStyle(.secondary)
            }
            if let status { Text(status).chatSystemFont(.caption1).textSelection(.enabled) }
            Divider()
            Text("Prepared actions and recent receipts").chatSystemFont(.headline, weight: .semibold)
            ForEach(actions.actions.filter { $0.agentID == agent.id && $0.service == service }.suffix(20).reversed()) { action in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(action.service.title) · \(action.state)").font(.subheadline.bold())
                    Text(action.summary).chatSystemFont(.callout).textSelection(.enabled)
                    if action.state == "prepared" {
                        HStack {
                            Button(action.service == .phone ? "Open call" : "Send this exact message") { Task { await approve(action) } }
                            Button("Cancel") { do { try actions.cancel(action.id, agentID: agent.id) } catch { status = error.localizedDescription } }
                        }
                    }
                    if action.state == "uncertain" { Text("Check the Apple app before trying again. This action will not be repeated automatically.").chatSystemFont(.caption1) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }.padding(16)
            .onAppear { refreshText(); refreshFiles() }
    }
    private func refreshFiles() { importedFiles = AppleAttachmentStore.shared.list(agentID: agent.id) }
    private func importAttachment() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                _ = try AppleAttachmentStore.shared.importFile(url, agentID: agent.id)
                refreshFiles(); status = "File imported for this agent."
            } catch { status = error.localizedDescription }
        }
    }
    private func binding(_ keyPath: WritableKeyPath<AppleServiceGrant, Bool>) -> Binding<Bool> {
        Binding(get: { grant[keyPath: keyPath] }, set: { value in var edited = grant; edited[keyPath: keyPath] = value; save(edited) })
    }
    private func resourceBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { grant.resourceIDs.contains(id) }, set: { value in var edited = grant; if value { edited.resourceIDs.insert(id) } else { edited.resourceIDs.remove(id) }; save(edited) })
    }
    private func destinationBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { grant.sendDestinations.contains(id) }, set: { value in var edited = grant; if value { edited.sendDestinations.insert(id) } else { edited.sendDestinations.remove(id) }; save(edited) })
    }
    private func save(_ grant: AppleServiceGrant) {
        agent.setAppleServiceGrant(service, grant: grant)
        do { try agent.modelContext?.save() } catch { status = "Could not save: \(error.localizedDescription)" }
    }
    private func refreshText() {
        sendingText = grant.sendDestinations.filter { service != .messages || $0.hasPrefix("+") || $0.contains("@") }.sorted().joined(separator: "\n")
        identitiesText = grant.sendingIdentities.sorted().joined(separator: "\n")
    }
    private func saveDestinations() {
        do {
            var edited = grant
            let endpoints = Set(try sendingText.split(separator: "\n").map { try AppleServiceValidation.endpoint(String($0)) })
            let conversations = service == .messages ? grant.sendDestinations.filter { !$0.hasPrefix("+") && !$0.contains("@") } : []
            edited.sendDestinations = endpoints.union(conversations)
            save(edited); status = "Destinations saved."
        } catch { status = error.localizedDescription }
    }
    private func saveIdentities() {
        do {
            var edited = grant
            edited.sendingIdentities = Set(try identitiesText.split(separator: "\n").map { raw in
                let address = try AppleServiceValidation.endpoint(String(raw))
                guard address.contains("@") else { throw AppleServiceError.invalid("Use email addresses.") }
                return address
            })
            save(edited); status = "Sending addresses saved."
        } catch { status = error.localizedDescription }
    }
    private func loadResources(append: Bool) async {
        loading = true
        defer { loading = false }
        do {
            var directoryGrant = AppleServiceGrant()
            directoryGrant.enabled = true; directoryGrant.allowsAll = true
            let action: String = switch service { case .reminders: "lists"; case .contacts: "containers"; case .notes: "folders"; case .mail: "mailboxes"; case .messages: "chats"; case .phone: "prepare" }
            let request = AppleServiceRequest(action: action, limit: 100, offset: append ? nextOffset : 0)
            let result: AppleServiceResult
            try AppleServiceConnections.shared.checkNotRevoked(service)
            if [.reminders, .contacts].contains(service) {
                result = try await NativeAppleServices.shared.execute(service, request, grant: directoryGrant, fence: AppleServiceFence())
            } else {
                try await AppleServiceConnections.shared.ensure(service)
                result = try await ScriptableAppleServices.shared.execute(service, request, grant: directoryGrant, fence: AppleServiceFence())
            }
            let combined = (append ? resources : []) + result.records
            resources = Array(Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values).sorted { $0.title < $1.title }
            nextOffset = result.nextOffset
            status = result.coverage
        } catch { status = error.localizedDescription }
    }
    private func approve(_ action: ApplePreparedAction) async {
        do {
            let request = AppleServiceRequest(action: action.service == .phone ? "call" : "send", actionID: action.id)
            let result = try await AppleServiceRuntime.shared.execute(action.service, request, context: AppleServiceRuntime.context(agent: agent, origin: .interactive), approved: true)
            status = result.message ?? result.status
        } catch { status = error.localizedDescription }
    }
}

struct AppleServiceActionBanner: View {
    let agents: [Agent]
    @ObservedObject private var store = AppleActionStore.shared
    @State private var reviewing: ApplePreparedAction?
    @State private var resultMessage: String?
    private var pending: [ApplePreparedAction] {
        store.actions.filter { $0.state == "prepared" }
            .filter { action in agents.contains { $0.id == action.agentID } }
    }
    var body: some View {
        Group {
            if let action = pending.first {
                HStack {
                    Text("\(action.service.title) action ready to review").chatSystemFont(.callout)
                    Spacer()
                    Button("Review") { reviewing = action }
                }.padding(10).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let resultMessage { Text(resultMessage).chatSystemFont(.caption1).textSelection(.enabled) }
        }.sheet(item: $reviewing) { action in
            VStack(alignment: .leading, spacing: 16) {
                Text(action.service == .phone ? "Review call" : "Review message").chatSystemFont(.title2, weight: .bold)
                Text("Prepared by " + (agents.first { $0.id == action.agentID }?.displayName ?? "Agent")).chatSystemFont(.caption1).foregroundStyle(.secondary)
                ScrollView { Text(action.summary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                HStack {
                    Button("Cancel action") { try? store.cancel(action.id, agentID: action.agentID); reviewing = nil }
                    Spacer()
                    Button(action.service == .phone ? "Open call" : "Send") {
                        guard let agent = agents.first(where: { $0.id == action.agentID }) else { return }
                        reviewing = nil
                        Task {
                            do {
                                let request = AppleServiceRequest(action: action.service == .phone ? "call" : "send", actionID: action.id)
                                let result = try await AppleServiceRuntime.shared.execute(action.service, request, context: AppleServiceRuntime.context(agent: agent, origin: .interactive), approved: true)
                                resultMessage = result.message ?? result.status
                            } catch { resultMessage = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 560, height: 420)
        }
    }
}
