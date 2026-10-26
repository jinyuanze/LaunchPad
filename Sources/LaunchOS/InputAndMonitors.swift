import Foundation
import AppKit
import SwiftUI
import Carbon

/// Replicates `HotCornersMonitor` from LaunchOS binary (`HotCornersMonitor.swift`)
public final class HotCornersMonitor {
    public static let shared = HotCornersMonitor()

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var lastTriggerTime: Date = .distantPast
    private let cornerThreshold: CGFloat = 6.0
    private let cooldownInterval: TimeInterval = 0.75

    private init() {}

    public func start() {
        stop()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.evaluateMouseLocation()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.evaluateMouseLocation()
            return event
        }
    }

    public func stop() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func evaluateMouseLocation() {
        let corner = AppState.shared.hotCorner
        guard corner != .off else { return }

        let mouseLoc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main else {
            return
        }

        let frame = screen.frame
        let inTop = mouseLoc.y >= frame.maxY - cornerThreshold
        let inBottom = mouseLoc.y <= frame.minY + cornerThreshold
        let inLeft = mouseLoc.x <= frame.minX + cornerThreshold
        let inRight = mouseLoc.x >= frame.maxX - cornerThreshold

        let matched: Bool
        switch corner {
        case .off:
            matched = false
        case .topLeft:
            matched = inTop && inLeft
        case .topRight:
            matched = inTop && inRight
        case .bottomLeft:
            matched = inBottom && inLeft
        case .bottomRight:
            matched = inBottom && inRight
        }

        if matched && Date().timeIntervalSince(lastTriggerTime) > cooldownInterval {
            lastTriggerTime = Date()
            DispatchQueue.main.async {
                LaunchpadWindowController.shared.toggle()
            }
        }
    }
}

/// Replicates `InputEventMonitor` from LaunchOS binary (`InputEventMonitor.swift`)
public final class InputEventMonitor {
    public static let shared = InputEventMonitor()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalGestureMonitor: Any?
    private var localKeyMonitor: Any?
    private var accumulatedMagnification: CGFloat = 0

    private init() {}

    public func start() {
        registerCarbonHotKey()
        registerGestureMonitors()
        TrackpadGestureMonitor.shared.start()
    }

    public func stop() {
        TrackpadGestureMonitor.shared.stop()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        if let globalGestureMonitor {
            NSEvent.removeMonitor(globalGestureMonitor)
            self.globalGestureMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    public func reregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registerCarbonHotKey()
    }

    private func registerCarbonHotKey() {
        guard AppState.shared.enableF4Shortcut else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        if eventHandlerRef == nil {
            let callback: EventHandlerUPP = { _, _, _ -> OSStatus in
                DispatchQueue.main.async {
                    LaunchpadWindowController.shared.toggle()
                }
                return noErr
            }
            InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                1,
                &eventType,
                nil,
                &eventHandlerRef
            )
        }

        // Default shortcut: Option + Space (keyCode 49, optionKey)
        let keyCode = UInt32(kVK_Space)
        let modifiers = UInt32(optionKey)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4F5331), id: 1) // 'LOS1'
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func registerGestureMonitors() {
        globalGestureMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.magnify, .keyDown]) { [weak self] event in
            self?.handleGlobalEvent(event)
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .magnify]) { [weak self] event in
            if let self = self, self.handleLocalEvent(event) {
                return nil
            }
            return event
        }
    }

    private func handleGlobalEvent(_ event: NSEvent) {
        if event.type == .magnify {
            let gesturePref = AppState.shared.trackpadGesture
            guard gesturePref != .off else { return }
            if event.phase == .began {
                accumulatedMagnification = 0
            }
            accumulatedMagnification += event.magnification
            if accumulatedMagnification < -0.35 {
                accumulatedMagnification = 0
                DispatchQueue.main.async {
                    LaunchpadWindowController.shared.show()
                }
            }
        } else if event.type == .keyDown {
            // F4 Launchpad hardware key (keyCode 131 or 118)
            if AppState.shared.enableF4Shortcut && (event.keyCode == 131 || event.keyCode == 118) {
                DispatchQueue.main.async {
                    LaunchpadWindowController.shared.toggle()
                }
            }
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            let optionHeld = event.modifierFlags.contains(.option)
            if AppState.shared.enableOptionUninstallMode && LaunchpadWindowController.shared.isVisible {
                DispatchQueue.main.async {
                    ApplicationManager.shared.isUninstallJiggleMode = optionHeld
                }
            }
            return false
        }

        if event.type == .keyDown && LaunchpadWindowController.shared.isVisible {
            let appMgr = ApplicationManager.shared
            let cols = max(4, AppState.shared.columnsPerPage)

            switch event.keyCode {
            case 53: // Escape
                DispatchQueue.main.async {
                    if appMgr.openedFolderID != nil {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            appMgr.openedFolderID = nil
                        }
                    } else if appMgr.isUninstallJiggleMode {
                        appMgr.isUninstallJiggleMode = false
                    } else if !appMgr.currentSearchQuery.isEmpty {
                        appMgr.currentSearchQuery = ""
                    } else {
                        LaunchpadWindowController.shared.hide()
                    }
                }
                return true
            case 36, 76: // Enter / Return
                if !appMgr.currentSearchQuery.isEmpty {
                    DispatchQueue.main.async {
                        appMgr.launchSelectedSearchApp()
                    }
                    return true
                }
            case 125: // Down Arrow
                if !appMgr.currentSearchQuery.isEmpty {
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.12)) {
                            appMgr.moveSearchSelection(deltaRow: 1, deltaCol: 0, cols: cols)
                        }
                    }
                    return true
                }
            case 126: // Up Arrow
                if !appMgr.currentSearchQuery.isEmpty {
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.12)) {
                            appMgr.moveSearchSelection(deltaRow: -1, deltaCol: 0, cols: cols)
                        }
                    }
                    return true
                }
            case 124: // Right Arrow
                if !appMgr.currentSearchQuery.isEmpty {
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.12)) {
                            appMgr.moveSearchSelection(deltaRow: 0, deltaCol: 1, cols: cols)
                        }
                    }
                    return true
                } else if appMgr.openedFolderID == nil {
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            AppState.shared.currentPage = min(appMgr.totalPages - 1, AppState.shared.currentPage + 1)
                        }
                    }
                    return true
                }
            case 123: // Left Arrow
                if !appMgr.currentSearchQuery.isEmpty {
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.12)) {
                            appMgr.moveSearchSelection(deltaRow: 0, deltaCol: -1, cols: cols)
                        }
                    }
                    return true
                } else if appMgr.openedFolderID == nil {
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            AppState.shared.currentPage = max(0, AppState.shared.currentPage - 1)
                        }
                    }
                    return true
                }
            case 48: // Tab
                if !appMgr.currentSearchQuery.isEmpty {
                    let isShift = event.modifierFlags.contains(.shift)
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.12)) {
                            appMgr.cycleSearchSelection(forward: !isShift)
                        }
                    }
                    return true
                }
            default:
                break
            }
        }
        return false
    }
}

/// Replicates `FinderMonitor` to watch `/Applications` directory changes automatically
public final class FinderMonitor {
    public static let shared = FinderMonitor()

    private var fileDescriptors: [CInt] = []
    private var dispatchSources: [DispatchSourceFileSystemObject] = []

    private init() {}

    public func startWatching(paths: [String]) {
        stopWatching()
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            fileDescriptors.append(fd)

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    ApplicationManager.shared.scanApplications()
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            dispatchSources.append(source)
        }
    }

    public func stopWatching() {
        for source in dispatchSources {
            source.cancel()
        }
        dispatchSources.removeAll()
        fileDescriptors.removeAll()
    }
}

/// Replicates `MenuBarManager` from LaunchOS binary (`MenuBarManager.swift`)
public final class MenuBarManager: NSObject {
    public static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: .preferencesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatusItemVisibility()
        }
    }

    public func updateStatusItemVisibility() {
        if AppState.shared.showMenubarIcon {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = item.button {
                    let img = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "LaunchPad")
                    img?.isTemplate = true
                    button.image = img
                    button.toolTip = "LaunchPad"
                }
                item.menu = buildMenu()
                statusItem = item
            } else {
                statusItem?.menu = buildMenu()
            }
        } else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
        }
    }

    public func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "LaunchPad")

        let openItem = NSMenuItem(title: "打开 LaunchPad (⌥Space)", action: #selector(openLaunchpad), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        // Display mode submenu
        let modeMenu = NSMenu(title: "显示模式")
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (AppState.shared.displayMode == mode) ? .on : .off
            modeMenu.addItem(item)
        }
        let modeRoot = NSMenuItem(title: "显示模式", action: nil, keyEquivalent: "")
        modeRoot.submenu = modeMenu
        menu.addItem(modeRoot)

        // Browsing style submenu
        let styleMenu = NSMenu(title: "浏览样式")
        for style in BrowsingStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(selectBrowsingStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = (AppState.shared.browsingStyle == style) ? .on : .off
            styleMenu.addItem(item)
        }
        let styleRoot = NSMenuItem(title: "浏览样式", action: nil, keyEquivalent: "")
        styleRoot.submenu = styleMenu
        menu.addItem(styleRoot)

        menu.addItem(.separator())

        let reorgItem = NSMenuItem(title: "整理布局...", action: #selector(openReorganizeLayout), keyEquivalent: "")
        reorgItem.target = self
        menu.addItem(reorgItem)

        let rescanItem = NSMenuItem(title: "重新扫描应用程序", action: #selector(rescanApplications), keyEquivalent: "r")
        rescanItem.target = self
        menu.addItem(rescanItem)

        let prefsItem = NSMenuItem(title: "偏好设置...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 LaunchPad", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openLaunchpad() {
        LaunchpadWindowController.shared.toggle()
    }

    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = DisplayMode(rawValue: raw) {
            AppState.shared.displayMode = mode
            updateStatusItemVisibility()
            if LaunchpadWindowController.shared.isVisible {
                LaunchpadWindowController.shared.reconfigureWindowMode()
            }
        }
    }

    @objc private func selectBrowsingStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = BrowsingStyle(rawValue: raw) {
            AppState.shared.browsingStyle = style
            updateStatusItemVisibility()
        }
    }

    @objc private func openReorganizeLayout() {
        ReorganizeLayoutWindowController.shared.showWindow()
    }

    @objc private func rescanApplications() {
        ApplicationManager.shared.scanApplications()
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.showWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
