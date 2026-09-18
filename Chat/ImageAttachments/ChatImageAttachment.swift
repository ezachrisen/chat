import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Owned image bytes, independent of the original file and safe to persist with a message.
nonisolated struct ChatImageAttachment: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let data: Data
    let width: Int
    let height: Int

    static let maximumCount = 4
    static let maximumContextCount = 8
    static let maximumInputBytes = 25 * 1024 * 1024
    static let maximumDimension = 2048

    var label: String { "Image \(id.uuidString): \(name)" }
    var dataURL: String { "data:image/jpeg;base64," + data.base64EncodedString() }

    static func importFile(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= maximumInputBytes else { throw ImageAttachmentError.invalidImage }
        return try importData(Data(contentsOf: url), name: url.lastPathComponent)
    }

    static func importData(_ data: Data, name: String = "Pasted image") throws -> Self {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImageAttachmentError.invalidImage }
        // JPEG has no alpha channel. Flatten onto white so transparent screenshots
        // and diagrams with dark text remain readable.
        guard let canvas = CGContext(data: nil, width: image.width, height: image.height,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ImageAttachmentError.invalidImage }
        canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flattened = canvas.makeImage() else { throw ImageAttachmentError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ImageAttachmentError.invalidImage }
        // Re-encoding applies orientation, limits memory/payload size, and omits source metadata.
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 4 * 1024 * 1024
        else { throw ImageAttachmentError.invalidImage }
        return Self(id: UUID(), name: String(name.prefix(160)), data: output as Data,
                    width: image.width, height: image.height)
    }

    func cgImage() throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImageAttachmentError.invalidImage }
        return image
    }
}

nonisolated enum ImageAttachmentError: LocalizedError {
    case invalidImage
    case tooManyImages
    case visionUnavailable(String)
    case localImagesDisabled(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Choose a still image no larger than 25 MB. Animated or unreadable images aren't supported."
        case .tooManyImages:
            return "You can attach up to four images to a message."
        case .localImagesDisabled(let model):
            return "Image input is disabled for \(model). In Settings → Models, enable Supports images for this local model if it supports vision, or choose a vision-capable model."
        case .visionUnavailable(let model):
            return "\(model) doesn't support image input. Choose a model with vision support."
        }
    }
}
