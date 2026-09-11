import Foundation
import CryptoKit

nonisolated struct AppleAttachment: Codable, Sendable, Identifiable {
    var id: String
    var agentID: UUID
    var name: String
    var digest: String
    var size: Int
    var createdAt = Date()
}

/// Only files deliberately imported through Chat's file picker become model-usable references.
@MainActor
final class AppleAttachmentStore {
    static let shared = AppleAttachmentStore()
    private let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.zachrisen.chat/apple-attachments", isDirectory: true)) {
        self.directory = directory
    }
    func list(agentID: UUID) -> [AppleAttachment] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let item = try? JSONDecoder().decode(AppleAttachment.self, from: data), item.agentID == agentID else { return nil }
            guard UUID(uuidString: item.id) != nil, url.lastPathComponent == item.id + ".json",
                  !item.name.isEmpty, item.name != ".", item.name != "..", !item.name.contains("/"), item.size <= 25 * 1024 * 1024 else { return nil }
            if item.createdAt < Date().addingTimeInterval(-86400) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.id))
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return item
        }.sorted { $0.createdAt > $1.createdAt }
    }
    func importFile(_ source: URL, agentID: UUID) throws -> AppleAttachment {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 25 * 1024 * 1024 else { throw AppleServiceError.invalid("Choose a regular file no larger than 25 MB.") }
        guard list(agentID: agentID).count < 50 else { throw AppleServiceError.invalid("Remove an imported file before adding another.") }
        let data = try Data(contentsOf: source)
        guard data.count <= 25 * 1024 * 1024 else { throw AppleServiceError.invalid("File grew beyond the import limit.") }
        let item = AppleAttachment(id: UUID().uuidString, agentID: agentID, name: source.lastPathComponent, digest: Self.digest(data), size: data.count)
        let folder = directory.appendingPathComponent(item.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: folder.appendingPathComponent(item.name), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent(item.name).path)
        try JSONEncoder().encode(item).write(to: directory.appendingPathComponent(item.id + ".json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(item.id + ".json").path)
        return item
    }
    func resolve(_ id: String, agentID: UUID) throws -> (AppleAttachment, URL) {
        guard let item = list(agentID: agentID).first(where: { $0.id == id }), item.createdAt > Date().addingTimeInterval(-86400) else { throw AppleServiceError.forbidden }
        let url = directory.appendingPathComponent(item.id).appendingPathComponent(item.name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == item.size,
              Self.digest(try Data(contentsOf: url)) == item.digest else { throw AppleServiceError.conflict }
        return (item, url)
    }
    func remove(_ id: String, agentID: UUID) throws {
        guard list(agentID: agentID).contains(where: { $0.id == id }) else { throw AppleServiceError.forbidden }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".json"))
    }
    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
