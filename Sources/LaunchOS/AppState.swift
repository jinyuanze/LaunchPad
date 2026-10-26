import Foundation
import AppKit
import SwiftUI
import Combine
import ServiceManagement

// MARK: - Observed Enums from LaunchOS Binary (__swift5_reflstr)

public enum IconGridPreset: String, CaseIterable, Identifiable, Codable {
    case grid7x5 = "grid7x5"
    case grid8x5 = "grid8x5"
    case grid9x5 = "grid9x5"
    case grid10x5 = "grid10x5"
    case grid7x6 = "grid7x6"
    case grid8x6 = "grid8x6"
    case grid9x6 = "grid9x6"
    case grid10x6 = "grid10x6"

    public var id: String { rawValue }

    public var columns: Int {
        switch self {
        case .grid7x5, .grid7x6: return 7
        case .grid8x5, .grid8x6: return 8
        case .grid9x5, .grid9x6: return 9
        case .grid10x5, .grid10x6: return 10
        }
    }

    public var rows: Int {
        switch self {
        case .grid7x5, .grid8x5, .grid9x5, .grid10x5: return 5
        case .grid7x6, .grid8x6, .grid9x6, .grid10x6: return 6
        }
    }

    public var title: String {
        "\(columns) × \(rows)"
    }
}

public enum BrowsingStyle: String, CaseIterable, Identifiable, Codable {
    case paged = "paged"
    case scroll = "scroll"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .paged: return "分页 (Paged)"
        case .scroll: return "滚动 (Scroll)"
        }
    }
}

public enum DisplayMode: String, CaseIterable, Identifiable, Codable {
    case fullScreen = "fullScreen"
    case window = "window"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .fullScreen: return "全屏模式 (经典 Launchpad)"
        case .window: return "窗口模式 (现代化悬浮窗)"
        }
    }
}

public enum HotCornerPosition: String, CaseIterable, Identifiable, Codable {
    case off = "off"
    case topLeft = "topLeft"
    case topRight = "topRight"
    case bottomLeft = "bottomLeft"
    case bottomRight = "bottomRight"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "关闭"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }
}

public enum TrackpadGestureType: String, CaseIterable, Identifiable, Codable {
    case off = "off"
    case three = "three"
    case four = "four"
    case five = "five"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "关闭"
        case .three: return "三指捏合"
        case .four: return "四指或五指捏合"
        case .five: return "五指捏合"
        }
    }
}

public enum ShowOnScreenMode: String, CaseIterable, Identifiable, Codable {
    case primary = "primary"
    case active = "active"
    case cursor = "cursor"
    case dock = "dock"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .primary: return "主屏幕"
        case .active: return "当前激活屏幕"
        case .cursor: return "鼠标所在屏幕"
        case .dock: return "Dock 所在屏幕"
        }
    }
}

public enum ReturnToHomeDelay: String, CaseIterable, Identifiable, Codable {
    case never = "never"
    case always = "always"
    case after5Sec = "after5Sec"
    case after15Sec = "after15Sec"
    case after30Sec = "after30Sec"
    case after1Min = "after1Min"
    case after5Min = "after5Min"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .never: return "从不 (延续上次位置)"
        case .always: return "始终返回首页"
        case .after5Sec: return "5 秒后"
        case .after15Sec: return "15 秒后"
        case .after30Sec: return "30 秒后"
        case .after1Min: return "1 分钟后"
        case .after5Min: return "5 分钟后"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .always: return 0
        case .after5Sec: return 5
        case .after15Sec: return 15
        case .after30Sec: return 30
        case .after1Min: return 60
        case .after5Min: return 300
        }
    }
}

public enum SortByOption: String, CaseIterable, Identifiable, Codable {
    case custom = "custom"
    case name = "name"
    case added = "added"
    case opened = "opened"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .custom: return "自定义 (支持拖拽排序)"
        case .name: return "名称"
        case .added: return "添加日期"
        case .opened: return "上次使用"
        }
    }
}

public enum SortOrderOption: String, CaseIterable, Identifiable, Codable {
    case ascending = "ascending"
    case descending = "descending"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ascending: return "升序"
        case .descending: return "降序"
        }
    }
}

public enum BackgroundStyleType: String, CaseIterable, Identifiable, Codable {
    case wallpaper = "wallpaper"
    case glassEffect = "glassEffect"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .wallpaper: return "系统壁纸模糊"
        case .glassEffect: return "毛玻璃材质 (Glass Effect)"
        }
    }
}

public enum GlassMaterialLevel: String, CaseIterable, Identifiable, Codable {
    case ultraThin = "ultraThin"
    case thin = "thin"
    case regular = "regular"
    case thick = "thick"
    case ultraThick = "ultraThick"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ultraThin: return "极薄 (Ultra Thin)"
        case .thin: return "薄 (Thin)"
        case .regular: return "标准 (Regular)"
        case .thick: return "厚 (Thick)"
        case .ultraThick: return "极厚 (Ultra Thick)"
        }
    }

    public var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .ultraThin: return .hudWindow
        case .thin: return .menu
        case .regular: return .popover
        case .thick: return .sidebar
        case .ultraThick: return .headerView
        }
    }
}

public enum MembershipTier: String, Codable {
    case free = "free"
    case pro = "pro"
}

// MARK: - AppState (Reconstructed from LaunchOS/AppState.swift fields)

public final class AppState: ObservableObject {
    public static let shared = AppState()

    private let defaults = UserDefaults.standard

    @Published public var hiddenAppCount: Int = 0
    @Published public var customAppDirectoryCount: Int = 0
    @Published public var currentPage: Int = 0
    @Published public var membership: MembershipTier = .pro
    @Published public var lastHiddenTime: Date? = nil

    @Published public var isFirstLaunch: Bool {
        didSet { defaults.set(isFirstLaunch, forKey: "isFirstLaunch") }
    }

    @Published public var iconGrid: IconGridPreset {
        didSet {
            defaults.set(iconGrid.rawValue, forKey: "iconGrid")
            columnsPerPage = iconGrid.columns
            rowsPerPage = iconGrid.rows
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var columnsPerPage: Int {
        didSet {
            defaults.set(columnsPerPage, forKey: "columnsPerPage")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var rowsPerPage: Int {
        didSet {
            defaults.set(rowsPerPage, forKey: "rowsPerPage")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var browsingStyle: BrowsingStyle {
        didSet {
            defaults.set(browsingStyle.rawValue, forKey: "browsingStyle")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var showMenubarIcon: Bool {
        didSet {
            defaults.set(showMenubarIcon, forKey: "showMenubarIcon")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var showDockIcon: Bool {
        didSet {
            defaults.set(showDockIcon, forKey: "showDockIcon")
            applyActivationPolicy()
        }
    }

    @Published public var displayMode: DisplayMode {
        didSet {
            defaults.set(displayMode.rawValue, forKey: "displayMode")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var hideDock: Bool {
        didSet {
            defaults.set(hideDock, forKey: "hideDock")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var hotCorner: HotCornerPosition {
        didSet {
            defaults.set(hotCorner.rawValue, forKey: "hotCorner")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var trackpadGesture: TrackpadGestureType {
        didSet {
            defaults.set(trackpadGesture.rawValue, forKey: "trackpadGesture")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var enableF4Shortcut: Bool {
        didSet {
            defaults.set(enableF4Shortcut, forKey: "EnableF4Shortcut")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var showOn: ShowOnScreenMode {
        didSet {
            defaults.set(showOn.rawValue, forKey: "showOn")
        }
    }

    @Published public var returnToHome: ReturnToHomeDelay {
        didSet {
            defaults.set(returnToHome.rawValue, forKey: "returnToHome")
        }
    }

    @Published public var sortBy: SortByOption {
        didSet {
            defaults.set(sortBy.rawValue, forKey: "sortBy")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var sortOrder: SortOrderOption {
        didSet {
            defaults.set(sortOrder.rawValue, forKey: "sortOrder")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var hideNames: Bool {
        didSet {
            defaults.set(hideNames, forKey: "hideNames")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var showHiddenAppsInSearch: Bool {
        didSet {
            defaults.set(showHiddenAppsInSearch, forKey: "ShowHiddenAppsInSearch")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var enableOptionUninstallMode: Bool {
        didSet {
            defaults.set(enableOptionUninstallMode, forKey: "EnableOptionUninstallMode")
        }
    }

    @Published public var backgroundType: BackgroundStyleType {
        didSet {
            defaults.set(backgroundType.rawValue, forKey: "backgroundType")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var isBlurWallpaper: Bool {
        didSet {
            defaults.set(isBlurWallpaper, forKey: "isBlurWallpaper")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var wallpaperBlurRadius: Double {
        didSet {
            defaults.set(wallpaperBlurRadius, forKey: "WallpaperBlurRadius")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var glassMaterial: GlassMaterialLevel {
        didSet {
            defaults.set(glassMaterial.rawValue, forKey: "glassMaterial")
            NotificationCenter.default.post(name: .preferencesChanged, object: nil)
        }
    }

    @Published public var startAtLogin: Bool {
        didSet {
            defaults.set(startAtLogin, forKey: "startAtLogin")
            updateLaunchAtLogin(startAtLogin)
        }
    }

    public var pageCapacity: Int {
        max(1, columnsPerPage * rowsPerPage)
    }

    private init() {
        let gridRaw = defaults.string(forKey: "iconGrid") ?? IconGridPreset.grid7x5.rawValue
        let preset = IconGridPreset(rawValue: gridRaw) ?? .grid7x5
        self.iconGrid = preset
        let savedCols = defaults.integer(forKey: "columnsPerPage")
        let savedRows = defaults.integer(forKey: "rowsPerPage")
        self.columnsPerPage = savedCols > 0 ? savedCols : preset.columns
        self.rowsPerPage = savedRows > 0 ? savedRows : preset.rows

        self.isFirstLaunch = defaults.object(forKey: "isFirstLaunch") as? Bool ?? true
        self.browsingStyle = BrowsingStyle(rawValue: defaults.string(forKey: "browsingStyle") ?? "") ?? .paged
        self.showMenubarIcon = defaults.object(forKey: "showMenubarIcon") as? Bool ?? false
        self.showDockIcon = defaults.object(forKey: "showDockIcon") as? Bool ?? true
        self.displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .fullScreen
        self.hideDock = defaults.object(forKey: "hideDock") as? Bool ?? true
        self.hotCorner = HotCornerPosition(rawValue: defaults.string(forKey: "hotCorner") ?? "") ?? .bottomLeft
        self.trackpadGesture = TrackpadGestureType(rawValue: defaults.string(forKey: "trackpadGesture") ?? "") ?? .four
        self.enableF4Shortcut = defaults.object(forKey: "EnableF4Shortcut") as? Bool ?? true
        self.showOn = ShowOnScreenMode(rawValue: defaults.string(forKey: "showOn") ?? "") ?? .active
        self.returnToHome = ReturnToHomeDelay(rawValue: defaults.string(forKey: "returnToHome") ?? "") ?? .after30Sec
        self.sortBy = SortByOption(rawValue: defaults.string(forKey: "sortBy") ?? "") ?? .custom
        self.sortOrder = SortOrderOption(rawValue: defaults.string(forKey: "sortOrder") ?? "") ?? .ascending
        self.hideNames = defaults.object(forKey: "hideNames") as? Bool ?? false
        self.showHiddenAppsInSearch = defaults.object(forKey: "ShowHiddenAppsInSearch") as? Bool ?? true
        self.enableOptionUninstallMode = defaults.object(forKey: "EnableOptionUninstallMode") as? Bool ?? true
        self.backgroundType = BackgroundStyleType(rawValue: defaults.string(forKey: "backgroundType") ?? "") ?? .wallpaper
        self.isBlurWallpaper = defaults.object(forKey: "isBlurWallpaper") as? Bool ?? true
        let blur = defaults.double(forKey: "WallpaperBlurRadius")
        self.wallpaperBlurRadius = blur > 0 ? blur : 28.0
        self.glassMaterial = GlassMaterialLevel(rawValue: defaults.string(forKey: "glassMaterial") ?? "") ?? .regular
        self.startAtLogin = defaults.object(forKey: "startAtLogin") as? Bool ?? false
    }

    public func applyActivationPolicy() {
        DispatchQueue.main.async {
            NSApp?.setActivationPolicy(self.showDockIcon ? .regular : .accessory)
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Ignore registration failure for unsigned/local build
            }
        }
    }
}

public extension Notification.Name {
    static let preferencesChanged = Notification.Name("PreferencesChanged")
    static let refreshPendingIcon = Notification.Name("RefreshPendingIcon")
    static let refreshPreferencesData = Notification.Name("RefreshPreferencesData")
    static let appIconChanged = Notification.Name("LaunchOS.AppIconChanged")
}

/// Property wrapper replacing `@State` when compiling with CommandLineTools SDK without `SwiftUIMacros` plugin
@propertyWrapper
public struct LocalState<Value>: DynamicProperty {
    public final class Storage: ObservableObject {
        @Published public var value: Value
        public init(_ value: Value) { self.value = value }
    }

    @ObservedObject private var storage: Storage

    public init(wrappedValue: Value) {
        self._storage = ObservedObject(wrappedValue: Storage(wrappedValue))
    }

    public var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }

    public var projectedValue: Binding<Value> {
        Binding(
            get: { storage.value },
            set: { storage.value = $0 }
        )
    }
}
