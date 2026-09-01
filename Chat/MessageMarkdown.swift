import Foundation
import ShadSwift
import SwiftUI

struct MarkdownMessageView: View {
    let text: String
    @Environment(\.shadTheme) private var theme

    var body: some View {
        let blocks = MessageMarkdown.parse(text)
        if blocks.isEmpty {
            Text(text)
        } else {
            VStack(alignment: .leading, spacing: theme.spacing.md) {
                ForEach(blocks) { block in
                    MarkdownBlockView(block: block, unorderedDepth: 0)
                }
            }
        }
    }
}

private struct MarkdownBlock: Identifiable {
    let id: Int
    let kind: PresentationIntent.Kind
    let text: AttributedString
    let children: [MarkdownBlock]
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let unorderedDepth: Int
    @Environment(\.shadTheme) private var theme

    var body: some View {
        switch block.kind {
        case .paragraph:
            paragraph(block.text)

        case .header(let level):
            paragraph(block.text)
                .font(headerFont(level))

        case .orderedList:
            VStack(alignment: .leading, spacing: theme.spacing.lg) {
                ForEach(block.children) { child in
                    MarkdownListItemView(
                        block: child,
                        unorderedDepth: unorderedDepth + 1,
                        ordered: true
                    )
                }
            }

        case .unorderedList:
            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                ForEach(block.children) { child in
                    MarkdownListItemView(
                        block: child,
                        unorderedDepth: unorderedDepth + 1,
                        ordered: false
                    )
                }
            }

        case .listItem:
            MarkdownListItemView(
                block: block,
                unorderedDepth: unorderedDepth,
                ordered: false
            )

        case .codeBlock:
            ShadItem(variant: .muted, size: .xs) {
                Text(String(block.text.characters).trimmingCharacters(in: .newlines))
                    .font(theme.monoFont(theme.typography.sm))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .blockQuote:
            HStack(alignment: .top, spacing: theme.spacing.md) {
                ShadSeparator(.vertical, color: theme.colors.border)
                    .frame(width: theme.borderWidth * 3)

                VStack(alignment: .leading, spacing: theme.spacing.sm) {
                    if !block.text.characters.isEmpty {
                        paragraph(block.text)
                    }
                    ForEach(block.children) { child in
                        MarkdownBlockView(block: child, unorderedDepth: unorderedDepth)
                    }
                }
            }

        case .thematicBreak:
            ShadSeparator()
                .padding(.vertical, theme.spacing.xs)

        default:
            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                if !block.text.characters.isEmpty {
                    paragraph(block.text)
                }
                ForEach(block.children) { child in
                    MarkdownBlockView(block: child, unorderedDepth: unorderedDepth)
                }
            }
        }
    }

    private func paragraph(_ text: AttributedString) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headerFont(_ level: Int) -> Font {
        switch level {
        case 1:
            return theme.font(theme.typography.xxl, theme.typography.semibold)
        case 2:
            return theme.font(theme.typography.xl, theme.typography.semibold)
        case 3:
            return theme.font(theme.typography.lg, theme.typography.semibold)
        default:
            return theme.font(theme.typography.base, theme.typography.semibold)
        }
    }
}

private struct MarkdownListItemView: View {
    let block: MarkdownBlock
    let unorderedDepth: Int
    let ordered: Bool
    @Environment(\.shadTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacing.md) {
            Text(marker)
                .font(theme.monoFont(theme.typography.sm).monospacedDigit())
                .frame(minWidth: ordered ? 22 : 14, alignment: .trailing)

            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                if !block.text.characters.isEmpty {
                    Text(block.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(contents) { child in
                    MarkdownBlockView(block: child, unorderedDepth: unorderedDepth)
                }
            }
        }
    }

    private var contents: [MarkdownBlock] {
        if case .listItem = block.kind {
            return block.children
        }
        return [block]
    }

    private var marker: String {
        guard case .listItem(let ordinal) = block.kind else {
            return ordered ? "1." : bullet
        }
        return ordered ? "\(ordinal)." : bullet
    }

    private var bullet: String {
        unorderedDepth <= 1 ? "•" : "◦"
    }
}

private enum MessageMarkdown {
    static func parse(_ text: String) -> [MarkdownBlock] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            return []
        }

        let root = Node(id: 0, kind: .paragraph)
        for run in attributed.runs {
            let slice = attributed[run.range]
            if isBlockSeparator(slice) {
                continue
            }

            var current = root
            if let intent = attributed[run.range].presentationIntent {
                for component in intent.components.reversed() {
                    current = current.child(component)
                }
            }

            var piece = AttributedString(slice)
            piece.presentationIntent = nil
            current.text.append(piece)
        }

        return root.children.map { $0.snapshot() }
    }

    private static func isBlockSeparator(_ slice: AttributedSubstring) -> Bool {
        let scalars = String(slice.characters).unicodeScalars
        guard !scalars.isEmpty else { return true }
        return scalars.allSatisfy { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }

    private final class Node {
        let id: Int
        let kind: PresentationIntent.Kind
        var text = AttributedString()
        var children: [Node] = []
        private var childByID: [Int: Node] = [:]

        init(id: Int, kind: PresentationIntent.Kind) {
            self.id = id
            self.kind = kind
        }

        func child(_ component: PresentationIntent.IntentType) -> Node {
            if let existing = childByID[component.identity] {
                return existing
            }
            let node = Node(id: component.identity, kind: component.kind)
            childByID[component.identity] = node
            children.append(node)
            return node
        }

        func snapshot() -> MarkdownBlock {
            MarkdownBlock(
                id: id,
                kind: kind,
                text: text,
                children: children.map { $0.snapshot() }
            )
        }
    }
}
