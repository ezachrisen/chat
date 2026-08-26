import SwiftUI

struct SkillPreferencesView: View {
    @ObservedObject var catalog: SkillCatalog

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                OpenUIPageHeader(
                    title: "Skills",
                    description: "Skills live in ~/.chat/skills. Enable a skill here before any agent can use it."
                )

                if catalog.skills.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "book")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(OpenUITheme.accent)

                        Text("No skills found")
                            .font(.system(size: 15, weight: .semibold))

                        Text("Add a folder containing SKILL.md to ~/.chat/skills, then reopen this pane.")
                            .font(.system(size: 13))
                            .foregroundStyle(OpenUITheme.foregroundMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .openUICard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(catalog.skills.enumerated()), id: \.element.id) { index, skill in
                            OpenUISettingsRow(
                                title: skill.name,
                                description: skill.description.isEmpty
                                    ? "No description in SKILL.md."
                                    : skill.description
                            ) {
                                Toggle(
                                    "Enable \(skill.name)",
                                    isOn: Binding(
                                        get: { catalog.isEnabled(skill.name) },
                                        set: { catalog.setEnabled(skill.name, enabled: $0) }
                                    )
                                )
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .tint(OpenUITheme.accent)
                            }

                            if index < catalog.skills.count - 1 {
                                OpenUIDivider()
                            }
                        }
                    }
                    .openUICard()
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
        .background(OpenUITheme.background)
        .onAppear {
            catalog.reload()
        }
    }
}
