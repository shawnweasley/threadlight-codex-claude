import AppKit
import Testing
@testable import Threadlight
@testable import ThreadlightCore

@MainActor private final class Actions: NSObject {
    @objc func open(_ sender: NSMenuItem) {}
    @objc func pin() {}
    @objc func quit() {}
    @objc func login() {}
}

@Suite @MainActor struct SurfaceTests {
    private func rows() -> [DisplayRow] {
        var ledger = ActivityLedger()
        ledger.apply([Reading(id: ChatID(.codex, "synthetic"), title: "一个用于检查截断与缩放的合成标题", phase: .working)])
        return ledger.visible.map(DisplayRow.init)
    }

    @Test func menuPollingKeepsFooterAndRowsUnderPointer() {
        _ = NSApplication.shared
        let surface = StableMenu(), target = Actions(), rows = rows()
        surface.open(rows: rows, pinned: true, loginStatus: .disabled, target: target, rowAction: #selector(Actions.open(_:)), pinAction: #selector(Actions.pin), loginAction: #selector(Actions.login), quitAction: #selector(Actions.quit))
        let items = surface.menu.items
        let loginItem = surface.menu.items.first { $0.title == "允许开机自启动" }
        #expect(loginItem?.state == .off)
        #expect(loginItem?.action == #selector(Actions.login))
        #expect(surface.menu.showsStateColumn)
        surface.beginTracking()
        for _ in 0..<20 {
            surface.update(rows: [], pinned: true)
            surface.updateLoginStatus(.enabled)
            let marker = SignalArtwork.mark(.finished, frame: 0, dark: false)
            surface.updateTaskMarker(rows[0].id, image: marker)
            #expect(surface.taskItems[rows[0].id]?.offStateImage === marker)
            #expect(surface.taskItems[rows[0].id]?.state == .off)
            #expect(surface.menu.items.allSatisfy { $0.image == nil })
            surface.open(rows: [], pinned: true, loginStatus: .disabled, target: target, rowAction: #selector(Actions.open(_:)), pinAction: #selector(Actions.pin), loginAction: #selector(Actions.login), quitAction: #selector(Actions.quit))
        }
        #expect(surface.menu.items.elementsEqual(items, by: { $0 === $1 }))
        #expect(loginItem?.state == .on)
        surface.updateLoginStatus(.requiresApproval)
        #expect(loginItem?.state == .mixed)
        #expect(surface.taskItems[rows[0].id]?.title.hasSuffix("已完成") == true)
        surface.endTracking()
        surface.open(rows: [], pinned: true, loginStatus: .disabled, target: target, rowAction: #selector(Actions.open(_:)), pinAction: #selector(Actions.pin), loginAction: #selector(Actions.login), quitAction: #selector(Actions.quit))
        #expect(surface.taskItems.isEmpty)
        #expect(surface.menu.items.first { $0.title == "允许开机自启动" }?.state == .off)
    }

    @Test func listHidesRightTextOnNarrowWidthsAndRestoresWithoutOverlap() {
        _ = NSApplication.shared
        let canvas = TaskListCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
        let rows = rows(), id = rows[0].id
        canvas.update(rows, target: nil, action: nil)
        let button = canvas.buttons[id]!
        #expect(canvas.labels[id]?.isHidden == false)
        canvas.setFrameSize(NSSize(width: 150, height: 36))
        #expect(canvas.labels[id]?.isHidden == true)
        #expect(button.frame.minX == 8 && button.frame.maxX == 142)
        #expect(button.lineBreakMode == .byTruncatingTail)
        canvas.setFrameSize(NSSize(width: 440, height: 36))
        #expect(canvas.labels[id]?.isHidden == false)
        #expect(button.frame.maxX < canvas.labels[id]!.frame.minX)
        canvas.update(rows, target: nil, action: nil)
        #expect(canvas.buttons[id] === button)
    }

    @Test func panelOnlyResizesHorizontallyAndKeepsWidthWhenRowsChange() {
        _ = NSApplication.shared
        let window = FloatingList(autosave: "Threadlight.Tests." + UUID().uuidString)
        window.update(rows(), target: nil, action: nil)
        #expect(window.panel.styleMask.contains(.resizable))
        #expect(window.panel.contentMinSize.height == window.panel.contentMaxSize.height)
        var frame = window.panel.frame; frame.size.width = 190
        window.panel.setFrame(frame, display: false)
        window.update([], target: nil, action: nil)
        #expect(window.panel.contentView!.bounds.width == 190)
        #expect(window.panel.contentMinSize.width == 150)
    }

    @Test func inactivePanelShowsResizeCursorAtBothEdgesAndClearsItInside() throws {
        _ = NSApplication.shared
        let window = FloatingList(autosave: "Threadlight.Tests.Cursor." + UUID().uuidString)
        window.update(rows(), target: nil, action: nil)
        let surface = try #require(window.panel.contentView as? HorizontalResizeScrollView)
        #expect(!window.panel.isKeyWindow)
        let previous = NSCursor.current
        defer { previous.set() }
        func event(at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: surface.convert(point, to: nil),
                                               modifierFlags: [], timestamp: 0, windowNumber: window.panel.windowNumber,
                                               context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        for width in [CGFloat(320), 180, 440] {
            var frame = window.panel.frame; frame.size.width = width
            window.panel.setFrame(frame, display: false)
            surface.updateTrackingAreas()
            for x in [surface.bounds.minX + 1, surface.bounds.maxX - 1] {
                NSCursor.arrow.set()
                surface.mouseEntered(with: try event(at: NSPoint(x: x, y: surface.bounds.midY)))
                #expect(NSCursor.current === NSCursor.resizeLeftRight)
            }
            surface.mouseExited(with: try event(at: NSPoint(x: surface.bounds.midX, y: surface.bounds.midY)))
            #expect(NSCursor.current === NSCursor.arrow)
            #expect(surface.trackingAreas.filter { $0.options.contains(.activeAlways) && $0.options.contains(.cursorUpdate) }.count == 2)
        }
    }
}
