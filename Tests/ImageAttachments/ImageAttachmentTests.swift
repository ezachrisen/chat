import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ImageAttachmentCore

final class ImageAttachmentTests: XCTestCase {
    private func png(width: Int = 32, height: Int = 16, orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                  [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testImportNormalizesResizesAndRoundTrips() throws {
        let image = try ChatImageAttachment.importData(png(width: 4096, height: 1024), name: "wide.png")
        XCTAssertEqual(image.width, 2048)
        XCTAssertEqual(image.height, 512)
        XCTAssertEqual(try image.cgImage().width, 2048)
        let decoded = try JSONDecoder().decode(ChatImageAttachment.self, from: JSONEncoder().encode(image))
        XCTAssertEqual(image, decoded)
        XCTAssertTrue(image.dataURL.hasPrefix("data:image/jpeg;base64,"))
    }

    func testOrientationIsApplied() throws {
        let image = try ChatImageAttachment.importData(png(width: 32, height: 16, orientation: 6))
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 32)
    }

    func testInvalidAndOversizedInputsAreRejected() {
        XCTAssertThrowsError(try ChatImageAttachment.importData(Data("not an image".utf8)))
        XCTAssertThrowsError(try ChatImageAttachment.importData(Data(count: ChatImageAttachment.maximumInputBytes + 1)))
    }

    func testTransparentImageIsFlattenedOntoWhite() throws {
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.clear(CGRect(x: 0, y: 0, width: 8, height: 8))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let imported = try ChatImageAttachment.importData(data as Data)
        canvas.draw(try imported.cgImage(), in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let pixels = try XCTUnwrap(canvas.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(pixels[0], 245)
        XCTAssertGreaterThan(pixels[1], 245)
        XCTAssertGreaterThan(pixels[2], 245)
    }

    func testCodexStagesOwnedBytesInInputOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = try [ChatImageAttachment.importData(png(), name: "one.png"),
                          ChatImageAttachment.importData(png(), name: "two.png")]
        let input = try ChatImageProviderInput.codex(prompt: "Compare these", images: images, directory: directory)
        XCTAssertEqual(input.map { $0["type"] }, ["text", "text", "localImage", "text", "localImage"])
        XCTAssertEqual(input[0]["text"], "Compare these")
        for (index, image) in images.enumerated() {
            let path = try XCTUnwrap(input[index * 2 + 2]["path"])
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), image.data)
            XCTAssertTrue(path.hasPrefix(directory.path + "/"))
        }
        XCTAssertEqual(try ChatImageProviderInput.codex(prompt: "Hello", images: [], directory: directory),
                       [["type": "text", "text": "Hello"]])
    }

    func testOpenAIImagePartUsesNestedDataURL() throws {
        let image = try ChatImageAttachment.importData(png())
        let part = ImageChatContentPart(type: "image_url", imageURL: .init(url: image.dataURL))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(part)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "image_url")
        XCTAssertNil(json["text"])
        XCTAssertEqual((json["image_url"] as? [String: String])?["url"], image.dataURL)
    }
}
