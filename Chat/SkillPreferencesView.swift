import ShadSwift
import SwiftUI

struct SkillPreferencesView: View {
    @ObservedObject var catalog: SkillCatalog
    @Environment(\.shadTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                ShadSettingsPageHeader(
                    title: "Skills",
                    description: "Skills live in ~/.chat/skills. Enable a skill here before any agent can use it."
                )

                if catalog.skills.isEmpty {
                    VStack(spacing: 12) {
                        ShadIconView(.custom("book"), size: theme.typography.xxl)
                            .foregroundStyle(theme.colors.primary)

                        Text("No skills found")
                            .font(theme.font(theme.typography.base, theme.typography.semibold))

                        Text("Add a folder containing SKILL.md to ~/.chat/skills, then reopen this pane.")
                            .font(theme.font(theme.typography.sm))
                            .foregroundStyle(theme.colors.mutedForeground)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .shadSettingsCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(catalog.skills.enumerated()), id: \.element.id) { index, skill in
                            ShadSettingsRow(
                                title: skill.name,
                                description: skill.description.isEmpty
                                    ? "No description in SKILL.md."
                                    : skill.description
                            ) {
                                ShadSwitch(
                                    isOn: Binding(
                                        get: { catalog.isEnabled(skill.name) },
                                        set: { catalog.setEnabled(skill.name, enabled: $0) }
                                    )
                                )
                                .accessibilityLabel("Enable \(skill.name)")
                            }

                            if index < catalog.skills.count - 1 {
                                ShadSeparator()
                            }
                        }
                    }
                    .shadSettingsCard()
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
        .background(theme.colors.background)
        .onAppear {
            catalog.reload()
        }
    }
}
