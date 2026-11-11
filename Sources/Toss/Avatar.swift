import AppKit
import SwiftUI

/// A send target shown in the menu bar and panel.
struct Target: Identifiable, Equatable {
    let id: Int64
    var name: String
    var photoPath: String?
    var isSavedMessages: Bool
    var thumbnail: Data? = nil

    /// Telegram's seven avatar colors, picked by id like the official apps.
    var colors: (NSColor, NSColor) {
        let palette: [(UInt32, UInt32)] = [
            (0xFF885E, 0xFF516A), (0xFFCD6A, 0xFFA85C), (0x82B1FF, 0x665FFF), (0xA0DE7E, 0x54CB68),
            (0x53EDD6, 0x28C9B7), (0x72D5FD, 0x2A9EF1), (0xE0A2F3, 0xD669ED),
        ]
        if isSavedMessages { return (NSColor(hex: 0x72D5FD), NSColor(hex: 0x2A9EF1)) }
        let pair = palette[Int(abs(id) % Int64(palette.count))]
        return (NSColor(hex: pair.0), NSColor(hex: pair.1))
    }

    var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

enum AvatarRenderer {
    private static var cache: [String: NSImage] = [:]

    static func photo(_ path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        if let cached = cache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = image
        return image
    }

    private static var thumbnails: [Data: NSImage] = [:]

    static func thumbnail(_ data: Data?) -> NSImage? {
        guard let data else { return nil }
        if let cached = thumbnails[data] { return cached }
        guard let image = NSImage(data: data) else { return nil }
        thumbnails[data] = image
        return image
    }

    /// Draws a circular avatar filling `rect` in the current graphics context.
    static func draw(_ target: Target, in rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        if let image = photo(target.photoPath) ?? thumbnail(target.thumbnail) {
            image.draw(in: aspectFill(image.size, in: rect), from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let (top, bottom) = target.colors
            NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
            if target.isSavedMessages {
                drawSymbol("bookmark.fill", in: rect)
            } else {
                drawInitials(target.initials, in: rect)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func image(_ target: Target, diameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            draw(target, in: rect)
            return true
        }
    }

    private static func aspectFill(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    private static func drawInitials(_ text: String, in rect: NSRect) {
        let font = NSFont.systemFont(ofSize: rect.height * (text.count > 1 ? 0.38 : 0.46), weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private static func drawSymbol(_ name: String, in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.45, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height))
    }
}

/// SwiftUI avatar for settings lists.
struct AvatarView: View {
    let target: Target
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: AvatarRenderer.image(target, diameter: size))
            .resizable()
            .frame(width: size, height: size)
    }
}
