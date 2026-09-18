import Foundation

nonisolated struct ImageChatContentPart: Encodable, Sendable {
    struct ImageURL: Encodable, Sendable { var url: String }
    var type: String
    var text: String? = nil
    var imageURL: ImageURL? = nil

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }
}

nonisolated enum ChatImageProviderInput {
    /// Files live only for the duration of the provider's isolated session.
    static func codex(prompt: String, images: [ChatImageAttachment], directory: URL) throws -> [[String: String]] {
        var input = [["type": "text", "text": prompt]]
        for image in images {
            let url = directory.appendingPathComponent(image.id.uuidString + ".jpg")
            try image.data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            input.append(["type": "text", "text": image.label])
            input.append(["type": "localImage", "path": url.path])
        }
        return input
    }
}
