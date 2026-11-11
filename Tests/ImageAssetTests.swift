import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

func imageFixture(width: Int = 2, height: Int = 2) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.5, green: 0.7, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

final class ImageAssetTests: XCTestCase {
    private var folder: URL!
    private let images = ImageAssetService()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    @objc func testCreatesAndReusesImagesDirectory() throws {
        let directory = try images.ensureDirectory(in: folder)
        XCTAssertEqual(directory.lastPathComponent, "imgs")
        let sentinel = directory.appendingPathComponent("keep.txt")
        try Data("Keep me".utf8).write(to: sentinel)
        XCTAssertEqual(try images.ensureDirectory(in: folder), directory)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "Keep me")
    }

    @objc func testClipboardTimestampAndSameSecondCollisions() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ImageInput.clipboard(imageFixture(), now: now)
        let later = ImageInput.clipboard(imageFixture(), now: now.addingTimeInterval(1))
        XCTAssertNotEqual(first.name, later.name)
        let imported = try images.importImages([first, first, later], into: folder)
        XCTAssertEqual(imported[0].url.lastPathComponent, first.name + ".png")
        XCTAssertEqual(imported[1].url.lastPathComponent, first.name + "-1.png")
        XCTAssertEqual(imported[2].url.lastPathComponent, later.name + ".png")
    }

    @objc func testCopiesBytesAndUsesActualImageFormat() throws {
        let data = imageFixture()
        let source = folder.appendingPathComponent("Photo.jpg")
        try data.write(to: source)
        let imported = try images.importImages([ImageInput.read(source)], into: folder)
        XCTAssertEqual(imported[0].url.lastPathComponent, "photo.png")
        XCTAssertEqual(imported[0].markdown, "![image](imgs/photo.png)")
        XCTAssertEqual(try Data(contentsOf: imported[0].url), data)
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    @objc func testSafeNamesAndCollisionsNeverOverwrite() throws {
        let data = imageFixture()
        let input = ImageInput(data: data, name: "Vacation [June] (100%).PNG")
        let first = try images.importImages([input], into: folder)[0]
        let next = try images.importImages([input, input], into: folder)
        XCTAssertEqual(first.url.lastPathComponent, "vacation-june-100.png")
        XCTAssertEqual(next.map { $0.url.lastPathComponent }, ["vacation-june-100-1.png", "vacation-june-100-2.png"])
        XCTAssertEqual(try Data(contentsOf: first.url), data)
        let entries = try FileManager.default.contentsOfDirectory(atPath: first.url.deletingLastPathComponent().path)
        XCTAssertEqual(entries.count, 3, "Staging files should be cleaned up")
    }

    @objc func testMixedInvalidDropCreatesNoAssets() throws {
        let good = ImageInput(data: imageFixture(), name: "good.png")
        let bad = ImageInput(data: Data("not an image".utf8), name: "bad.png")
        XCTAssertThrowsError(try images.importImages([good, bad], into: folder))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @objc func testRejectsFileBlockingImagesDirectory() throws {
        let blocked = folder.appendingPathComponent("imgs")
        let data = Data("Keep this file".utf8)
        try data.write(to: blocked)
        XCTAssertThrowsError(try images.ensureDirectory(in: folder))
        XCTAssertEqual(try Data(contentsOf: blocked), data)
    }

    @objc func testRejectsSymlinkImagesDirectory() throws {
        let outside = folder.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("imgs"),
                                                   withDestinationURL: outside)
        XCTAssertThrowsError(try images.importImages([ImageInput(data: imageFixture(), name: "photo")], into: folder))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @objc func testFallbackNamesAndPortableLinks() throws {
        let inputs = ["日本語.png", "../bad [name]#.png"].map { ImageInput(data: imageFixture(), name: $0) }
        let imported = try images.importImages(inputs, into: folder)
        XCTAssertEqual(imported.map { $0.url.lastPathComponent }, ["image.png", "bad-name.png"])
        for image in imported {
            XCTAssertEqual(image.url.deletingLastPathComponent(), folder.appendingPathComponent("imgs", isDirectory: true))
            XCTAssertFalse(image.markdown.contains("file://"))
            XCTAssertFalse(image.markdown.contains(folder.path))
        }
    }

    @objc func testRejectsTruncatedImageAndNonFileSources() throws {
        let truncated = ImageInput(data: imageFixture().prefix(12), name: "truncated.png")
        XCTAssertThrowsError(try images.importImages([truncated], into: folder))
        XCTAssertThrowsError(try ImageInput.read(folder))
        XCTAssertThrowsError(try ImageInput.read(folder.appendingPathComponent("missing.png")))
    }
}
