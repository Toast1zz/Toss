import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One message ready for TDLib's `InputMessageContent`.
struct OutgoingItem {
    enum Kind { case photo, document, text }

    let kind: Kind
    let content: JSON

    /// Groups consecutive photos (or documents) into albums of up to 10;
    /// text goes alone. Telegram albums can't mix photos with documents.
    static func batches(_ items: [OutgoingItem]) -> [[OutgoingItem]] {
        var result: [[OutgoingItem]] = []
        for item in items {
            if item.kind != .text, let last = result.last, last.count < 10,
               last[0].kind == item.kind {
                result[result.count - 1].append(item)
            } else {
                result.append([item])
            }
        }
        return result
    }
}

/// What the user dropped, before conversion to Telegram content.
enum DropPayload {
    case file(URL)
    case text(String)
    case image(Data, UTType)
}

enum PayloadError: LocalizedError {
    case unreadable(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): L("Can't read \(name)")
        case .empty: L("Nothing to send")
        }
    }
}

enum OutgoingBuilder {
    /// Telegram limits for photos: ≤10 MB, width+height ≤ 10000, ratio ≤ 20.
    private static let maxPhotoBytes: Int64 = 10 * 1024 * 1024
    private static let maxTextLength = 4096

    static func build(_ payloads: [DropPayload], imagesAsPhotos: Bool) throws -> [OutgoingItem] {
        var items: [OutgoingItem] = []
        for payload in payloads {
            switch payload {
            case .file(let url):
                items.append(try fileItem(url, imagesAsPhotos: imagesAsPhotos))
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if trimmed.count > maxTextLength {
                    let url = AppPaths.newOutboxFolder().appendingPathComponent("Text.txt")
                    try trimmed.write(to: url, atomically: true, encoding: .utf8)
                    items.append(document(url))
                } else {
                    items.append(textItem(trimmed))
                }
            case .image(let data, let type):
                let ext = type.preferredFilenameExtension ?? "png"
                let url = AppPaths.newOutboxFolder().appendingPathComponent("Image.\(ext)")
                try data.write(to: url)
                items.append(try fileItem(url, imagesAsPhotos: imagesAsPhotos))
            }
        }
        guard !items.isEmpty else { throw PayloadError.empty }
        return items
    }

    private static func fileItem(_ url: URL, imagesAsPhotos: Bool) throws -> OutgoingItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .isPackageKey])
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw PayloadError.unreadable(url.lastPathComponent)
        }
        if values?.isDirectory == true {
            return document(try zip(url))
        }
        let size = Int64(values?.fileSize ?? 0)
        guard size > 0 else { throw PayloadError.unreadable(url.lastPathComponent) }
        if imagesAsPhotos, let type = values?.contentType, type.conforms(to: .image),
           !type.conforms(to: .gif), let photo = photoItem(url, type: type, size: size) {
            return photo
        }
        return document(url)
    }

    private static func photoItem(_ url: URL, type: UTType, size: Int64) -> OutgoingItem? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
            swap(&width, &height)
        }
        guard width + height <= 10000, max(width, height) <= min(width, height) * 20 else { return nil }

        var path = url
        if !(type.conforms(to: .jpeg) || type.conforms(to: .png)) || size > maxPhotoBytes {
            // HEIC, TIFF, WebP… are re-encoded so every client can show them.
            guard let jpeg = jpegCopy(source: source) else { return nil }
            path = jpeg
        }
        let photo: JSON = [
            "@type": "inputMessagePhoto",
            "photo": [
                "@type": "inputPhoto",
                "photo": ["@type": "inputFileLocal", "path": path.path],
                "width": width,
                "height": height,
            ] as JSON,
        ]
        return OutgoingItem(kind: .photo, content: photo)
    }

    private static func jpegCopy(source: CGImageSource) -> URL? {
        let url = AppPaths.newOutboxFolder().appendingPathComponent("Photo.jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImageDestinationImageMaxPixelSize: 4096,
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0 && Int64(size) <= maxPhotoBytes ? url : nil
    }

    private static func document(_ url: URL) -> OutgoingItem {
        OutgoingItem(kind: .document, content: [
            "@type": "inputMessageDocument",
            "document": [
                "@type": "inputDocument",
                "document": ["@type": "inputFileLocal", "path": url.path],
            ] as JSON,
        ])
    }

    private static func textItem(_ text: String) -> OutgoingItem {
        OutgoingItem(kind: .text, content: [
            "@type": "inputMessageText",
            "text": ["@type": "formattedText", "text": text, "entities": [Any]()] as JSON,
        ])
    }

    /// Folders can't be sent, so they go as a zip next to nothing of the user's.
    private static func zip(_ folder: URL) throws -> URL {
        let output = AppPaths.newOutboxFolder().appendingPathComponent(folder.lastPathComponent + ".zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, output.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PayloadError.unreadable(folder.lastPathComponent) }
        return output
    }
}

// MARK: - Reading the drag pasteboard

enum DragReader {
    static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .rtf, .html, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: acceptedTypes) != nil
    }

    /// Everything readable from a drag, captured synchronously while the
    /// drag session is still alive. File promises are fulfilled later.
    struct Snapshot {
        var files: [URL] = []
        var promises: [NSFilePromiseReceiver] = []
        var image: (Data, UTType)?
        /// A web (or other non-file) link, e.g. from an address bar.
        var link: URL?
        var linkTitle: String?
        var text: String?

        var isEmpty: Bool { DragReader.kind(of: self) == nil }

        var promisedNames: [String] { promises.flatMap(\.fileNames) }
        var promisedTypes: [UTType] { promises.flatMap(\.fileTypes).compactMap { UTType($0) } }
    }

    /// What a drag will be sent as.
    enum Kind: Equatable {
        case files([URL])
        case promisedFiles(names: [String], type: UTType?)
        case image
        case link(URL)
        case text(String)
    }

    /// Files win; then images (a dragged picture also carries its URL);
    /// then links (an address-bar drag may also promise a .webloc); then
    /// other promised files; then plain or rich text.
    static func kind(of snapshot: Snapshot) -> Kind? {
        if !snapshot.files.isEmpty { return .files(snapshot.files) }
        let promisesImage = !snapshot.promises.isEmpty && !snapshot.promisedTypes.isEmpty
            && snapshot.promisedTypes.allSatisfy { $0.conforms(to: .image) }
        if snapshot.image != nil || promisesImage { return .image }
        if let link = snapshot.link { return .link(link) }
        if !snapshot.promises.isEmpty {
            return .promisedFiles(names: snapshot.promisedNames, type: snapshot.promisedTypes.first)
        }
        if let text = snapshot.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let url = webURL(text) { return .link(url) }
            return .text(text)
        }
        return nil
    }

    /// A string that is exactly one web address.
    static func webURL(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }

    static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        var snapshot = Snapshot()
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            snapshot.files = urls
            return snapshot
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            snapshot.promises = promises
        }
        if let data = pasteboard.data(forType: .png) {
            snapshot.image = (data, .png)
        } else if let data = pasteboard.data(forType: .tiff) {
            snapshot.image = (data, .tiff)
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first(where: { !$0.isFileURL }) {
            snapshot.link = url
            snapshot.linkTitle = pasteboard.string(forType: urlNameType)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = pasteboard.string(forType: .string) {
            snapshot.text = text
        } else if let data = pasteboard.data(forType: .rtf),
                  let rich = NSAttributedString(rtf: data, documentAttributes: nil) {
            snapshot.text = rich.string
        } else if let data = pasteboard.data(forType: .html),
                  let rich = NSAttributedString(html: data, documentAttributes: nil) {
            snapshot.text = rich.string
        }
        return snapshot
    }

    /// Resolves a snapshot into payloads: real files, promised files
    /// (Photos, Mail, browsers), image data, a link, or text.
    static func payloads(from snapshot: Snapshot) async -> [DropPayload] {
        switch kind(of: snapshot) {
        case .files(let urls):
            return urls.map { .file($0) }
        case .image:
            if !snapshot.promises.isEmpty {
                let files = await receive(snapshot.promises)
                if !files.isEmpty { return files.map { .file($0) } }
            }
            if let (data, type) = snapshot.image { return [.image(data, type)] }
            return []
        case .link(let url):
            // Sent as text so Telegram shows a link preview.
            return [.text(url.absoluteString)]
        case .promisedFiles:
            return await receive(snapshot.promises).map { .file($0) }
        case .text(let text):
            return [.text(text)]
        case nil:
            return []
        }
    }

    /// The snapshot with its file promises received into the outbox and
    /// turned into plain files, so it stays sendable after the drag is over.
    static func resolved(_ snapshot: Snapshot) async -> Snapshot {
        guard !snapshot.promises.isEmpty else { return snapshot }
        let files = await receive(snapshot.promises)
        var result = snapshot
        result.promises = []
        if !files.isEmpty {
            // Received files win, as they would at send time.
            result.files = files
        }
        return result
    }

    private final class PromiseCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        private var finished = false

        func add(_ url: URL) {
            lock.withLock { urls.append(url) }
        }

        /// True only for the first caller.
        func finish() -> Bool {
            lock.withLock {
                defer { finished = true }
                return !finished
            }
        }

        var sortedURLs: [URL] {
            lock.withLock { urls.sorted { $0.lastPathComponent < $1.lastPathComponent } }
        }
    }

    private static func receive(_ promises: [NSFilePromiseReceiver]) async -> [URL] {
        let folder = AppPaths.newOutboxFolder()
        let queue = OperationQueue()
        let collector = PromiseCollector()
        let group = DispatchGroup()
        for promise in promises {
            // One receiver can promise several files; the reader runs once per file.
            let expected = max(1, promise.fileNames.count)
            for _ in 0..<expected { group.enter() }
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                if error == nil { collector.add(url) }
                group.leave()
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) {
                if collector.finish() { continuation.resume() }
            }
            // A source app that never delivers must not leave the drop hanging.
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                if collector.finish() { continuation.resume() }
            }
        }
        return collector.sortedURLs
    }
}
