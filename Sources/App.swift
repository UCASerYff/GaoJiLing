import AppKit
import SwiftUI
import Carbon
import Combine

@main enum GaoJiLingMain {
    static func main() {
        if CommandLine.arguments.contains("--sample-json") {
            let collector = MetricsCollector()
            _ = collector.sample(); Thread.sleep(forTimeInterval: 1)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(collector.sample()), let value = String(data: data, encoding: .utf8) { print(value) }
            return
        }
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class MonitorPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performMiniaturize(_ sender: Any?) { dismiss?() }
    override func miniaturize(_ sender: Any?) { dismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss?() } else { super.keyDown(with: event) }
    }
}

final class MonitorPanelContentView: NSHostingView<PanelView> {
    var pointerChanged: ((NSPoint) -> Void)?
    private var pointerArea: NSTrackingArea?
    override func updateTrackingAreas() {
        if let pointerArea { removeTrackingArea(pointerArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero,
                                  options: [.inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                  owner: self, userInfo: nil)
        pointerArea = area
        addTrackingArea(area)
    }
    private func trackPointer(_ event: NSEvent) {
        guard let window else { return }
        pointerChanged?(window.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseEntered(with event: NSEvent) { trackPointer(event) }
    override func mouseExited(with event: NSEvent) { trackPointer(event) }
    override func mouseMoved(with event: NSEvent) { trackPointer(event) }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: MonitorStore!
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private let settingsNavigation = GLSettingsNavigation()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var edgeHandle: EdgeHandleController?
    private var edgeTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var panelAutoCollapse = PanelAutoCollapse()
    private var panelContentHeight: CGFloat = 620
    private var openingStripFrame: NSRect?
    private var panelExpansionEdge = "right"
    private var panelDragOffset: NSSize?
    private var panelDragScreen: NSScreen?
    private var panelDidDrag = false
    private var panelDragStart: NSPoint?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var statusClickAlreadyCollapsed = false
    private var suppressEdgeUntil = Date.distantPast
    private var hotkey: EventHotKeyRef?
    private var hotkeyHandler: EventHandlerRef?
    private var terminationSignal: DispatchSourceSignal?
    private var pendingTermination = false
    private var panelMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.gaoseries.GaoJiLing").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.regular)
        store = MonitorStore()
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal?.setEventHandler { NSApp.terminate(nil) }
        terminationSignal?.resume()
        configureMainMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "搞机灵 V\(GLPalette.version)"
        window.identifier = NSUserInterfaceItemIdentifier("GaoJiLing.Main")
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 960, height: 690)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: DashboardView(store: store, openSettings: { [weak self] in self?.showSettings() }))
        window.setFrameAutosaveName("GaoJiLing.MainWindow")
        if !window.setFrameUsingName("GaoJiLing.MainWindow") { window.center() }

        let overlay = MonitorPanel(contentRect: NSRect(x: 0, y: 0, width: 398, height: panelContentHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.dismiss = { [weak self] in self?.hidePanel() }
        panel = overlay
        panel.title = "系统监控面板"
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        updatePanelView()
        configureEdgeHandle()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "搞机灵")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusTapped)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        configurePanelMouseMonitoring()
        store.$latest.sink { [weak self] sample in self?.updateStatus(sample) }.store(in: &subscriptions)
        store.$isPaused.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus(self?.store.latest ?? .empty) } }.store(in: &subscriptions)
        store.$dataBusy.sink { [weak self] busy in
            guard let self, !busy, self.pendingTermination else { return }
            // @Published emits before the stored value changes. Reply on the next
            // main-loop turn, after the data operation's cleanup has completed.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingTermination, !self.store.dataBusy else { return }
                self.pendingTermination = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)), name: .monitorSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsNavigationRequested(_:)), name: .monitorNavigate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resetEdgeHandle), name: .monitorResetEdgeHandle, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dockEdgeHandle), name: .monitorDockEdgeHandle, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeApplicationChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        edgeTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(checkEdge), userInfo: nil, repeats: true)
        if let edgeTimer { RunLoop.main.add(edgeTimer, forMode: .common) }
        settingsChanged()
        showDashboard()
    }
    private func configureMainMenu() {
        let main = NSMenu(); let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于搞机灵…", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        let exportItem = appMenu.addItem(withTitle: "导出与备份…", action: #selector(showData), keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "打开搞机灵", action: #selector(showDashboard), keyEquivalent: "0")
        panelMenuItem = appMenu.addItem(withTitle: "显示边缘面板", action: #selector(togglePanel), keyEquivalent: "g")
        panelMenuItem?.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏搞机灵", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出搞机灵", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        for item in appMenu.items where [#selector(showAbout), #selector(showSettings), #selector(showData), #selector(showDashboard), #selector(togglePanel)].contains(item.action) { item.target = self }
        let edit = NSMenuItem(); edit.title = "编辑"; let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; main.addItem(edit)
        let windowsItem = NSMenuItem()
        windowsItem.title = "窗口"
        let windowsMenu = NSMenu(title: "窗口")
        windowsMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowsMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowsMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowsMenu.addItem(.separator())
        windowsItem.submenu = windowsMenu
        main.addItem(windowsItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowsMenu
    }
    @objc func showDashboard() {
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func showAbout() { showSettingsWindow(tab: .about) }
    @objc private func showSettings() { showSettingsWindow(tab: .module) }
    @objc private func showData() { showSettingsWindow(tab: .data) }
    @objc private func settingsNavigationRequested(_ notification: Notification) {
        guard let destination = notification.object as? String,
              let tab = GLSettingsTab(destination: destination) else { return }
        showSettingsWindow(tab: tab)
    }
    private func showSettingsWindow(tab: GLSettingsTab) {
        // Keep any in-progress save/restore dialog in front and avoid changing
        // its underlying settings tab when a shortcut is pressed again.
        if let modal = NSApp.modalWindow ?? settingsWindow?.attachedSheet {
            NSApp.activate(ignoringOtherApps: true)
            modal.makeKeyAndOrderFront(nil)
            return
        }
        hidePanel()
        settingsNavigation.selectedTab = tab
        if settingsWindow == nil {
            let preferences = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 740),
                                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            preferences.title = "搞机灵设置"
            preferences.identifier = NSUserInterfaceItemIdentifier("GaoJiLing.Settings")
            preferences.minSize = NSSize(width: 680, height: 600)
            preferences.isReleasedWhenClosed = false
            preferences.delegate = self
            preferences.contentView = NSHostingView(rootView: GLSettingsWindowView(store: store, navigation: settingsNavigation))
            preferences.setFrameAutosaveName("GaoJiLing.SettingsWindow")
            if !preferences.setFrameUsingName("GaoJiLing.SettingsWindow") { preferences.center() }
            settingsWindow = preferences
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel { hidePanel() } else { sender.orderOut(nil) }
        return false
    }
    func windowDidResignKey(_ notification: Notification) {
        if let sender = notification.object as? NSWindow, sender === panel { dismissPanelAfterFocusLoss() }
    }
    func applicationDidResignActive(_ notification: Notification) { dismissPanelAfterFocusLoss() }
    @objc private func activeApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        dismissPanelAfterFocusLoss()
    }
    private func dismissPanelAfterFocusLoss() {
        guard panel?.isVisible == true, edgeHandle?.isInteracting != true else { return }
        if panelAutoCollapse.shouldCollapseOnFocusLoss(pressedMouseButtons: UInt(bitPattern: NSEvent.pressedMouseButtons)) { hidePanel() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.dataBusy == true {
            pendingTermination = true
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showDashboard(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        finishPanelDrag()
        edgeTimer?.invalidate()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        edgeHandle?.suspend(); store?.shutdown()
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }
    }
    @objc private func willSleep() { store.prepareForSleep(); hidePanel(); edgeHandle?.suspend() }
    @objc private func didWake() { edgeHandle?.resume() }
    @objc private func screensChanged() { hidePanel(); edgeHandle?.screensChanged() }
    @objc private func resetEdgeHandle() { hidePanel(); edgeHandle?.reset() }
    @objc private func dockEdgeHandle() { hidePanel(); edgeHandle?.dock() }
    @objc private func settingsChanged(_ notification: Notification? = nil) {
        NSApp.appearance = store.settings.appearance == "dark" ? NSAppearance(named: .darkAqua) : store.settings.appearance == "light" ? NSAppearance(named: .aqua) : nil
        updateStatus(store.latest); registerShortcut()
        edgeHandle?.update(enabled: store.settings.edgeEnabled, edge: store.settings.edge,
                           restorePosition: notification?.object as? String == "restored")
        if !store.settings.edgeEnabled { hidePanel() }
    }
    private func updateStatus(_ sample: MetricsSample) {
        guard let button = statusItem?.button else { return }
        button.title = store.isPaused ? " 暂停" : (store.settings.menuBarCPU ? " " + Format.percent(sample.cpuPercent) : "")
        button.toolTip = "搞机灵 · CPU \(Format.percent(sample.cpuPercent)) · 内存 \(Format.bytes(sample.memoryUsed))\n单击打开面板，右键更多选项"
    }
    @objc private func statusTapped() {
        let alreadyCollapsed = statusClickAlreadyCollapsed
        statusClickAlreadyCollapsed = false
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            for (title, action) in [("打开搞机灵", #selector(showDashboard)), ("显示 / 收起面板", #selector(togglePanel)), (store.isPaused ? "继续监控" : "暂停监控", #selector(pause))] { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
            menu.addItem(.separator())
            for (title, action) in [("设置…", #selector(showSettings)), ("导出与备份…", #selector(showData)), ("关于搞机灵…", #selector(showAbout))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            menu.addItem(.separator()); menu.addItem(withTitle: "退出搞机灵", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else if !alreadyCollapsed { togglePanel() }
    }
    private func configurePanelMouseMonitoring() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                          .leftMouseUp, .rightMouseUp, .otherMouseUp]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handlePanelMouseEvent(event, local: true)
            return event // Other windows and controls still receive their click.
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handlePanelMouseEvent(event, local: false)
        }
    }
    private func handlePanelMouseEvent(_ event: NSEvent, local: Bool) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            statusClickAlreadyCollapsed = false
            guard panel.isVisible else { return }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            let inside = local && event.window === panel && PanelHitRegion.contains(point, in: panel.frame)
            if panelAutoCollapse.mouseDown(button: event.buttonNumber, insidePanel: inside) {
                if local, let button = statusItem.button, let buttonWindow = button.window,
                   event.window === buttonWindow {
                    let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
                    statusClickAlreadyCollapsed = buttonFrame.contains(point)
                }
                hidePanel()
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            panelAutoCollapse.mouseUp(button: event.buttonNumber)
            checkPanelPointer()
        default: break
        }
    }
    @objc private func pause() { store.togglePause() }
    private func configureEdgeHandle() {
        let handle = EdgeHandleController()
        handle.onOpen = { [weak self] screen, anchor, manual in
            guard let self, !self.panel.isVisible else { return }
            self.showPanel(on: screen, manual: manual, anchor: anchor, fromStrip: true)
        }
        handle.onDragBegan = { [weak self] in self?.hidePanel() }
        handle.onEdgeChanged = { [weak self] edge in
            guard let self, self.store.settings.edge != edge else { return }
            self.store.settings.edge = edge
            self.store.saveSettings()
        }
        edgeHandle = handle
    }
    @objc func togglePanel() {
        if panel.isVisible { hidePanel() }
        else {
            let screen = currentScreen()
            showPanel(on: screen, manual: true, anchor: edgeHandle?.anchor(on: screen))
        }
    }
    private func currentScreen() -> NSScreen { NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0] }
    private func updatePanelView() {
        let content = MonitorPanelContentView(rootView: PanelView(store: store,
            openDashboard: { [weak self] in self?.showDashboard() },
            contentHeightChanged: { [weak self] height in self?.resizePanel(to: height) },
            panelDragBegan: { [weak self] point in self?.beginPanelDrag(at: point) },
            panelDragged: { [weak self] point in self?.dragPanel(to: point) },
            panelDragEnded: { [weak self] in self?.finishPanelDrag() }))
        content.pointerChanged = { [weak self] point in
            guard let self, self.panel.isVisible else { return }
            // Keep the original event position: a quick pass through the panel
            // must count as an entry even if the current pointer has moved on.
            if PanelHitRegion.contains(point, in: self.panel.frame) {
                _ = self.panelAutoCollapse.shouldCollapse(at: ProcessInfo.processInfo.systemUptime,
                                                          pointerInside: true,
                                                          pressedMouseButtons: UInt(bitPattern: NSEvent.pressedMouseButtons))
            }
            self.checkPanelPointer()
        }
        panel.contentView = content
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 20
        panel.contentView?.layer?.masksToBounds = true
    }
    private func resizePanel(to contentHeight: CGFloat) {
        guard contentHeight.isFinite, contentHeight > 0 else { return }
        let height = max(320, ceil(contentHeight))
        guard abs(height - panelContentHeight) >= 1 else { return }
        panelContentHeight = height
        applyPanelHeight()
    }
    private func applyPanelHeight() {
        guard panel.isVisible, panelDragOffset == nil, let screen = panel.screen else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.size.height = min(panelContentHeight, max(visible.height - 24, 1))
        frame.origin.y = max(visible.minY + 12, min(panel.frame.maxY - frame.height, visible.maxY - frame.height - 12))
        panel.setFrame(frame, display: true)
    }
    private func showPanel(on screen: NSScreen, manual: Bool = false, anchor: NSRect? = nil, fromStrip: Bool = false) {
        let visible = screen.visibleFrame
        let size = NSSize(width: min(398, max(visible.width - 32, 1)), height: min(panelContentHeight, max(visible.height - 24, 1)))
        let strip = anchor ?? EdgeHandleGeometry.frame(in: visible, edge: store.settings.edge, verticalRatio: 0.5)
        let placement = FloatingPanelGeometry.placement(anchor: strip, size: size, in: visible, preferredEdge: store.settings.edge)
        panelExpansionEdge = placement.edge
        panel.setFrame(placement.frame, display: true)
        panelAutoCollapse.opened(at: ProcessInfo.processInfo.systemUptime)
        openingStripFrame = fromStrip ? strip : nil
        _ = panelAutoCollapse.shouldCollapse(at: ProcessInfo.processInfo.systemUptime,
                                             pointerInside: PanelHitRegion.contains(NSEvent.mouseLocation, in: panel.frame))
        panel.alphaValue = 0
        edgeHandle?.setExpanded(true)
        panel.orderFrontRegardless()
        if manual { panel.makeKeyAndOrderFront(nil) }
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; panel.animator().alphaValue = 1 }
    }
    private func beginPanelDrag(at point: NSPoint) {
        guard panel.isVisible else { return }
        panelDragStart = point
        panelDragOffset = NSSize(width: point.x - panel.frame.minX, height: point.y - panel.frame.minY)
        panelDragScreen = panel.screen
        panelDidDrag = false
    }
    private func dragPanel(to point: NSPoint) {
        guard let offset = panelDragOffset, let start = panelDragStart,
              let screen = EdgeHandleScreen.containing(point) ?? panelDragScreen else { return }
        guard panelDidDrag || hypot(point.x - start.x, point.y - start.y) >= EdgeHandleGeometry.dragThreshold else { return }
        panelDidDrag = true
        panelDragScreen = screen
        let frame = FloatingPanelGeometry.draggingFrame(pointer: point, grabOffset: offset, size: panel.frame.size, in: screen.visibleFrame)
        if abs(frame.minX - (screen.visibleFrame.minX + 12)) < 0.5 { panelExpansionEdge = "left" }
        else if abs(frame.maxX - (screen.visibleFrame.maxX - 12)) < 0.5 { panelExpansionEdge = "right" }
        openingStripFrame = nil
        panel.setFrame(frame, display: true)
    }
    private func finishPanelDrag() {
        guard panelDragOffset != nil else { return }
        let didDrag = panelDidDrag; let screen = panelDragScreen
        panelDragOffset = nil; panelDragStart = nil; panelDragScreen = nil; panelDidDrag = false
        applyPanelHeight()
        if didDrag, let screen { edgeHandle?.commitPanelPosition(panel.frame, on: screen, edge: panelExpansionEdge) }
        checkPanelPointer()
    }
    private func hidePanel() {
        guard panel != nil else { return }
        // Save a completed move if Esc, sleep or display changes close the
        // panel before its mouse-up arrives.
        if panelDragOffset != nil {
            let screen = panelDragScreen; let didDrag = panelDidDrag
            panelDragOffset = nil; panelDragStart = nil; panelDragScreen = nil; panelDidDrag = false
            if didDrag, let screen { edgeHandle?.commitPanelPosition(panel.frame, on: screen, edge: panelExpansionEdge) }
        }
        panelAutoCollapse.closed(); openingStripFrame = nil; panel.orderOut(nil)
        suppressEdgeUntil = Date().addingTimeInterval(0.8); edgeHandle?.setExpanded(false)
    }
    @objc private func checkEdge() {
        guard !NSScreen.screens.isEmpty else { return }
        edgeHandle?.checkPointer(delay: store.settings.edgeDelay, canOpen: !panel.isVisible && Date() > suppressEdgeUntil)
        checkPanelPointer()
        // Only the visible strip is a hover target. The remaining screen edge
        // stays available to scrollbars, neighbouring displays and other apps.
    }
    private func checkPanelPointer() {
        guard panel?.isVisible == true else { return }
        guard edgeHandle?.isInteracting != true else { return }
        if panelDragOffset != nil {
            if NSEvent.pressedMouseButtons & 1 == 0 { finishPanelDrag() }
            return
        }
        let point = NSEvent.mouseLocation
        if panelAutoCollapse.shouldCollapse(at: ProcessInfo.processInfo.systemUptime,
                                            pointerInside: PanelHitRegion.contains(point, in: panel.frame),
                                            pointerInOpeningBridge: openingStripFrame.map { PanelHitRegion.openingBridge(panel: panel.frame, strip: $0).contains(point) } ?? false,
                                            pressedMouseButtons: UInt(bitPattern: NSEvent.pressedMouseButtons)) { hidePanel() }
    }
    private func registerShortcut() {
        panelMenuItem?.keyEquivalent = store.settings.hotkeyChoice == "m" ? "m" : "g"
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        if hotkeyHandler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context -> OSStatus in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<ApplicationDelegate>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in delegate.togglePanel() }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &hotkeyHandler)
            if installed != noErr { store.statusMessage = "无法注册全局快捷键监听，可使用菜单栏或屏幕边缘打开面板。"; return }
        }
        let code: UInt32 = store.settings.hotkeyChoice == "m" ? 46 : 5
        let result = RegisterEventHotKey(code, UInt32(cmdKey | optionKey), EventHotKeyID(signature: 0x474A4C47, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        if result != noErr { store.statusMessage = "全局快捷键被其他应用占用，请在设置里切换另一个组合。" }
    }
}
