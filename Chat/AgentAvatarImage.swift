import AppKit
import Foundation
import ShadSwift
import SwiftUI

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

    var avatarPlaceholderColor: Color? {
        AgentAvatarPlaceholderColor.decode(avatarPlaceholderColorHex)
    }
}

enum AgentAvatarPlaceholderColor {
    static func encode(_ color: Color) -> String? {
        guard let color = NSColor(color).usingColorSpace(.sRGB) else { return nil }

        let red = Int((color.redComponent.clampedToUnitInterval * 255).rounded())
        let green = Int((color.greenComponent.clampedToUnitInterval * 255).rounded())
        let blue = Int((color.blueComponent.clampedToUnitInterval * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    static func decode(_ value: String?) -> Color? {
        guard let value else { return nil }
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let components = UInt64(hex, radix: 16) else { return nil }

        return Color(
            red: Double((components >> 16) & 0xFF) / 255,
            green: Double((components >> 8) & 0xFF) / 255,
            blue: Double(components & 0xFF) / 255
        )
    }
}

private extension CGFloat {
    var clampedToUnitInterval: CGFloat {
        Swift.min(Swift.max(self, 0), 1)
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
