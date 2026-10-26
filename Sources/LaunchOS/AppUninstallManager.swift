import Foundation
import AppKit
import SwiftUI

public enum UninstallCategory: String, CaseIterable, Identifiable {
    case application = "Application"
    case support = "Application Support"
    case caches = "Caches"
    case preferences = "Preferences"
    case containers = "Containers & Sandbox"
    case logs = "Logs & Crash Reports"
    case savedState = "Saved Application State"
    case launchAgents = "Launch Agents & Daemons"
    case other = "Other Data"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .application: return "应用程序本体"
        case .support: return "应用支持文件 (Application Support)"
        case .caches: return "缓存文件 (Caches)"
        case .preferences: return "偏好设置 (Preferences)"
        case .containers: return "沙盒容器 (Containers)"
        case .logs: return "日志与崩溃报告 (Logs)"
        case .savedState: return "保存的窗口状态 (Saved State)"
        case .launchAgents: return "启动项与守护进程 (LaunchAgents)"
        case .other: return "其他关联数据 (WebKit / Scripts)"
        }
    }

    public var iconName: String {
        switch self {
        case .application: return "app.fill"
        case .support: return "folder.fill.badge.gearshape"
        case .caches: return "internaldrive.fill"
        case .preferences: return "slider.horizontal.3"
        case .containers: return "shippingbox.fill"
        case .logs: return "doc.text.fill"
        case .savedState: return "macwindow"
        case .launchAgents: return "bolt.horizontal.fill"
        case .other: return "doc.fill"
        }
    }
}

public struct UninstallItem: Identifiable, Hashable {
    public let id: UUID
    public let path: String
    public let category: UninstallCategory
    public let sizeBytes: Int64
    public var isSelected: Bool

    public init(path: String, category: UninstallCategory, sizeBytes: Int64, isSelected: Bool = true) {
        self.id = UUID()
        self.path = path
        self.category = category
        self.sizeBytes = sizeBytes
        self.isSelected = isSelected
    }

    public var displayName: String {
        (path as NSString).lastPathComponent
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Replicates `AppUninstallManager` from LaunchOS binary (`AppUninstallManager.swift`)
public final class AppUninstallManager: ObservableObject {
    public static let shared = AppUninstallManager()

    @Published public var targetApp: LaunchpadApp?
    @Published public var items: [UninstallItem] = []
    @Published public var isScanning: Bool = false
    @Published public var errorMessage: String?

    private let fm = FileManager.default

    private init() {}

    public var totalSelectedBytes: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
    }

    public var formattedTotalSelectedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSelectedBytes, countStyle: .file)
    }

    public func scanRelatedFiles(for app: LaunchpadApp) {
        targetApp = app
        isScanning = true
        errorMessage = nil
        items = []

        let appPath = app.url.path
        let bundleId = app.bundleId.lowercased()
        let appName = app.name.lowercased()
        let rawBundleName = app.bundleName.lowercased()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var found: [UninstallItem] = []
            var seenPaths = Set<String>()

            func addPath(_ path: String, category: UninstallCategory) {
                let standardized = (path as NSString).standardizingPath
                guard !seenPaths.contains(standardized), self.fm.fileExists(atPath: standardized) else { return }
                seenPaths.insert(standardized)
                let size = self.calculateDirectorySize(standardized)
                found.append(UninstallItem(path: standardized, category: category, sizeBytes: size, isSelected: true))
            }

            // 1. Main Application Bundle
            addPath(appPath, category: .application)

            // 2. Scan ~/Library and /Library directories discovered in binary __cstring
            let homeLib = (NSHomeDirectory() as NSString).appendingPathComponent("Library")
            let sysLib = "/Library"

            let searchSpec: [(String, UninstallCategory)] = [
                ("Application Support", .support),
                ("Caches", .caches),
                ("Preferences", .preferences),
                ("Preferences/ByHost", .preferences),
                ("Containers", .containers),
                ("Group Containers", .containers),
                ("HTTPStorages", .caches),
                ("Saved Application State", .savedState),
                ("Logs", .logs),
                ("Logs/DiagnosticReports", .logs),
                ("CrashReporter", .logs),
                ("WebKit", .other),
                ("Application Scripts", .other),
                ("LaunchAgents", .launchAgents),
                ("LaunchDaemons", .launchAgents)
            ]

            let tokens = [bundleId, appName, rawBundleName].filter { $0.count >= 3 }

            for root in [homeLib, sysLib] {
                for (subDir, category) in searchSpec {
                    let dirPath = (root as NSString).appendingPathComponent(subDir)
                    guard let entries = try? self.fm.contentsOfDirectory(atPath: dirPath) else { continue }
                    for entry in entries {
                        let lower = entry.lowercased()
                        let matched = tokens.contains { token in
                            guard !token.isEmpty else { return false }
                            return lower == token
                                || lower.hasPrefix(token + ".")
                                || lower.contains(bundleId)
                                || (!rawBundleName.isEmpty && lower == rawBundleName)
                        }
                        if matched {
                            let fullPath = (dirPath as NSString).appendingPathComponent(entry)
                            addPath(fullPath, category: category)
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                self.items = found.sorted {
                    if $0.category == $1.category {
                        return $0.sizeBytes > $1.sizeBytes
                    }
                    return $0.category.rawValue < $1.category.rawValue
                }
                self.isScanning = false
            }
        }
    }

    public func toggleSelection(for itemID: UUID) {
        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].isSelected.toggle()
        }
    }

    public func performUninstall(completion: @escaping (Bool) -> Void) {
        guard let app = targetApp else {
            completion(false)
            return
        }

        // Terminate running application first if running
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == app.bundleId || $0.bundleURL?.path == app.url.path
        }
        for running in runningApps {
            if !running.terminate() {
                running.forceTerminate()
            }
        }

        let selectedPaths = items.filter(\.isSelected).map(\.path)
        var failedPaths: [String] = []

        for path in selectedPaths {
            let url = URL(fileURLWithPath: path)
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failedPaths.append(path)
            }
        }

        // Fallback to privileged AppleScript deletion if moving to Trash failed due to permissions
        if !failedPaths.isEmpty {
            let escaped = failedPaths.map { path in
                "POSIX file \"\(path.replacingOccurrences(of: "\"", with: "\\\""))\""
            }.joined(separator: ", ")
            let scriptSource = "tell application \"Finder\" to delete {\(escaped)}"
            if let script = NSAppleScript(source: scriptSource) {
                var errorDict: NSDictionary?
                script.executeAndReturnError(&errorDict)
                if errorDict != nil {
                    errorMessage = "部分受保护文件需要管理员权限或无法移入废纸篓。"
                }
            }
        }

        ApplicationManager.shared.removeAppRecord(app)
        completion(true)
    }

    private func calculateDirectorySize(_ path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: path)
            return (attrs?[.size] as? Int64) ?? 0
        }

        let url = URL(fileURLWithPath: path)
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
               values.isDirectory != true,
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

/// Replicates `UninstallWindowController` & `UninstallContentView`
public final class UninstallWindowController: NSWindowController {
    public static let shared = UninstallWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "卸载应用程序"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: UninstallContentView(onClose: { [weak self] in
            self?.window?.close()
        }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func present(for app: LaunchpadApp) {
        AppUninstallManager.shared.scanRelatedFiles(for: app)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

public struct UninstallContentView: View {
    @ObservedObject var manager = AppUninstallManager.shared
    var onClose: () -> Void

    public var body: some View {
        VStack(spacing: 0) {
            if let app = manager.targetApp {
                HStack(spacing: 16) {
                    Image(nsImage: AppIconRepository.shared.icon(for: app))
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("彻底卸载 \(app.displayName)")
                            .font(.title2.bold())
                        Text(app.bundleId.isEmpty ? app.url.path : app.bundleId)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("已选中关联文件总大小：\(manager.formattedTotalSelectedSize)")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.accentColor)
                    }
                    Spacer()
                }
                .padding(20)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            }

            Divider()

            if manager.isScanning {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("正在深度扫描关联的缓存、偏好设置与沙盒容器文件...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(UninstallCategory.allCases) { category in
                        let catItems = manager.items.filter { $0.category == category }
                        if !catItems.isEmpty {
                            Section(header: Label(category.localizedTitle, systemImage: category.iconName).font(.subheadline.bold())) {
                                ForEach(catItems) { item in
                                    HStack(spacing: 10) {
                                        Toggle("", isOn: Binding(
                                            get: { item.isSelected },
                                            set: { _ in manager.toggleSelection(for: item.id) }
                                        ))
                                        .labelsHidden()

                                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                                            .resizable()
                                            .frame(width: 22, height: 22)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.displayName)
                                                .font(.body.weight(.medium))
                                                .lineLimit(1)
                                            Text(item.path)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }

                                        Spacer()

                                        Text(item.formattedSize)
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.secondary)

                                        Button {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                                        } label: {
                                            Image(systemName: "magnifyingglass.circle")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("在访达中显示")
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            if let errorMessage = manager.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }

            Divider()

            HStack {
                Button("全选") {
                    for idx in manager.items.indices {
                        manager.items[idx].isSelected = true
                    }
                }
                Button("仅选残留项") {
                    for idx in manager.items.indices {
                        manager.items[idx].isSelected = (manager.items[idx].category != .application)
                    }
                }
                Spacer()
                Button("取消") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button("移至废纸篓 (\(manager.formattedTotalSelectedSize))") {
                    manager.performUninstall { _ in
                        onClose()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(manager.items.filter(\.isSelected).isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 580, minHeight: 460)
    }
}
