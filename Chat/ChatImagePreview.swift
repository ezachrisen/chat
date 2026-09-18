import AppKit
import ImageIO
import SwiftUI

struct ChatImagePreview: View {
    let attachment: ChatImageAttachment
    var compact = false
    @State private var image: NSImage?
    @State private var isExpanded = false

    var body: some View {
        Button { isExpanded = true } label: {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Label(attachment.name, systemImage: "photo")
                }
            }
            .frame(maxWidth: compact ? 80 : 320, maxHeight: compact ? 64 : 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(attachment.name)
        .accessibilityLabel("Preview \(attachment.name)")
        .contextMenu {
            Button("Copy image") {
                guard let image else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
        .task(id: attachment.id) {
            let data = attachment.data
            let decoded = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }.value
            if let decoded { image = NSImage(cgImage: decoded, size: .zero) }
        }
        .sheet(isPresented: $isExpanded) {
            VStack {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                }
                HStack {
                    Text(attachment.name).lineLimit(1)
                    Spacer()
                    Button("Done") { isExpanded = false }.keyboardShortcut(.cancelAction)
                }
            }
            .padding()
            .frame(minWidth: 500, idealWidth: 800, minHeight: 400, idealHeight: 600)
        }
    }
}
