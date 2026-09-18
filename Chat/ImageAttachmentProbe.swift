import AppKit
import SwiftData

/// Offline integration checks using the production persistence and request models.
enum ImageAttachmentProbe {
    static func run() throws {
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else {
                throw NSError(domain: "ImageAttachmentProbe", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: label])
            }
            print("PASS \(label)")
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = try ChatImageAttachment.importData(bitmap.representation(using: .png, properties: [:])!, name: "fixture.png")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let chatID = UUID()
        let localModelID = UUID()
        // Release both the context and container, then reopen the actual disk store.
        try autoreleasepool {
            let container = try ChatModelContainer.make(configuration: ModelConfiguration(url: url))
            let context = ModelContext(container)
            let local = LocalModel(id: localModelID, name: "Fixture local model", endpoint: "http://127.0.0.1:1/v1", modelID: "fixture")
            context.insert(local)
            let store = LocalModelStore(modelContext: context)
            try check(!store.configuration(for: local).supportsImages, "new local models default to image input disabled")
            local.supportsImages = nil
            try check(!store.configuration(for: local).supportsImages, "legacy local models default to image input disabled")
            let disabled = store.configuration(for: local)
            try disabled.validateImageInput(hasImages: false)
            try check(true, "disabled image support still allows text-only requests")
            do {
                try disabled.validateImageInput(hasImages: true)
                try check(false, "disabled local model must reject image input")
            } catch ImageAttachmentError.localImagesDisabled {
                try check(true, "disabled local model rejects image input before sending")
            }
            store.updateSupportsImages(for: local, to: true)
            try store.configuration(for: local).validateImageInput(hasImages: true)
            context.insert(StoredChatMessage(chatID: chatID, role: .user, text: "Describe it", images: [image]))
            context.insert(StoredChatMessage(chatID: chatID, role: .assistant, text: "A picture"))
            context.insert(StoredChatMessage(chatID: chatID, role: .user, text: "What color is it?"))
            try context.save()
        }
        try autoreleasepool {
            let container = try ChatModelContainer.make(configuration: ModelConfiguration(url: url))
            let context = ModelContext(container)
            let local = try context.fetch(FetchDescriptor<LocalModel>()).first { $0.id == localModelID }!
            let store = LocalModelStore(modelContext: context)
            try check(store.configuration(for: local).supportsImages, "local image capability survives reopening")
            store.updateSupportsImages(for: local, to: false)
            try check(!store.configuration(for: local).supportsImages, "local image capability can be disabled again")
            let stored = ActiveChatMessages.fetchAll(chatID: chatID, in: context)
            try check(stored.count == 3, "messages survive reopening")
            try check(stored[0].images == [image], "image bytes and metadata survive reopening")
            try check(stored[1].images.isEmpty, "text-only messages remain compatible")
            let messages = stored.map { ChatMessage(storedMessage: $0) }
            let conversation = ModelConversationContext(systemPrompt: "Be helpful", digest: "", messages: messages,
                labeledPrompt: ModelPrompts.conversationTranscript(messages: stored, isGroupChat: false, fallbackAgentName: "Agent"))
            try check(conversation.messagesIncludingDigest.first?.images == [image], "follow-up retains original image")
            try check(conversation.labeledPrompt.contains(image.label), "flattened transcript labels original image")
            let request = OpenAIChatMessage(role: "user", content: "Describe it", images: [image])
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
            let content = json["content"] as! [[String: Any]]
            try check(content[0]["text"] as? String == "Describe it", "local request retains user question")
            try check((content[2]["image_url"] as? [String: String])?["url"] == image.dataURL,
                      "local request carries real image bytes")
            let textRequest = OpenAIChatMessage(role: "user", content: "Hello")
            let textJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(textRequest)) as! [String: Any]
            try check(textJSON["content"] as? String == "Hello", "text-only request keeps string content")
            for message in stored { context.delete(message) }
            try context.save()
            try check(ActiveChatMessages.fetchAll(chatID: chatID, in: context).isEmpty, "message deletion removes attachment owner")
        }
        print("Image attachment integration checks passed")
    }
}
