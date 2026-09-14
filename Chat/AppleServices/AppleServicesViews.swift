import SwiftUI
import SwiftData
import ShadSwift

struct AppleServicesPreferencesView: View {
    @ObservedObject private var connections = AppleServiceConnections.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Apple Services").chatSystemFont(.title2, weight: .bold)
                Text("Connect this Mac, then choose what each agent can access in its Tools settings. Retrieved content may be sent to that agent's selected model and included in saved replies.").foregroundStyle(.secondary)
                ForEach(AppleServiceID.allCases) { service in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(service.title).chatSystemFont(.headline, weight: .semibold)
                            Text(connections.statuses[service] ?? "Not connected").chatSystemFont(.caption1).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connections.busy.contains(service) { ProgressView().controlSize(.small) }
                        if connections.connectedServices.contains(service) {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .chatSystemFont(.caption1, weight: .semibold)
                                .foregroundStyle(.green)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.green.opacity(0.12), in: Capsule())
                        } else {
                            Button("Connect") { Task { await connections.connect(service) } }.disabled(connections.busy.contains(service))
                        }
                    }
                    Divider()
                }
                Text("Messages history is separate from sending. To read local history, enable Full Disk Access for Chat, restart Chat, and enable History for the agent. Rich message content may be unavailable.").chatSystemFont(.callout).foregroundStyle(.secondary)
                Button("Open Full Disk Access settings") { openPrivacy("Privacy_AllFiles") }
                Button("Open Automation settings") { openPrivacy("Privacy_Automation") }
                Text("Debug logging remains available per agent when Apple Services are enabled. When it is on, saved diagnostics include Apple service requests and the bounded results returned to that agent. When it is off, native-service tool rows omit request and result content.").chatSystemFont(.caption1).foregroundStyle(.secondary)
                Text("Phone opens the system calling app. Call history, call control and agent voice calls are unavailable. Notes with rich formatting are protected from replacement; Mail and Messages accept files deliberately imported for the agent; other attachments remain in the Apple apps.").chatSystemFont(.caption1).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 850, alignment: .leading)
        }.onAppear { connections.refresh() }
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}

struct AgentAppleServicesView: View {
    let agent: Agent
    @ObservedObject private var actions = AppleActionStore.shared
    @State private var selected: AppleServiceID = .reminders
    @State private var resources: [AppleServiceRecord] = []
    @State private var status: String?
    @State private var loading = false
    @State private var nextOffset: Int?
    @State private var sendingText = ""
    @State private var identitiesText = ""
    @State private var importedFiles: [AppleAttachment] = []
    private var grant: AppleServiceGrant { agent.appleServiceGrants[selected.rawValue] ?? AppleServiceGrant() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Service", selection: $selected) {
                ForEach(AppleServiceID.allCases) { service in Text(service.title).tag(service) }
            }.pickerStyle(.segmented)
            Toggle("Allow \(selected.title)", isOn: binding(\.enabled))
            if grant.enabled {
                if selected != .phone {
                    Toggle("Read all \(selected.scopeLabel.lowercased())", isOn: binding(\.allowsAll))
                    HStack {
                        Text(grant.allowsAll ? "Includes newly added resources." : "Choose the resources this agent may use.").chatSystemFont(.caption1).foregroundStyle(.secondary)
                        Spacer()
                        Button(loading ? "Loading…" : "Choose \(selected.scopeLabel.lowercased())") { Task { await loadResources(append: false) } }.disabled(loading)
                    }
                    ForEach(resources) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Toggle(item.title.isEmpty ? (item.fields["participants"] ?? "Untitled") : item.title, isOn: resourceBinding(item.id)).disabled(grant.allowsAll)
                                if let source = item.fields["account_name"] ?? item.fields["parent"] { Text(source).chatSystemFont(.caption1).foregroundStyle(.secondary) }
                            }
                            if selected == .messages {
                                Toggle("Allow sending", isOn: destinationBinding(item.id)).toggleStyle(.checkbox)
                            }
                        }
                    }
                    if nextOffset != nil { Button("Load more") { Task { await loadResources(append: true) } }.disabled(loading) }
                    if !grant.allowsAll, resources.isEmpty { Text("\(grant.resourceIDs.count) selected resources.").chatSystemFont(.caption1) }
                }
                if [.reminders, .contacts, .notes, .mail].contains(selected) {
                    Toggle("Allow changes", isOn: binding(\.allowsChanges))
                }
                if selected == .reminders { Toggle("Allow deleting reminders", isOn: binding(\.allowsDeletion)) }
                Toggle("Allow scheduled use", isOn: binding(\.allowsBackground))
                Toggle("Allow use when another agent asks", isOn: binding(\.allowsDelegation))
                if selected == .messages { Toggle("Read local message history (requires Full Disk Access)", isOn: binding(\.allowsHistory)) }
                if selected == .phone || selected == .mail || selected == .messages {
                    Text(selected == .phone ? "Numbers this agent may call without another approval" : "Addresses or numbers this agent may message without another approval").chatSystemFont(.caption1)
                    TextField(selected == .phone ? "+14155550123, one per line" : "person@example.com, one per line", text: $sendingText, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder)
                    Button("Save destinations") { saveDestinations() }
                }
                if selected == .mail {
                    Text("Allowed sending addresses (one per line)").chatSystemFont(.caption1)
                    TextField("Your address as configured in Mail", text: $identitiesText, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                    Button("Save sending addresses") { saveIdentities() }
                }
                if selected == .mail || selected == .messages {
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
            ForEach(actions.actions.filter { $0.agentID == agent.id }.suffix(20).reversed()) { action in
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
            .onChange(of: selected) { _, _ in resources = []; nextOffset = nil; status = nil; refreshText() }
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
        agent.setAppleServiceGrant(selected, grant: grant)
        do { try agent.modelContext?.save() } catch { status = "Could not save: \(error.localizedDescription)" }
    }
    private func refreshText() {
        sendingText = grant.sendDestinations.filter { selected != .messages || $0.hasPrefix("+") || $0.contains("@") }.sorted().joined(separator: "\n")
        identitiesText = grant.sendingIdentities.sorted().joined(separator: "\n")
    }
    private func saveDestinations() {
        do {
            var edited = grant
            let endpoints = Set(try sendingText.split(separator: "\n").map { try AppleServiceValidation.endpoint(String($0)) })
            let conversations = selected == .messages ? grant.sendDestinations.filter { !$0.hasPrefix("+") && !$0.contains("@") } : []
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
        let service = selected
        loading = true
        defer { loading = false }
        do {
            var directoryGrant = AppleServiceGrant()
            directoryGrant.enabled = true; directoryGrant.allowsAll = true
            let action: String = switch service { case .reminders: "lists"; case .contacts: "containers"; case .notes: "folders"; case .mail: "mailboxes"; case .messages: "chats"; case .phone: "prepare" }
            let request = AppleServiceRequest(action: action, limit: 100, offset: append ? nextOffset : 0)
            let result: AppleServiceResult
            if [.reminders, .contacts].contains(service) {
                result = try await NativeAppleServices.shared.execute(service, request, grant: directoryGrant, fence: AppleServiceFence())
            } else {
                try await AppleServiceConnections.shared.ensure(service)
                result = try await ScriptableAppleServices.shared.execute(service, request, grant: directoryGrant, fence: AppleServiceFence())
            }
            guard selected == service else { return }
            let combined = (append ? resources : []) + result.records
            resources = Array(Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values).sorted { $0.title < $1.title }
            nextOffset = result.nextOffset
            status = result.coverage
        } catch { if selected == service { status = error.localizedDescription } }
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
