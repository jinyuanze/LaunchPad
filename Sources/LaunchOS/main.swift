import Foundation
import AppKit
import SwiftUI

/// Replicates `LaunchOSApplication` from LaunchOS binary (`LaunchOSApplication.swift`)
public final class LaunchOSApplication: NSApplication {
    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // Standard Cmd+Q / Cmd+W / Cmd+, / Cmd+R shortcuts inside borderless NSPanel
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case ",":
                    PreferencesWindowController.shared.showWindow()
                    return
                case "w":
                    if LaunchpadWindowController.shared.isVisible {
                        LaunchpadWindowController.shared.hide()
                        return
                    }
                case "r":
                    ApplicationManager.shared.scanApplications()
                    return
                default:
                    break
                }
            }
        }
        super.sendEvent(event)
    }
}

/// Replicates `AppDelegate` from LaunchOS binary (`AppDelegate.swift`)
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchDate = Date()

    private var isLaunchedAtLogin: Bool {
        // 1. Check command line arguments passed by system or launch agents
        let args = CommandLine.arguments
        if args.contains("--login") || args.contains("--login-item") || args.contains("--background") || args.contains("-background") || args.contains("--hidden") || args.contains("-hidden") {
            return true
        }

        // 2. Check AppleEvent attribute keyAELaunchedAsLogInItem ('lgit' = 0x6c676974)
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            let lgit = AEKeyword(0x6c676974)
            if event.attributeDescriptor(forKeyword: lgit) != nil {
                return true
            }
        }

        // 3. System boot check: if startAtLogin is enabled and system uptime is within 180s, it was auto-launched on boot
        if AppState.shared.startAtLogin && ProcessInfo.processInfo.systemUptime < 180 {
            return true
        }

        return false
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? Bundle.main.url(forResource: "Launchpad-Light", withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = image
        }

        AppState.shared.applyActivationPolicy()
        MenuBarManager.shared.updateStatusItemVisibility()

        // Initialize application list & import existing LaunchOS database on first launch
        _ = ApplicationManager.shared

        // Start global monitors (Hot Corners, Carbon Shortcut, F4, Trackpad Pinch, Finder Watcher)
        HotCornersMonitor.shared.start()
        InputEventMonitor.shared.start()
        FinderMonitor.shared.startWatching(paths: ApplicationManager.shared.sources.map(\.path))

        // Only show Launchpad if manually opened by user; remain silent in background on login auto-start
        if !isLaunchedAtLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                LaunchpadWindowController.shared.show()
            }
        } else {
            NSLog("[LaunchPad] Auto-started at login/system boot; remaining quietly in background.")
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard Date().timeIntervalSince(launchDate) > 0.8 else {
            return true
        }
        LaunchpadWindowController.shared.toggle()
        return true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "launchos" {
                handleCustomURLScheme(url)
            } else if url.pathExtension.lowercased() == "launchos" {
                try? ApplicationManager.shared.importBackup(from: url)
                LaunchpadWindowController.shared.show()
            }
        }
    }

    private func handleCustomURLScheme(_ url: URL) {
        switch url.host?.lowercased() {
        case "export-backup":
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "LaunchOS-Backup.launchos"
            if panel.runModal() == .OK, let targetURL = panel.url {
                try? ApplicationManager.shared.exportBackup(to: targetURL)
            }
        case "preferences":
            PreferencesWindowController.shared.showWindow()
        case "reorganize":
            ReorganizeLayoutWindowController.shared.showWindow()
        case "page":
            if let pageStr = url.pathComponents.last, let p = Int(pageStr) {
                LaunchpadWindowController.shared.show()
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    AppState.shared.currentPage = max(0, min(ApplicationManager.shared.totalPages - 1, p))
                }
            }
        default:
            LaunchpadWindowController.shared.show()
        }
    }
}

// Entry point
let app = LaunchOSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
