import AppKit
import ThreadlightCore

final class AgentApplication: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let surfaces = StableMenu()
    private let queue = DispatchQueue(label: "Threadlight.metadata", qos: .utility)
    private let monitor = LocalMonitor()
    private let loginItem = LoginItemController()
    private let ledgerFile = MonitorPaths.local.storage.appendingPathComponent("ledger-v1.json")
    private var ledger = ActivityLedger()
    private var rows: [DisplayRow] = []
    private var floating: FloatingList?
    private var polling: Timer?
    private var animation: Timer?
    private var inFlight = false
    private var terminating = false
    private var isMenuOpen = false
    private var frame = 0
    private var lastSaved = Date.distantPast
    private var lastSave: Data?
    private var appearance: NSAppearance.Name?
    private var barFrames: [NSImage] = []
    private var workingFrames: [NSImage] = []
    private var complete: NSImage?
    private var notices: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = try? Data(contentsOf: ledgerFile), let value = try? JSONDecoder().decode(ActivityLedger.self, from: data) { ledger = value }
        item.menu = surfaces.menu; surfaces.menu.delegate = self
        item.button?.setAccessibilityLabel("Threadlight 对话灯")
        item.button?.imagePosition = .imageOnly; item.button?.imageScaling = .scaleNone
        repaint(force: true); poll()
        polling = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(polling!, forMode: .eventTracking)
        if UserDefaults.standard.object(forKey: "listIsPinned") as? Bool ?? true { showList() }
        if ProcessInfo.processInfo.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.item.button?.performClick(nil) }
        }
    }

    private func poll() {
        guard !inFlight else { return }; inFlight = true
        let watched = ledger.watched
        queue.async { [monitor] in
            let report = monitor.poll(watched: watched)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false; self.notices = report.notices
                let prior = self.rows
                self.ledger.apply(report.readings)
                self.rows = self.ledger.visible.map(DisplayRow.init)
                let changed = prior != self.rows
                self.repaint(force: changed)
                if changed {
                    self.floating?.update(self.rows, target: self, action: #selector(self.openListRow(_:)))
                    self.surfaces.update(rows: self.rows, pinned: self.floating != nil)
                }
                if changed || Date().timeIntervalSince(self.lastSaved) > 5 { self.saveLedger() }
            }
        }
    }

    private func saveLedger() {
        lastSaved = Date()
        guard let data = try? JSONEncoder().encode(ledger), data != lastSave else { return }
        lastSave = data
        let location = ledgerFile
        queue.async {
            do {
                try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: location, options: .atomic)
            } catch { /* The live monitor still works without persistence. */ }
        }
    }

    private func repaint(force: Bool) {
        let current = item.button?.effectiveAppearance.name
        if force || appearance != current {
            appearance = current
            let dark = item.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let count = rows.contains { $0.phase == .working } ? SignalArtwork.frameCount : 1
            barFrames = (0..<count).map { SignalArtwork.bar(rows, frame: $0, dark: dark) }
            workingFrames = (0..<SignalArtwork.frameCount).map { SignalArtwork.mark(.working, frame: $0, dark: dark) }
            complete = SignalArtwork.mark(.finished, frame: 0, dark: dark)
            item.length = (barFrames.first?.size.width ?? 16) + 2
        }
        let details = rows.map { "\($0.marker) · \($0.title)（\($0.stateText)）" }
        item.button?.toolTip = (["Threadlight 对话灯"] + details + notices).joined(separator: "\n")
        item.button?.setAccessibilityValue("\(rows.filter { $0.phase == .working }.count) 个运行中")
        drawFrame()
        let animate = rows.contains { $0.phase == .working } && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate && animation == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.frame = (self.frame + 1) % SignalArtwork.frameCount
                self.drawFrame()
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .eventTracking); animation = timer
        } else if !animate { animation?.invalidate(); animation = nil }
    }

    private func drawFrame() {
        guard !barFrames.isEmpty else { return }
        item.button?.image = barFrames[frame % barFrames.count]
        for row in rows {
            let image = row.phase == .working ? workingFrames[frame % workingFrames.count] : complete
            floating?.canvas.buttons[row.id]?.image = image
            if isMenuOpen { surfaces.updateTaskMarker(row.id, image: image) }
        }
        // If a read task vanished during tracking, keep its row stable and completed.
        if isMenuOpen {
            for id in surfaces.taskItems.keys where !rows.contains(where: { $0.id == id }) { surfaces.updateTaskMarker(id, image: complete) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        surfaces.open(rows: rows, pinned: floating != nil, loginStatus: loginItem.status, target: self,
                      rowAction: #selector(openMenuRow(_:)), pinAction: #selector(toggleList),
                      loginAction: #selector(toggleLoginItem), quitAction: #selector(quit))
        drawFrame()
    }
    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true; surfaces.beginTracking(); drawFrame() }
    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false; surfaces.endTracking() }

    @objc private func openMenuRow(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? ChatID, let url = id.link { NSWorkspace.shared.open(url) }
    }
    @objc private func openListRow(_ sender: NSButton) {
        if let row = rows.first(where: { $0.id.client.rawValue + ":" + $0.id.rawValue == sender.identifier?.rawValue }), let url = row.id.link { NSWorkspace.shared.open(url) }
    }
    @objc private func toggleList() { if let floating { floating.panel.close() } else { showList() } }
    @objc private func toggleLoginItem() {
        let status = loginItem.status
        do {
            try loginItem.setEnabled(status != .enabled && status != .requiresApproval)
            surfaces.updateLoginStatus(loginItem.status)
            if loginItem.status == .requiresApproval {
                let alert = NSAlert()
                alert.messageText = "自启动需要系统允许"
                alert.informativeText = "请在系统设置的“通用 → 登录项”中允许对话灯。"
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "稍后")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { loginItem.openSystemSettings() }
            }
        } catch {
            surfaces.updateLoginStatus(loginItem.status)
            let alert = NSAlert()
            alert.messageText = "无法更改开机自启动"
            alert.informativeText = "请将对话灯放在“应用程序”文件夹后重试。\n\(error.localizedDescription)"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    private func showList() {
        let list = FloatingList()
        list.onClose = { [weak self] in
            guard let self else { return }
            self.floating = nil
            if !self.terminating { UserDefaults.standard.set(false, forKey: "listIsPinned") }
        }
        floating = list; UserDefaults.standard.set(true, forKey: "listIsPinned")
        list.update(rows, target: self, action: #selector(openListRow(_:)))
        drawFrame(); list.panel.orderFrontRegardless()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        terminating = true; polling?.invalidate(); animation?.invalidate()
        // Finish pending cache work without touching either monitored app.
        if let data = try? JSONEncoder().encode(ledger) {
            queue.sync { try? data.write(to: ledgerFile, options: .atomic) }
        }
    }
}
