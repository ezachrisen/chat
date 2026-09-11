import ShadSwift
import SwiftData
import SwiftUI

struct AgentStashEditor: View {
    let agent: Agent
    @Query private var entries: [AgentStashEntry]
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.shadTheme) private var theme

    init(agent: Agent) {
        self.agent = agent
        let agentID = agent.id
        _entries = Query(
            filter: #Predicate<AgentStashEntry> { $0.agentID == agentID },
            sort: [SortDescriptor(\AgentStashEntry.normalizedKey)]
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShadSettingsSectionHeader(
                title: "Stash",
                description: "Short-lived working information stored as text key/value pairs. This is separate from Memory."
            )

            VStack(alignment: .leading, spacing: 12) {
                Text("Add an entry")
                    .font(theme.font(theme.typography.sm, theme.typography.medium))

                ShadInput("Key, such as Weather", text: $newKey)
                    .accessibilityLabel("New stash key")

                ShadTextarea(
                    "Value",
                    text: $newValue,
                    minHeight: 100,
                    maxHeight: 320,
                    isResizable: true
                )
                .accessibilityLabel("New stash value")

                HStack {
                    Text("Values can contain multiple lines.")
                        .font(theme.font(theme.typography.xs))
                        .foregroundStyle(theme.colors.mutedForeground)

                    Spacer()

                    ShadButton("Add", size: .sm, icon: .plus) {
                        addEntry()
                    }
                    .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .shadSettingsCard()

            if let errorMessage {
                Text(errorMessage)
                    .font(theme.font(theme.typography.xs))
                    .foregroundStyle(theme.colors.destructive)
            }

            if entries.isEmpty {
                VStack(spacing: 6) {
                    Text("No stash entries")
                        .font(theme.font(theme.typography.sm, theme.typography.medium))
                    Text("Add one here, or let this agent create one after enabling the Stash tool.")
                        .font(theme.font(theme.typography.sm))
                        .foregroundStyle(theme.colors.mutedForeground)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
                .shadSettingsCard()
            } else {
                ForEach(entries) { entry in
                    AgentStashEntryEditor(entry: entry, agentID: agent.id)
                        .id(entry.id)
                }
            }

            Text(
                agent.isToolEnabled(.agentStash)
                    ? "This agent can list, read, and update these entries. Each result includes its last update time."
                    : "Enable Stash in Tools to let this agent list, read, and update these entries. You can always edit them here."
            )
            .font(theme.font(theme.typography.xs))
            .foregroundStyle(theme.colors.mutedForeground)
        }
    }

    private func addEntry() {
        do {
            try AgentStashDatabase.upsert(
                key: newKey,
                value: newValue,
                agentID: agent.id,
                in: modelContext
            )
            newKey = ""
            newValue = ""
            errorMessage = nil
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

private struct AgentStashEntryEditor: View {
    let entry: AgentStashEntry
    let agentID: UUID
    @State private var draftKey: String
    @State private var draftValue: String
    @State private var baselineKey: String
    @State private var baselineValue: String
    @State private var hasExternalConflict = false
    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.shadTheme) private var theme

    init(entry: AgentStashEntry, agentID: UUID) {
        self.entry = entry
        self.agentID = agentID
        _draftKey = State(initialValue: entry.key)
        _draftValue = State(initialValue: entry.value)
        _baselineKey = State(initialValue: entry.key)
        _baselineValue = State(initialValue: entry.value)
    }

    private var hasChanges: Bool {
        draftKey != entry.key || draftValue != entry.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShadInput("Key", text: $draftKey)
                .accessibilityLabel("Stash key")

            ShadTextarea(
                "Value",
                text: $draftValue,
                minHeight: 110,
                maxHeight: 420,
                isResizable: true
            )
            .accessibilityLabel("Stash value for \(entry.key)")

            if let errorMessage {
                Text(errorMessage)
                    .font(theme.font(theme.typography.xs))
                    .foregroundStyle(theme.colors.destructive)
            }

            if hasExternalConflict {
                Text("This entry changed while you were editing. Saving will replace its latest value.")
                    .font(theme.font(theme.typography.xs))
                    .foregroundStyle(theme.colors.destructive)
            }

            HStack {
                Text("Updated \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(theme.font(theme.typography.xs))
                    .foregroundStyle(theme.colors.mutedForeground)

                Spacer()

                ShadButton("Delete", variant: .outline, size: .sm, icon: .trash) {
                    deleteEntry()
                }

                ShadButton("Save", size: .sm, icon: .check) {
                    saveEntry()
                }
                .disabled(!hasChanges || draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .shadSettingsCard()
        .onChange(of: entry.updatedAt) {
            let userHasDraftChanges = draftKey != baselineKey || draftValue != baselineValue
            baselineKey = entry.key
            baselineValue = entry.value
            if userHasDraftChanges {
                hasExternalConflict = true
            } else {
                draftKey = entry.key
                draftValue = entry.value
                hasExternalConflict = false
            }
        }
    }

    private func saveEntry() {
        do {
            try AgentStashDatabase.update(
                entry: entry,
                key: draftKey,
                value: draftValue,
                agentID: agentID,
                in: modelContext
            )
            baselineKey = entry.key
            baselineValue = entry.value
            hasExternalConflict = false
            errorMessage = nil
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEntry() {
        modelContext.delete(entry)
        do {
            try modelContext.save()
            errorMessage = nil
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
