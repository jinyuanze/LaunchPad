import Foundation
import AppKit
import SwiftUI

/// Replicates `PreferencesWindowController` from LaunchOS binary (`PreferencesWindowController.swift`)
public final class PreferencesWindowController: NSWindowController {
    public static let shared = PreferencesWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LaunchPad 偏好设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: PreferencesRootView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showWindow() {
        if LaunchpadWindowController.shared.isVisible && AppState.shared.displayMode == .fullScreen {
            LaunchpadWindowController.shared.hide()
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

public enum PreferencesTab: String, CaseIterable, Identifiable {
    case general = "通用"
    case appearance = "外观"
    case layout = "布局"
    case sources = "应用来源与隐藏"
    case backup = "备份与恢复"
    case about = "关于"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintbrush.fill"
        case .layout: return "square.grid.3x3.fill"
        case .sources: return "folder.fill.badge.plus"
        case .backup: return "externaldrive.fill.badge.timemachine"
        case .about: return "sparkles"
        }
    }
}

public struct PreferencesRootView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var appManager = ApplicationManager.shared
    @LocalState private var selectedTab: PreferencesTab = .general
    @LocalState private var statusBanner: String? = nil

    public var body: some View {
        NavigationSplitView {
            List(PreferencesTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .font(.body.weight(.medium))
                    .padding(.vertical, 4)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 175, ideal: 185, max: 200)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let banner = statusBanner {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(banner)
                                .font(.subheadline)
                            Spacer()
                            Button("关闭") { statusBanner = nil }
                                .buttonStyle(.plain)
                                .font(.caption)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.14)))
                    }

                    switch selectedTab {
                    case .general:
                        generalSettingsSection
                    case .appearance:
                        appearanceSettingsSection
                    case .layout:
                        layoutSettingsSection
                    case .sources:
                        sourcesAndHiddenSection
                    case .backup:
                        backupAndRestoreSection
                    case .about:
                        aboutSection
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 680, minHeight: 500)
    }

    // MARK: - General Settings
    private var generalSettingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("通用设置")
                .font(.title2.bold())

            GroupBox("系统集成") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("开机时自动启动", isOn: $state.startAtLogin)
                    Toggle("在程序坞显示图标", isOn: $state.showDockIcon)
                    Toggle("在菜单栏显示图标", isOn: $state.showMenubarIcon)
                        .onChange(of: state.showMenubarIcon) { _, _ in
                            MenuBarManager.shared.updateStatusItemVisibility()
                        }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("快捷键与触发手势") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("启用全局快捷键 (⌥ + Space / F4)", isOn: $state.enableF4Shortcut)
                        .onChange(of: state.enableF4Shortcut) { _, _ in
                            InputEventMonitor.shared.reregisterHotKey()
                        }

                    Picker("触发角 (Hot Corners)", selection: $state.hotCorner) {
                        ForEach(HotCornerPosition.allCases) { pos in
                            Text(pos.title).tag(pos)
                        }
                    }

                    Picker("触控板捏合手势", selection: $state.trackpadGesture) {
                        ForEach(TrackpadGestureType.allCases) { g in
                            Text(g.title).tag(g)
                        }
                    }

                    Picker("显示在哪个屏幕", selection: $state.showOn) {
                        ForEach(ShowOnScreenMode.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }

                    Picker("自动返回主页延迟", selection: $state.returnToHome) {
                        ForEach(ReturnToHomeDelay.allCases) { d in
                            Text(d.title).tag(d)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("搜索与卸载") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("搜索结果中包含已隐藏的应用", isOn: $state.showHiddenAppsInSearch)
                    Toggle("按住 Option (⌥) 键进入抖动卸载模式", isOn: $state.enableOptionUninstallMode)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Appearance Settings
    private var appearanceSettingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("外观与视觉效果")
                .font(.title2.bold())

            GroupBox("窗口与浏览模式") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("浏览样式", selection: $state.browsingStyle) {
                        ForEach(BrowsingStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("显示模式", selection: $state.displayMode) {
                        ForEach(DisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: state.displayMode) { _, _ in
                        LaunchpadWindowController.shared.reconfigureWindowMode()
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("背景材质与模糊") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("背景风格", selection: $state.backgroundType) {
                        ForEach(BackgroundStyleType.allCases) { bg in
                            Text(bg.title).tag(bg)
                        }
                    }

                    Picker("液态毛玻璃材质", selection: $state.glassMaterial) {
                        ForEach(GlassMaterialLevel.allCases) { mat in
                            Text(mat.title).tag(mat)
                        }
                    }

                    HStack {
                        Text("壁纸模糊半径")
                        Slider(value: $state.wallpaperBlurRadius, in: 5...60)
                        Text("\(Int(state.wallpaperBlurRadius)) px")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }

                    Toggle("隐藏应用名称标签", isOn: $state.hideNames)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Layout Settings
    private var layoutSettingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("网格与布局整理")
                .font(.title2.bold())

            GroupBox("主页网格尺寸") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("预设网格", selection: $state.iconGrid) {
                        ForEach(IconGridPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    HStack {
                        Text("列数 (Columns): \(state.columnsPerPage)")
                            .frame(width: 150, alignment: .leading)
                        Stepper("", value: $state.columnsPerPage, in: 4...12)
                            .labelsHidden()
                    }

                    HStack {
                        Text("行数 (Rows): \(state.rowsPerPage)")
                            .frame(width: 150, alignment: .leading)
                        Stepper("", value: $state.rowsPerPage, in: 3...9)
                            .labelsHidden()
                    }

                    Picker("默认排序方式", selection: $state.sortBy) {
                        ForEach(SortByOption.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }

                    Picker("排序方向", selection: $state.sortOrder) {
                        ForEach(SortOrderOption.allCases) { o in
                            Text(o.title).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("智能整理与迁移") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Button("打开整理布局向导...") {
                            ReorganizeLayoutWindowController.shared.showWindow()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("从原版 LaunchOS 数据库导入") {
                            if appManager.importFromExistingLaunchOSDatabaseIfAvailable() {
                                statusBanner = "已成功从 ~/Library/Application Support/LaunchOS/LaunchOS.sqlite 导入布局！"
                            } else {
                                statusBanner = "未找到原版 LaunchOS.sqlite 数据库文件。"
                            }
                        }

                        Button("从系统启动台导入") {
                            switch appManager.importSystemLaunchpadData() {
                            case .success(let (apps, folders)):
                                statusBanner = "已导入 \(apps) 个应用与 \(folders) 个文件夹！"
                            case .failure(let err):
                                statusBanner = "导入失败：\(err.localizedDescription)"
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - App Sources & Hidden Apps
    private var sourcesAndHiddenSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("应用来源与隐藏列表")
                .font(.title2.bold())

            GroupBox("扫描目录来源 (App Sources)") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(appManager.sources) { source in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { source.enabled },
                                set: { appManager.toggleSource(source, enabled: $0) }
                            ))
                            .labelsHidden()

                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading) {
                                Text((source.path as NSString).lastPathComponent)
                                    .font(.body.weight(.medium))
                                Text(source.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if !source.isCustom {
                                Text(source.type.title)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                            } else {
                                Button(role: .destructive) {
                                    appManager.removeCustomSourceDirectory(source)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Divider()
                    }

                    HStack {
                        Button("添加应用目录...") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                appManager.addCustomSourceDirectory(url)
                            }
                        }
                        Button("立即重新扫描") {
                            appManager.scanApplications()
                            statusBanner = "已完成所有目录的应用重新扫描。"
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("已隐藏的应用 (\(appManager.hiddenApps.count))") {
                if appManager.hiddenApps.isEmpty {
                    Text("当前没有隐藏的应用程序。您可以在启动台右键点击任意图标选择「隐藏应用」。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appManager.hiddenApps) { app in
                            HStack {
                                Image(nsImage: AppIconRepository.shared.icon(for: app))
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                Text(app.displayName)
                                Text(app.url.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Button("恢复显示") {
                                    appManager.unhideApp(app)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Backup & Restore
    private var backupAndRestoreSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("备份与恢复 (.launchos)")
                .font(.title2.bold())

            GroupBox("导出或恢复布局备份") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("与原版 LaunchOS 备份格式 (.launchos) 兼容，支持完整保存应用顺序、文件夹分组、自定义目录与偏好设置。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 14) {
                        Button("导出备份 (.launchos)...") {
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = "LaunchOS-Backup.launchos"
                            if panel.runModal() == .OK, let url = panel.url {
                                do {
                                    try appManager.exportBackup(to: url)
                                    statusBanner = "已导出备份至 \(url.lastPathComponent)"
                                } catch {
                                    statusBanner = "导出失败：\(error.localizedDescription)"
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("从备份文件恢复...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url {
                                do {
                                    try appManager.importBackup(from: url)
                                    statusBanner = "已成功从 \(url.lastPathComponent) 恢复布局！"
                                } catch {
                                    statusBanner = "恢复失败：\(error.localizedDescription)"
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - About Section
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LaunchPad")
                        .font(.title.bold())
                    Text("版本 1.4.2 (Build 51) · Clean-Room Native Swift Replica")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill")
                            .foregroundColor(.yellow)
                        Text("Lifetime Pro 终身完整版 · 全功能原生解锁")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                    }
                    .padding(.top, 2)
                }
            }

            GroupBox("核心逆向还原特性") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("兼容 LaunchOS Core Data 数据模型 (AppEntity / GroupEntity / SourceEntity)", systemImage: "cylinder.split.1x2.fill")
                    Label("支持分页模式 (Paged) 与滚动模式 (Scroll) 自由切换", systemImage: "rectangle.grid.3x2.fill")
                    Label("支持全屏玻璃模式 (Full Screen) 与悬浮窗口模式 (Window)", systemImage: "macwindow.on.rectangle")
                    Label("支持中文拼音/首字母搜索、拖拽建夹、多选归组、Option 抖动深度卸载", systemImage: "sparkles")
                    Label("支持智能整理向导（应用名称、添加日期、使用频率、图标颜色、Apple 应用排布等）", systemImage: "wand.and.stars")
                }
                .font(.subheadline)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Replicates `ReorganizeLayoutWindowController` from LaunchOS binary (`ReorganizeLayoutWindowController.swift`)
public final class ReorganizeLayoutWindowController: NSWindowController {
    public static let shared = ReorganizeLayoutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 490),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "智能整理布局"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ReorganizeLayoutView(onClose: { [weak self] in
            self?.window?.close()
        }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showWindow() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

public struct ReorganizeLayoutView: View {
    @LocalState private var rules = ReorganizeRules()
    var onClose: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars.inverse")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("整理启动台布局")
                        .font(.title2.bold())
                    Text("选择排序与自动排列规则，一键重排所有应用与文件夹")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 8)

            GroupBox("排序规则") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("整理范围", selection: $rules.pageScope) {
                        ForEach(ReorganizePageScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("排序依据", selection: $rules.sortMethod) {
                        ForEach(ReorganizeSortMethod.allCases) { opt in
                            Text(opt.title).tag(opt)
                        }
                    }
                    Picker("排序方向", selection: $rules.sortDirection) {
                        ForEach(SortOrderOption.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(8)
            }

            GroupBox("分组与文件夹策略") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("文件夹位置", selection: $rules.folderPlacement) {
                        ForEach(ReorganizeFolderPlacement.allCases) { fp in
                            Text(fp.title).tag(fp)
                        }
                    }
                    Picker("Apple 系统应用位置", selection: $rules.appleAppPlacement) {
                        ForEach(ReorganizeApplePlacement.allCases) { ap in
                            Text(ap.title).tag(ap)
                        }
                    }
                    Toggle("同时对文件夹内部应用进行排序", isOn: $rules.sortsFolderContents)
                    Toggle("自动填满页面空位", isOn: $rules.fillsEmptySlots)
                    Toggle("解散所有文件夹并将全部应用平铺", isOn: $rules.removesAllFolders)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            HStack {
                Button("取消") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("立即应用整理") {
                    ApplicationManager.shared.reorganizeLayout(with: rules)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 490)
    }
}
