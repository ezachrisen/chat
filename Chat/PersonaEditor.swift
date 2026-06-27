import SwiftUI

#if os(macOS)
import AppKit
#endif

struct PersonasWindow: View {
    @ObservedObject var store: PersonaStore

    var body: some View {
        NavigationSplitView {
            PersonaSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            PersonaEditor(store: store)
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

struct PersonaSidebar: View {
    @ObservedObject var store: PersonaStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedPersonaID) {
                ForEach(store.personas) { persona in
                    Text(persona.displayName)
                        .tag(persona.id)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    store.addPersona()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Persona")

                Button {
                    store.removeSelectedPersona()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(store.selectedPersonaID == nil)
                .help("Remove Persona")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }
}

private let minimumSoulEditorHeight: CGFloat = 240
private let maximumSoulEditorHeight: CGFloat = 720

struct PersonaEditor: View {
    @ObservedObject var store: PersonaStore
    @State private var draftSoul = ""
    @State private var soulEditorHeight: CGFloat = 360

    private var selectedPersona: Persona? {
        store.selectedPersona
    }

    private var personaName: Binding<String> {
        Binding {
            selectedPersona?.name ?? ""
        } set: { newValue in
            guard let personaID = selectedPersona?.id else { return }
            store.updatePersonaName(id: personaID, name: newValue)
        }
    }

    var body: some View {
        Group {
            if let selectedPersona {
                editor(for: selectedPersona)
            } else {
                Text("Select or add a persona.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(red: 253 / 255, green: 253 / 255, blue: 252 / 255))
        .onAppear(perform: loadSelectedPersona)
        .onChange(of: store.selectedPersonaID) {
            loadSelectedPersona()
        }
    }

    private func editor(for persona: Persona) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Persona name", text: personaName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(height: 54)

                Text("Soul")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 34)
                    .padding(.bottom, 12)

                ResizableSoulEditor(text: $draftSoul, height: $soulEditorHeight)

                HStack {
                    Spacer()

                    Button("Save") {
                        store.updatePersonaSoul(id: persona.id, soul: draftSoul)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
            .padding(.top, 70)
            .padding(.bottom, 70)
            .padding(.horizontal, 48)

            Spacer(minLength: 0)
        }
    }

    private func loadSelectedPersona() {
        guard let selectedPersona else {
            draftSoul = ""
            return
        }

        load(selectedPersona)
    }

    private func load(_ persona: Persona) {
        draftSoul = persona.soul
    }
}

struct ResizableSoulEditor: View {
    @Binding var text: String
    @Binding var height: CGFloat
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        SoulTextView(text: $text)
            .padding(12)
            .padding(.bottom, 8)
            .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.22), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                ResizeGrip()
                    .padding(5)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let startHeight = dragStartHeight ?? height
                                dragStartHeight = startHeight
                                height = min(max(startHeight + value.translation.height, minimumSoulEditorHeight), maximumSoulEditorHeight)
                            }
                            .onEnded { _ in
                                dragStartHeight = nil
                            }
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

#if os(macOS)
struct SoulTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 15)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
#else
struct SoulTextView: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 15))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
    }
}
#endif

struct ResizeGrip: View {
    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round)
            let color = Color.gray.opacity(0.55)

            for offset in stride(from: 0.0, through: 8.0, by: 4.0) {
                var path = Path()
                path.move(to: CGPoint(x: size.width - offset, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: size.height - offset))
                context.stroke(path, with: .color(color), style: stroke)
            }
        }
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
        .help("Resize Soul editor")
    }
}
