import AppKit
import Foundation
import ShadSwift

extension Agent {
    var avatarInitials: String {
        let parts = displayName
            .split { $0.isWhitespace || $0.isNewline }
            .filter { !$0.isEmpty }

        if parts.count >= 2 {
            return String((parts[0].prefix(1) + parts[1].prefix(1))).uppercased()
        }
        if let first = parts.first, let character = first.first {
            return String(character).uppercased()
        }
        return "?"
    }

    var avatarPhoto: ShadAvatarPhoto {
        guard let avatarImageData,
              let image = NSImage(data: avatarImageData) else {
            return .empty
        }

        return ShadAvatarPhoto(
            image: image,
            crop: ShadAvatarCrop(
                zoom: max(1, avatarCropZoom ?? 1),
                offset: CGSize(
                    width: CGFloat(avatarCropOffsetX ?? 0),
                    height: CGFloat(avatarCropOffsetY ?? 0)
                )
            )
        )
    }
}

extension ShadAvatarPhoto {
    var persistentImageData: Data? {
        guard let image,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
