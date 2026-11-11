import AppKit
import ThreadlightCore

/// The Codex emblem is a separately attributed vendor asset. State markers are
/// drawn here and are part of Threadlight's source code.
enum SignalArtwork {
    static let frameCount = 24
    static let markerSize = NSSize(width: 13, height: 16)

    private static var packagedLogo: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Threadlight_Threadlight.bundle/codex.svg")
    }
    static var hasPackagedArtwork: Bool { packagedLogo.flatMap(NSImage.init(contentsOf:)) != nil }
    private static let logo: NSImage? = {
        if Bundle.main.bundleURL.pathExtension == "app" { return packagedLogo.flatMap(NSImage.init(contentsOf:)) }
        // SwiftPM puts resources beside the development executable. Resolve
        // them at runtime so distributed binaries contain no build-machine path.
        let resource = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("Threadlight_Threadlight.bundle/codex.svg")
        return resource.flatMap(NSImage.init(contentsOf:))
    }()

    static func emblem(in rect: NSRect, ink: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        logo?.draw(in: rect)
        ink.setFill(); rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func mark(_ phase: Phase, frame: Int, dark: Bool) -> NSImage {
        NSImage(size: markerSize, flipped: false) { rect in
            if phase == .finished {
                NSColor.systemGreen.setStroke()
                let path = NSBezierPath(); path.lineWidth = 1.5; path.lineCapStyle = .round; path.lineJoinStyle = .round
                path.move(to: NSPoint(x: 2, y: 8)); path.line(to: NSPoint(x: 5, y: 5)); path.line(to: NSPoint(x: 11, y: 11)); path.stroke()
            } else {
                // Clockwise head leads. The tail fades behind it, without a gap.
                let head = Double.pi / 2 - Double(frame) * 2 * .pi / Double(frameCount)
                for part in 0..<96 {
                    let tail = Double(part) / 96
                    let opacity = 0.14 + 0.76 * pow(1 - tail, 1.8)
                    NSColor(white: dark ? 0.94 : 0.12, alpha: opacity).setStroke()
                    let start = head + tail * 2 * .pi
                    let end = start + 2 * .pi / 96 * 1.08
                    let arc = NSBezierPath(); arc.lineWidth = 1.05
                    arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: 4.45,
                                  startAngle: CGFloat(start * 180 / .pi), endAngle: CGFloat(end * 180 / .pi), clockwise: false)
                    arc.stroke()
                }
            }
            return true
        }
    }

    static func bar(_ rows: [DisplayRow], frame: Int, dark: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let ink = dark ? NSColor.white : NSColor.black
        let widths = rows.map { ($0.marker as NSString).size(withAttributes: [.font: font]).width + 15 }
        let total = 16 + widths.reduce(0, +)
        return NSImage(size: NSSize(width: total, height: 22), flipped: false) { _ in
            emblem(in: NSRect(x: 1, y: 4, width: 13, height: 14), ink: ink)
            var x: CGFloat = 16
            for (index, row) in rows.enumerated() {
                let text = row.marker as NSString
                text.draw(at: NSPoint(x: x, y: 4), withAttributes: [.font: font, .foregroundColor: ink])
                let textWidth = widths[index] - 15
                mark(row.phase, frame: frame, dark: dark).draw(in: NSRect(x: x + textWidth + 1, y: 3, width: 13, height: 16))
                x += widths[index]
            }
            return true
        }
    }
}

struct DisplayRow: Equatable {
    let id: ChatID
    let marker: String
    let title: String
    let phase: Phase
    init(_ indicator: Indicator) {
        id = indicator.id; marker = indicator.marker; title = indicator.title; phase = indicator.phase
    }
    var stateText: String { phase == .working ? "运行中" : "已完成" }
    var tooltip: String { "\(id.client.label) · \(title)（\(stateText)）" }
}
