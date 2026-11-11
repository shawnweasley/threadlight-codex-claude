import AppKit
import ThreadlightCore

final class StableMenu {
    let menu = NSMenu()
    private(set) var taskItems: [ChatID: NSMenuItem] = [:]
    private var snapshot: [DisplayRow] = []
    private var summary: NSMenuItem?
    private var pin: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var tracking = false

    init() {
        // Use only AppKit's state column. Hiding it does not reliably suppress
        // native checkmarks on every macOS version, so never duplicate them in image.
        menu.showsStateColumn = true
    }

    private func setCheckmark(_ item: NSMenuItem?, state: NSControl.StateValue) {
        item?.state = state
        item?.image = nil
    }

    func updateTaskMarker(_ id: ChatID, image: NSImage?) {
        // A task is an action, not a checked preference. Its off-state image
        // occupies the same native column as preference checkmarks.
        taskItems[id]?.offStateImage = image
    }

    func open(rows: [DisplayRow], pinned: Bool, loginStatus: LoginItemStatus, target: AnyObject, rowAction: Selector, pinAction: Selector, loginAction: Selector, quitAction: Selector) {
        guard !tracking else { return }
        menu.removeAllItems(); taskItems.removeAll(); snapshot = rows
        let summary = NSMenuItem(title: summaryText(rows), action: nil, keyEquivalent: "")
        summary.isEnabled = false; self.summary = summary; menu.addItem(summary)
        menu.addItem(.separator())
        if rows.isEmpty {
            let item = NSMenuItem(title: "暂无运行中或完成未读的对话", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }
        for row in rows {
            let item = NSMenuItem(title: line(row), action: rowAction, keyEquivalent: "")
            item.target = target; item.representedObject = row.id; item.toolTip = row.tooltip
            menu.addItem(item); taskItems[row.id] = item
        }
        menu.addItem(.separator())
        let pin = NSMenuItem(title: pinned ? "取消固定列表" : "固定列表", action: pinAction, keyEquivalent: "")
        pin.target = target; setCheckmark(pin, state: pinned ? .on : .off)
        menu.addItem(pin); self.pin = pin
        let loginItem = NSMenuItem(title: "允许开机自启动", action: loginAction, keyEquivalent: "")
        loginItem.target = target; menu.addItem(loginItem); self.loginItem = loginItem
        updateLoginStatus(loginStatus)
        let quit = NSMenuItem(title: "退出对话灯", action: quitAction, keyEquivalent: "q")
        quit.target = target; menu.addItem(quit)
    }
    func beginTracking() { tracking = true }
    func endTracking() { tracking = false }

    func updateLoginStatus(_ status: LoginItemStatus) {
        switch status {
        case .enabled:
            setCheckmark(loginItem, state: .on)
            loginItem?.toolTip = "登录 Mac 时自动启动对话灯"
        case .requiresApproval:
            setCheckmark(loginItem, state: .mixed)
            loginItem?.toolTip = "等待在系统设置的登录项中允许；再次点击可取消"
        case .disabled, .unavailable:
            setCheckmark(loginItem, state: .off)
            loginItem?.toolTip = "登录 Mac 时自动启动对话灯"
        }
    }

    func update(rows: [DisplayRow], pinned: Bool) {
        let text = summaryText(rows)
        if summary?.title != text { summary?.title = text }
        let pinTitle = pinned ? "取消固定列表" : "固定列表"
        if pin?.title != pinTitle { pin?.title = pinTitle }
        setCheckmark(pin, state: pinned ? .on : .off)
        for prior in snapshot {
            guard let item = taskItems[prior.id] else { continue }
            if let row = rows.first(where: { $0.id == prior.id }) {
                if item.title != line(row) { item.title = line(row); item.toolTip = row.tooltip }
            } else {
                let finished = line(prior, phase: .finished)
                if item.title != finished {
                    item.title = finished
                    item.toolTip = "\(prior.id.client.label) · \(prior.title)（已完成）"
                }
            }
            // Removed rows keep their native height until the next opening.
        }
    }
    private func line(_ row: DisplayRow, phase: Phase? = nil) -> String {
        let title = row.title.count > 32 ? String(row.title.prefix(31)) + "…" : row.title
        let text = (phase ?? row.phase) == .working ? "运行中" : "已完成"
        return "\(row.marker)　\(title)　· \(text)"
    }
    private func summaryText(_ rows: [DisplayRow]) -> String {
        let working = rows.filter { $0.phase == .working }.count
        let done = rows.count - working
        return done == 0 ? "\(working) 个运行中" : "\(working) 个运行中 · \(done) 个完成待查看"
    }
}

final class TaskListCanvas: NSView {
    private(set) var buttons: [ChatID: NSButton] = [:]
    private(set) var labels: [ChatID: NSTextField] = [:]
    private var order: [ChatID] = []
    private let empty = NSTextField(labelWithString: "暂无运行中或完成未读的对话")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor
        empty.lineBreakMode = .byTruncatingTail; addSubview(empty)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ rows: [DisplayRow], target: AnyObject?, action: Selector?) {
        let wanted = Set(rows.map(\.id))
        for id in Array(buttons.keys) where !wanted.contains(id) {
            buttons.removeValue(forKey: id)?.removeFromSuperview()
            labels.removeValue(forKey: id)?.removeFromSuperview()
        }
        order = rows.map(\.id); empty.isHidden = !rows.isEmpty
        for row in rows {
            let button = buttons[row.id] ?? NSButton(title: "", target: target, action: action)
            if buttons[row.id] == nil {
                button.isBordered = false; button.alignment = .left; button.imagePosition = .imageLeading
                button.focusRingType = .none; button.refusesFirstResponder = true
                button.font = .systemFont(ofSize: 12); button.lineBreakMode = .byTruncatingTail
                button.identifier = NSUserInterfaceItemIdentifier(row.id.client.rawValue + ":" + row.id.rawValue)
                addSubview(button); buttons[row.id] = button
            }
            button.title = "\(row.marker)　\(row.title)"
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12)])
            button.toolTip = row.tooltip
            let label = labels[row.id] ?? NSTextField(labelWithString: "")
            if labels[row.id] == nil { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; addSubview(label); labels[row.id] = label }
            label.stringValue = row.stateText
        }
        arrange()
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); arrange() }
    private func arrange() {
        let showStatus = bounds.width >= 270
        for (index, id) in order.enumerated() {
            let y = CGFloat(index) * 28 + 4
            buttons[id]?.frame = NSRect(x: 8, y: y, width: max(20, bounds.width - (showStatus ? 69 : 16)), height: 28)
            labels[id]?.isHidden = !showStatus
            labels[id]?.frame = NSRect(x: bounds.width - 55, y: y + 6, width: 47, height: 16)
        }
        empty.frame = NSRect(x: 8, y: 10, width: max(20, bounds.width - 16), height: 18)
    }
}

/// Nonactivating panels do not reliably receive the standard key-window resize
/// cursor. Track the two content edges even while another app is active, while
/// leaving mouse-down and drag handling to AppKit's native window resizing.
final class HorizontalResizeScrollView: NSScrollView {
    private var edgeTracking: [NSTrackingArea] = []
    var resizeEdges: [NSRect] {
        let width = min(CGFloat(5), bounds.width / 2)
        return [NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height),
                NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)]
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in resizeEdges { addCursorRect(rect, cursor: .resizeLeftRight) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in edgeTracking { removeTrackingArea(area) }
        edgeTracking = resizeEdges.map {
            NSTrackingArea(rect: $0, options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag], owner: self)
        }
        for area in edgeTracking { addTrackingArea(area) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    private func atEdge(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return resizeEdges.contains { $0.contains(point) }
    }
    override func cursorUpdate(with event: NSEvent) {
        if atEdge(event) { NSCursor.resizeLeftRight.set() } else { super.cursorUpdate(with: event) }
    }
    override func mouseEntered(with event: NSEvent) {
        if atEdge(event) { NSCursor.resizeLeftRight.set() } else { super.mouseEntered(with: event) }
    }
    override func mouseExited(with event: NSEvent) {
        if !atEdge(event) { NSCursor.arrow.set() }
        super.mouseExited(with: event)
    }
}

final class FloatingList: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let canvas: TaskListCanvas
    private let scroll = HorizontalResizeScrollView()
    var onClose: (() -> Void)?

    init(autosave: String = "Threadlight.TaskList") {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        canvas = TaskListCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        super.init()
        panel.title = "任务列表"; panel.level = .floating
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.delegate = self
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]; canvas.autoresizingMask = [.width]
        scroll.documentView = canvas; panel.contentView = scroll
        if let visible = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: visible.maxX - 330, y: visible.maxY - 170)) }
        panel.setFrameAutosaveName(autosave); _ = panel.setFrameUsingName(autosave)
    }

    func update(_ rows: [DisplayRow], target: AnyObject?, action: Selector?) {
        let documentHeight = max(36, CGFloat(rows.count) * 28 + 8)
        let height = min(288, documentHeight)
        let old = panel.frame
        panel.contentMaxSize = NSSize(width: 10000, height: max(height, panel.contentMinSize.height))
        panel.contentMinSize = NSSize(width: 150, height: height)
        panel.contentMaxSize = NSSize(width: 10000, height: height)
        let width = max(150, panel.contentView?.bounds.width ?? 320)
        let frame = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - frame.height, width: frame.width, height: frame.height), display: true)
        scroll.hasVerticalScroller = documentHeight > height
        canvas.setFrameSize(NSSize(width: scroll.contentSize.width, height: documentHeight))
        canvas.update(rows, target: target, action: action)
    }
    func windowDidResize(_ notification: Notification) {
        canvas.setFrameSize(NSSize(width: scroll.contentSize.width, height: canvas.frame.height))
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
