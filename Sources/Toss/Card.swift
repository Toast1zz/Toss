import AppKit
import LinkPresentation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// What the preview card shows for the thing being dragged.
enum CardContent: Equatable {
    case link(URL)
    case text(String)
    case image(NSImage?)
    case files(names: [String], icon: NSImage?)
    /// The clipboard holds nothing Toss can send.
    case empty

    var isLink: Bool { if case .link = self { true } else { false } }
}

/// Builds the card for a drag in progress and fills in what loads later
/// (page titles, favicons, Quick Look thumbnails).
@MainActor
final class CardLoader: ObservableObject {
    struct LinkInfo: Equatable {
        var title: String?
        var icon: NSImage?
    }

    @Published private(set) var links: [URL: LinkInfo] = [:]
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    private var providers: [URL: LPMetadataProvider] = [:]

    static let shared = CardLoader()

    func content(for snapshot: DragReader.Snapshot) -> CardContent? {
        switch DragReader.kind(of: snapshot) {
        case .files(let urls):
            let first = urls[0]
            loadThumbnail(first)
            return .files(names: urls.map(\.lastPathComponent), icon: NSWorkspace.shared.icon(forFile: first.path))
        case .promisedFiles(let names, let type):
            let icon = type.map { NSWorkspace.shared.icon(for: $0) }
            return .files(names: names.isEmpty ? [""] : names, icon: icon)
        case .image:
            if let (data, _) = snapshot.image, let image = NSImage(data: data) { return .image(image) }
            return .image(nil)
        case .link(let url):
            if let title = snapshot.linkTitle, !title.isEmpty, links[url]?.title == nil {
                links[url, default: LinkInfo()].title = title
            }
            loadLink(url)
            return .link(url)
        case .text(let text):
            return .text(text)
        case nil:
            return nil
        }
    }

    func title(for url: URL) -> String { links[url]?.title ?? url.host() ?? url.absoluteString }
    func icon(for url: URL) -> NSImage? { links[url]?.icon }

    /// The page's own title (og:title or <title>) and favicon, fetched in the background.
    private func loadLink(_ url: URL) {
        guard providers[url] == nil, links[url]?.icon == nil else { return }
        let provider = LPMetadataProvider()
        provider.timeout = 6
        providers[url] = provider
        provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
            let title = metadata?.title
            let iconProvider = metadata?.iconProvider
            Task { @MainActor in
                guard let self else { return }
                if let title, !title.isEmpty { self.links[url, default: LinkInfo()].title = title }
                iconProvider?.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage else { return }
                    Task { @MainActor in self.links[url, default: LinkInfo()].icon = image }
                }
            }
        }
    }

    private func loadThumbnail(_ url: URL) {
        guard thumbnails[url] == nil else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 96, height: 96), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor in self?.thumbnails[url] = image }
        }
    }
}
