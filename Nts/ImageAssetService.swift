import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageInput {
    let data: Data
    let name: String

    static func clipboard(_ data: Data, now: Date = Date()) -> ImageInput {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return ImageInput(data: data, name: "screenshot-\(formatter.string(from: now))")
    }

    static func read(_ url: URL) throws -> ImageInput {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ImageAssetError.unsupportedImage }
        return ImageInput(data: try Data(contentsOf: url), name: url.lastPathComponent)
    }
}

struct ImportedImage {
    let url: URL
    var markdown: String { "![image](imgs/\(url.lastPathComponent))" }
}

enum ImageAssetError: LocalizedError {
    case unsupportedImage
    case invalidImagesDirectory
    case noActiveNote

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "Drop a supported image, such as PNG, JPEG, GIF, TIFF, HEIC, or BMP. Folders, SVG, PDF, and damaged images aren't supported."
        case .invalidImagesDirectory:
            return "The imgs path must be a regular folder, not a file or symbolic link. Rename the existing item in Finder, then try again."
        case .noActiveNote:
            return "Open a note before inserting an image."
        }
    }
}

struct ImageAssetService {
    private let manager = FileManager.default

    @discardableResult
    func ensureDirectory(in folder: URL) throws -> URL {
        let directory = folder.appendingPathComponent("imgs", isDirectory: true)
        if let existing = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard existing.isDirectory == true, existing.isSymbolicLink != true else {
                throw ImageAssetError.invalidImagesDirectory
            }
            return directory
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ImageAssetError.invalidImagesDirectory
        }
        return directory
    }

    func importImages(_ inputs: [ImageInput], into folder: URL) throws -> [ImportedImage] {
        guard !inputs.isEmpty else { return [] }
        // Validate the whole drop before creating files or changing the note.
        let prepared = try inputs.map { input in
            (input, try imageExtension(for: input.data))
        }
        let directory = try ensureDirectory(in: folder)
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        var imported: [ImportedImage] = []
        do {
            for (index, preparedImage) in prepared.enumerated() {
                let (input, ext) = preparedImage
                let temporary = staging.appendingPathComponent("\(index)")
                try input.data.write(to: temporary, options: .atomic)
                let base = safeStem(input.name)
                var suffix = 0
                while true {
                    let filename = suffix == 0 ? base : "\(base)-\(suffix)"
                    let target = directory.appendingPathComponent(filename).appendingPathExtension(ext)
                    do {
                        // Publish a complete image; moveItem refuses existing destinations.
                        try manager.moveItem(at: temporary, to: target)
                        imported.append(ImportedImage(url: target))
                        break
                    } catch let error as NSError {
                        guard error.domain == NSCocoaErrorDomain,
                              error.code == CocoaError.fileWriteFileExists.rawValue else { throw error }
                        suffix += 1
                    }
                }
            }
            return imported
        } catch {
            for image in imported { try? manager.removeItem(at: image.url) }
            throw error
        }
    }

    private func imageExtension(for data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image),
              let ext = type.preferredFilenameExtension,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1
              ] as CFDictionary) != nil else {
            throw ImageAssetError.unsupportedImage
        }
        return ext
    }

    private func safeStem(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        var result = ""
        for scalar in stem.unicodeScalars {
            if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
                result.append(Character(String(scalar)))
            } else if !result.isEmpty, !result.hasSuffix("-") {
                result.append("-")
            }
            if result.count >= 80 { break }
        }
        let cleaned = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "image" : cleaned
    }
}
