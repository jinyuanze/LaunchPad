import Foundation
import AppKit
import CoreData
import Combine
import SQLite3

// MARK: - AppIconRepository (Reconstructed from LaunchOS/AppIconRepository.swift)

public final class AppIconRepository {
    public static let shared = AppIconRepository()

    private let cache = NSCache<NSString, NSImage>()
    private let colorCache = NSCache<NSString, NSNumber>()
    private let lock = NSLock()
    private let persistentCacheDirectoryURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        persistentCacheDirectoryURL = appSupport
            .appendingPathComponent("LaunchOSReplica", isDirectory: true)
            .appendingPathComponent("AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: persistentCacheDirectoryURL, withIntermediateDirectories: true)
        cache.countLimit = 400
    }

    public func icon(for app: LaunchpadApp, pointSize: CGFloat = 128) -> NSImage {
        let key = "\(app.bundleId)|\(app.url.path)|\(Int(pointSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let img = NSWorkspace.shared.icon(forFile: app.url.path)
        img.size = NSSize(width: pointSize, height: pointSize)
        cache.setObject(img, forKey: key)
        return img
    }

    public func icon(for path: String, pointSize: CGFloat = 128) -> NSImage {
        let key = "path|\(path)|\(Int(pointSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: pointSize, height: pointSize)
        cache.setObject(img, forKey: key)
        return img
    }

    public func dominantHue(for app: LaunchpadApp) -> Double {
        let key = app.bundleId as NSString
        if let cached = colorCache.object(forKey: key) {
            return cached.doubleValue
        }
        let img = icon(for: app, pointSize: 32)
        guard let tiff = img.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return 0
        }
        var rTotal: Double = 0
        var gTotal: Double = 0
        var bTotal: Double = 0
        var count: Double = 0
        let w = bitmap.pixelsWide
        let h = bitmap.pixelsHigh
        for x in stride(from: 0, to: w, by: 2) {
            for y in stride(from: 0, to: h, by: 2) {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.25 {
                    rTotal += Double(c.redComponent)
                    gTotal += Double(c.greenComponent)
                    bTotal += Double(c.blueComponent)
                    count += 1
                }
            }
        }
        guard count > 0 else { return 0 }
        let avg = NSColor(srgbRed: rTotal / count, green: gTotal / count, blue: bTotal / count, alpha: 1.0)
        let hue = Double(avg.hueComponent)
        colorCache.setObject(NSNumber(value: hue), forKey: key)
        return hue
    }
}

// MARK: - Reorganize Layout Rules (Reconstructed from ReorganizeLayoutWindowController.swift)

public enum ReorganizeSortMethod: String, CaseIterable, Identifiable {
    case currentOrder = "currentOrder"
    case name = "name"
    case dateAdded = "dateAdded"
    case lastUsed = "lastUsed"
    case iconColor = "iconColor"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .currentOrder: return "当前顺序"
        case .name: return "应用名称"
        case .dateAdded: return "添加日期"
        case .lastUsed: return "上次使用"
        case .iconColor: return "图标颜色"
        }
    }
}

public enum ReorganizeFolderPlacement: String, CaseIterable, Identifiable {
    case keep = "keep"
    case front = "front"
    case back = "back"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .keep: return "与应用混排"
        case .front: return "应用之前"
        case .back: return "应用之后"
        }
    }
}

public enum ReorganizeApplePlacement: String, CaseIterable, Identifiable {
    case keep = "keep"
    case front = "front"
    case back = "back"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .keep: return "与其他应用混排"
        case .front: return "其他应用前"
        case .back: return "其他应用后"
        }
    }
}

public enum ReorganizePageScope: String, CaseIterable, Identifiable {
    case allPages = "allPages"
    case currentPage = "currentPage"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .allPages: return "全部页面"
        case .currentPage: return "当前页面"
        }
    }
}

public struct ReorganizeRules {
    public var sortMethod: ReorganizeSortMethod = .name
    public var sortDirection: SortOrderOption = .ascending
    public var folderPlacement: ReorganizeFolderPlacement = .front
    public var removesAllFolders: Bool = false
    public var sortsFolderContents: Bool = true
    public var fillsEmptySlots: Bool = true
    public var appleAppPlacement: ReorganizeApplePlacement = .keep
    public var pageScope: ReorganizePageScope = .allPages
    public init() {}
}

// MARK: - ApplicationManager & LaunchpadDataManager

public final class ApplicationManager: ObservableObject {
    public static let shared = ApplicationManager()

    @Published public private(set) var allGroups: [LaunchpadGroup] = []
    @Published public private(set) var filteredGroups: [LaunchpadGroup] = []
    @Published public private(set) var hiddenApps: [LaunchpadApp] = []
    @Published public private(set) var sources: [AppSourceItem] = []
    @Published public var currentSearchQuery: String = "" {
        didSet {
            if oldValue.isEmpty && !currentSearchQuery.isEmpty {
                searchReturnPosition = AppState.shared.currentPage
            } else if !oldValue.isEmpty && currentSearchQuery.isEmpty {
                if let pos = searchReturnPosition {
                    AppState.shared.currentPage = pos
                }
            }
            applyFilterAndSort()
        }
    }
    public var searchReturnPosition: Int? = nil
    @Published public var selectedSearchAppID: String? = nil
    @Published public var openedFolderID: String? = nil
    @Published public var selectedGroupIDs: Set<String> = []
    @Published public var isUninstallJiggleMode: Bool = false

    public let defaultSystemDirectories: [(String, AppSourceType)] = [
        ("/Applications", .system),
        ("/System/Applications", .system),
        ("/System/Applications/Utilities", .system),
        ("/System/Cryptexes/App/System/Applications", .system),
        ((NSHomeDirectory() as NSString).appendingPathComponent("Applications"), .userHome)
    ]

    public let coreServicesAllowlist: Set<String> = [
        "/System/Library/CoreServices/Finder.app",
        "/System/Library/CoreServices/Applications/Directory Utility.app",
        "/System/Library/CoreServices/Applications/Screen Sharing.app",
        "/System/Library/CoreServices/Applications/Storage Management.app",
        "/System/Library/CoreServices/Applications/Wireless Diagnostics.app",
        "/System/Library/CoreServices/Applications/Archive Utility.app"
    ]

    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadSourcesFromCoreData()
        loadLayoutFromCoreData()
        if allGroups.isEmpty {
            // Try importing existing LaunchOS database if present on this machine, then scan apps
            _ = importFromExistingLaunchOSDatabaseIfAvailable()
        }
        scanApplications()

        NotificationCenter.default.publisher(for: .preferencesChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyFilterAndSort()
            }
            .store(in: &cancellables)
    }

    // MARK: - App Source Management

    public func loadSourcesFromCoreData() {
        let ctx = PersistenceController.shared.viewContext
        let req = NSFetchRequest<SourceEntity>(entityName: "SourceEntity")
        let entities = (try? ctx.fetch(req)) ?? []

        if entities.isEmpty {
            for (path, sType) in defaultSystemDirectories {
                let entity = SourceEntity(context: ctx)
                entity.id = UUID()
                entity.path = path
                entity.enabled = true
                entity.type = Int64(sType.rawValue)
            }
            PersistenceController.shared.save()
        }

        let refreshed = (try? ctx.fetch(req)) ?? []
        self.sources = refreshed.compactMap { ent in
            guard let path = ent.path else { return nil }
            let id = ent.id ?? UUID()
            let t = AppSourceType(rawValue: Int(ent.type)) ?? .external
            return AppSourceItem(id: id, path: path, enabled: ent.enabled, type: t)
        }.sorted { $0.type.rawValue < $1.type.rawValue || ($0.type == $1.type && $0.path < $1.path) }

        AppState.shared.customAppDirectoryCount = sources.filter { $0.isCustom && $0.enabled }.count
    }

    public func toggleSource(_ source: AppSourceItem, enabled: Bool) {
        let ctx = PersistenceController.shared.viewContext
        let req = NSFetchRequest<SourceEntity>(entityName: "SourceEntity")
        req.predicate = NSPredicate(format: "path == %@", source.path)
        if let entity = try? ctx.fetch(req).first {
            entity.enabled = enabled
            PersistenceController.shared.save()
            loadSourcesFromCoreData()
            scanApplications()
        }
    }

    public func addCustomSourceDirectory(_ url: URL) {
        let path = url.path
        guard !sources.contains(where: { $0.path == path }) else { return }
        let ctx = PersistenceController.shared.viewContext
        let entity = SourceEntity(context: ctx)
        entity.id = UUID()
        entity.path = path
        entity.enabled = true
        entity.type = Int64(AppSourceType.external.rawValue)
        PersistenceController.shared.save()
        loadSourcesFromCoreData()
        scanApplications()
    }

    public func removeCustomSourceDirectory(_ source: AppSourceItem) {
        guard source.isCustom else { return }
        let ctx = PersistenceController.shared.viewContext
        let req = NSFetchRequest<SourceEntity>(entityName: "SourceEntity")
        req.predicate = NSPredicate(format: "path == %@", source.path)
        if let list = try? ctx.fetch(req) {
            list.forEach { ctx.delete($0) }
            PersistenceController.shared.save()
            loadSourcesFromCoreData()
            scanApplications()
        }
    }

    // MARK: - Application Scanning & Metadata

    public func scanApplications() {
        let fm = FileManager.default
        let enabledPaths = sources.filter { $0.enabled }.map { $0.path }
        var discoveredURLs: [URL] = []
        var seenPaths = Set<String>()

        for dirPath in enabledPaths {
            let dirURL = URL(fileURLWithPath: dirPath)
            guard let enumerator = fm.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey, .isAliasFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if enumerator.level > 2 {
                    enumerator.skipDescendants()
                    continue
                }
                if fileURL.pathExtension.lowercased() == "app" {
                    let resolvedPath = fileURL.resolvingSymlinksInPath().path
                    if !seenPaths.contains(resolvedPath) {
                        seenPaths.insert(resolvedPath)
                        discoveredURLs.append(fileURL)
                    }
                    enumerator.skipDescendants()
                }
            }
        }

        // Include allowlisted CoreServices apps (like Finder, Screen Sharing)
        for coreAppPath in coreServicesAllowlist {
            if fm.fileExists(atPath: coreAppPath), !seenPaths.contains(coreAppPath) {
                seenPaths.insert(coreAppPath)
                discoveredURLs.append(URL(fileURLWithPath: coreAppPath))
            }
        }

        var scannedByBundleOrPath: [String: LaunchpadApp] = [:]
        for appURL in discoveredURLs {
            guard let app = parseAppBundle(at: appURL) else { continue }
            // Skip original LaunchOS or our own replica if desired, or keep all productivity apps
            if app.bundleId == "app.remixdesign.LaunchOSReplica" { continue }
            scannedByBundleOrPath[app.id] = app
        }

        reconcileScannedAppsWithDatabase(scannedByBundleOrPath)
    }

    private func parseAppBundle(at url: URL) -> LaunchpadApp? {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary
        let rawBundleId = bundle?.bundleIdentifier
            ?? (info?["CFBundleIdentifier"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleName = (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let localizedName = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive, .anchored, .backwards])
        let displayName = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (info?["CFBundleDisplayName"] as? String)
            ?? localizedName

        let category = (info?["LSApplicationCategoryType"] as? String) ?? "public.app-category.utilities"
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "1"

        var addedDate = Date.distantPast
        var lastOpenedDate = Date.distantPast
        if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            if let added = MDItemCopyAttribute(mdItem, kMDItemDateAdded) as? Date {
                addedDate = added
            } else if let created = MDItemCopyAttribute(mdItem, kMDItemContentCreationDate) as? Date {
                addedDate = created
            }
            if let used = MDItemCopyAttribute(mdItem, kMDItemLastUsedDate) as? Date {
                lastOpenedDate = used
            }
        }

        let id = "\(rawBundleId)|\(url.path)"
        return LaunchpadApp(
            id: id,
            name: displayName,
            defaultName: displayName,
            alias: nil,
            bundleId: rawBundleId,
            bundleName: bundleName,
            url: url,
            category: category,
            version: version,
            build: build,
            order: 0,
            hidden: false,
            addedDate: addedDate,
            lastOpenedDate: lastOpenedDate,
            isSourceUnavailable: !FileManager.default.fileExists(atPath: url.path)
        )
    }

    // MARK: - Core Data Synchronization

    private func reconcileScannedAppsWithDatabase(_ scanned: [String: LaunchpadApp]) {
        var existingFlatApps: [String: LaunchpadApp] = [:]
        for group in allGroups {
            for app in group.apps {
                existingFlatApps[app.bundleId] = app
                existingFlatApps[app.id] = app
            }
        }
        for app in hiddenApps {
            existingFlatApps[app.bundleId] = app
            existingFlatApps[app.id] = app
        }

        // Update metadata of existing groups
        var updatedGroups: [LaunchpadGroup] = []
        var matchedKeys = Set<String>()

        for var group in allGroups {
            var newGroupApps: [LaunchpadApp] = []
            for var app in group.apps {
                if let match = scanned[app.id] ?? scanned.values.first(where: { $0.bundleId == app.bundleId }) {
                    matchedKeys.insert(match.id)
                    app.url = match.url
                    app.version = match.version
                    app.build = match.build
                    app.addedDate = match.addedDate
                    app.lastOpenedDate = match.lastOpenedDate
                    app.isSourceUnavailable = false
                    if !app.hidden {
                        newGroupApps.append(app)
                    }
                }
            }
            if !newGroupApps.isEmpty {
                group.apps = newGroupApps
                updatedGroups.append(group)
            }
        }

        var updatedHidden: [LaunchpadApp] = []
        for var app in hiddenApps {
            if let match = scanned[app.id] ?? scanned.values.first(where: { $0.bundleId == app.bundleId }) {
                matchedKeys.insert(match.id)
                app.url = match.url
                app.hidden = true
                updatedHidden.append(app)
            }
        }

        // Newly discovered apps go to the last page or fill available pages
        let newApps = scanned.values
            .filter { !matchedKeys.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        let cap = AppState.shared.pageCapacity
        var maxPage = updatedGroups.map { $0.page }.max() ?? 0
        var countOnMaxPage = updatedGroups.filter { $0.page == maxPage }.count
        var nextOrder = (updatedGroups.filter { $0.page == maxPage }.map { $0.order }.max() ?? -1) + 1

        for var app in newApps {
            if countOnMaxPage >= cap {
                maxPage += 1
                countOnMaxPage = 0
                nextOrder = 0
            }
            app.order = 0
            let grp = LaunchpadGroup(
                id: UUID().uuidString,
                name: app.displayName,
                isFolder: false,
                page: maxPage,
                order: nextOrder,
                apps: [app]
            )
            updatedGroups.append(grp)
            countOnMaxPage += 1
            nextOrder += 1
        }

        self.allGroups = normalizePagesAndOrders(updatedGroups)
        self.hiddenApps = updatedHidden
        AppState.shared.hiddenAppCount = updatedHidden.count
        saveLayoutToCoreData()
        applyFilterAndSort()
    }

    private func normalizePagesAndOrders(_ groups: [LaunchpadGroup]) -> [LaunchpadGroup] {
        let distinctPages = Array(Set(groups.map { $0.page })).sorted()
        var result: [LaunchpadGroup] = []
        for (newPageIdx, oldPage) in distinctPages.enumerated() {
            let pageItems = groups
                .filter { $0.page == oldPage }
                .sorted { $0.order < $1.order }
            for (orderIdx, var item) in pageItems.enumerated() {
                item.page = newPageIdx
                item.order = orderIdx
                if !item.isFolder, let first = item.apps.first {
                    item.name = first.displayName
                }
                result.append(item)
            }
        }
        return result
    }

    public func loadLayoutFromCoreData() {
        let ctx = PersistenceController.shared.viewContext
        let groupReq = NSFetchRequest<GroupEntity>(entityName: "GroupEntity")
        groupReq.sortDescriptors = [
            NSSortDescriptor(key: "page", ascending: true),
            NSSortDescriptor(key: "order", ascending: true)
        ]
        let groupEntities = (try? ctx.fetch(groupReq)) ?? []

        var loadedGroups: [LaunchpadGroup] = []
        var loadedHidden: [LaunchpadApp] = []

        for gEnt in groupEntities {
            let appSet = (gEnt.apps?.array as? [AppEntity]) ?? []
            var groupApps: [LaunchpadApp] = []
            for (idx, aEnt) in appSet.enumerated() {
                guard let url = aEnt.url else { continue }
                let app = LaunchpadApp(
                    id: aEnt.id ?? UUID().uuidString,
                    name: aEnt.name ?? url.deletingPathExtension().lastPathComponent,
                    defaultName: aEnt.bundleName ?? aEnt.name ?? "",
                    alias: aEnt.alias,
                    bundleId: aEnt.bundleId ?? "",
                    bundleName: aEnt.bundleName ?? "",
                    url: url,
                    category: aEnt.category ?? "",
                    version: aEnt.version ?? "",
                    build: aEnt.build ?? "",
                    order: Int(aEnt.order > 0 ? aEnt.order : Int64(idx)),
                    hidden: aEnt.hidden,
                    addedDate: Date.distantPast,
                    lastOpenedDate: Date.distantPast,
                    isSourceUnavailable: !FileManager.default.fileExists(atPath: url.path)
                )
                if app.hidden {
                    loadedHidden.append(app)
                } else {
                    groupApps.append(app)
                }
            }
            if !groupApps.isEmpty {
                loadedGroups.append(
                    LaunchpadGroup(
                        id: gEnt.id ?? UUID().uuidString,
                        name: gEnt.name ?? groupApps.first?.displayName ?? "Folder",
                        isFolder: gEnt.isFolder && groupApps.count > 1,
                        page: Int(gEnt.page),
                        order: Int(gEnt.order),
                        apps: groupApps
                    )
                )
            }
        }

        // Also fetch ungrouped hidden AppEntity records
        let hiddenReq = NSFetchRequest<AppEntity>(entityName: "AppEntity")
        hiddenReq.predicate = NSPredicate(format: "hidden == YES")
        if let hiddenEntities = try? ctx.fetch(hiddenReq) {
            for aEnt in hiddenEntities {
                guard let url = aEnt.url else { continue }
                let id = aEnt.id ?? UUID().uuidString
                if !loadedHidden.contains(where: { $0.id == id }) {
                    loadedHidden.append(
                        LaunchpadApp(
                            id: id,
                            name: aEnt.name ?? url.deletingPathExtension().lastPathComponent,
                            defaultName: aEnt.bundleName ?? aEnt.name ?? "",
                            alias: aEnt.alias,
                            bundleId: aEnt.bundleId ?? "",
                            bundleName: aEnt.bundleName ?? "",
                            url: url,
                            category: aEnt.category ?? "",
                            version: aEnt.version ?? "",
                            build: aEnt.build ?? "",
                            order: Int(aEnt.order),
                            hidden: true,
                            addedDate: Date.distantPast,
                            lastOpenedDate: Date.distantPast,
                            isSourceUnavailable: !FileManager.default.fileExists(atPath: url.path)
                        )
                    )
                }
            }
        }

        self.allGroups = loadedGroups
        self.hiddenApps = loadedHidden
        AppState.shared.hiddenAppCount = loadedHidden.count
    }

    public func saveLayoutToCoreData() {
        let ctx = PersistenceController.shared.viewContext
        if let oldGroups = try? ctx.fetch(NSFetchRequest<GroupEntity>(entityName: "GroupEntity")) {
            oldGroups.forEach { ctx.delete($0) }
        }
        if let oldApps = try? ctx.fetch(NSFetchRequest<AppEntity>(entityName: "AppEntity")) {
            oldApps.forEach { ctx.delete($0) }
        }

        for grp in allGroups {
            let gEnt = GroupEntity(context: ctx)
            gEnt.id = grp.id
            gEnt.name = grp.name
            gEnt.isFolder = grp.isFolder
            gEnt.page = Int64(grp.page)
            gEnt.order = Int64(grp.order)

            let orderedApps = NSMutableOrderedSet()
            for (idx, app) in grp.apps.enumerated() {
                let aEnt = AppEntity(context: ctx)
                aEnt.id = app.id
                aEnt.name = app.name
                aEnt.alias = app.alias
                aEnt.bundleId = app.bundleId
                aEnt.bundleName = app.bundleName
                aEnt.url = app.url
                aEnt.category = app.category
                aEnt.version = app.version
                aEnt.build = app.build
                aEnt.order = Int64(idx)
                aEnt.hidden = false
                aEnt.group = gEnt
                orderedApps.add(aEnt)
            }
            gEnt.apps = orderedApps
        }

        for app in hiddenApps {
            let aEnt = AppEntity(context: ctx)
            aEnt.id = app.id
            aEnt.name = app.name
            aEnt.alias = app.alias
            aEnt.bundleId = app.bundleId
            aEnt.bundleName = app.bundleName
            aEnt.url = app.url
            aEnt.category = app.category
            aEnt.version = app.version
            aEnt.build = app.build
            aEnt.order = 0
            aEnt.hidden = true
        }

        PersistenceController.shared.save()
    }

    // MARK: - Filtering & Sorting

    public func applyFilterAndSort() {
        let q = currentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = AppState.shared

        if !q.isEmpty {
            var matchingApps: [LaunchpadApp] = []
            var seenIDs = Set<String>()
            for grp in allGroups {
                for app in grp.apps where app.matchesSearch(q) && !seenIDs.contains(app.id) {
                    matchingApps.append(app)
                    seenIDs.insert(app.id)
                }
            }
            if state.showHiddenAppsInSearch {
                for app in hiddenApps where app.matchesSearch(q) && !seenIDs.contains(app.id) {
                    matchingApps.append(app)
                    seenIDs.insert(app.id)
                }
            }
            // Sort by relevance score descending (exact match -> prefix -> initials -> pinyin -> contains)
            matchingApps.sort { $0.searchScore(for: q) > $1.searchScore(for: q) }

            self.filteredGroups = matchingApps.enumerated().map { idx, app in
                LaunchpadGroup(
                    id: "search-\(app.id)",
                    name: app.displayName,
                    isFolder: false,
                    page: idx / state.pageCapacity,
                    order: idx % state.pageCapacity,
                    apps: [app]
                )
            }

            // Auto-select the first result, or maintain current selection if still matching
            if let sel = selectedSearchAppID, matchingApps.contains(where: { $0.id == sel }) {
                // keep selection
            } else {
                selectedSearchAppID = matchingApps.first?.id
            }
            return
        }

        selectedSearchAppID = nil

        if state.sortBy == .custom {
            self.filteredGroups = allGroups
            return
        }

        // Non-custom dynamic sort
        let sorted = allGroups.sorted { lhs, rhs in
            let asc = state.sortOrder == .ascending
            switch state.sortBy {
            case .custom:
                return lhs.order < rhs.order
            case .name:
                let cmp = lhs.name.localizedStandardCompare(rhs.name)
                return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            case .added:
                let lDate = lhs.primaryApp?.addedDate ?? .distantPast
                let rDate = rhs.primaryApp?.addedDate ?? .distantPast
                return asc ? (lDate < rDate) : (lDate > rDate)
            case .opened:
                let lDate = lhs.primaryApp?.lastOpenedDate ?? .distantPast
                let rDate = rhs.primaryApp?.lastOpenedDate ?? .distantPast
                return asc ? (lDate < rDate) : (lDate > rDate)
            }
        }

        let cap = state.pageCapacity
        self.filteredGroups = sorted.enumerated().map { idx, grp in
            var copy = grp
            copy.page = idx / cap
            copy.order = idx % cap
            return copy
        }
    }

    // MARK: - Search Selection Navigation & Launch

    public func moveSearchSelection(deltaRow: Int, deltaCol: Int, cols: Int) {
        let matchingApps = filteredGroups.compactMap { $0.primaryApp }
        guard !matchingApps.isEmpty else { return }

        let currentIndex = matchingApps.firstIndex(where: { $0.id == selectedSearchAppID }) ?? 0
        let total = matchingApps.count
        var nextIndex = currentIndex

        if deltaRow != 0 {
            nextIndex += deltaRow * cols
        }
        if deltaCol != 0 {
            nextIndex += deltaCol
        }

        nextIndex = max(0, min(total - 1, nextIndex))
        selectedSearchAppID = matchingApps[nextIndex].id
    }

    public func cycleSearchSelection(forward: Bool) {
        let matchingApps = filteredGroups.compactMap { $0.primaryApp }
        guard !matchingApps.isEmpty else { return }

        let currentIndex = matchingApps.firstIndex(where: { $0.id == selectedSearchAppID }) ?? 0
        let total = matchingApps.count
        let nextIndex = forward ? ((currentIndex + 1) % total) : ((currentIndex - 1 + total) % total)
        selectedSearchAppID = matchingApps[nextIndex].id
    }

    public func launchSelectedSearchApp() {
        let matchingApps = filteredGroups.compactMap { $0.primaryApp }
        guard let app = matchingApps.first(where: { $0.id == selectedSearchAppID }) ?? matchingApps.first else {
            return
        }
        LaunchpadWindowController.shared.hide()
        launchApp(app)
    }

    public func removeAppRecord(_ app: LaunchpadApp) {
        for i in allGroups.indices.reversed() {
            allGroups[i].apps.removeAll { $0.id == app.id }
            if allGroups[i].apps.isEmpty {
                allGroups.remove(at: i)
            } else if allGroups[i].apps.count == 1 && allGroups[i].isFolder {
                allGroups[i].isFolder = false
                allGroups[i].name = allGroups[i].apps[0].displayName
            }
        }
        hiddenApps.removeAll { $0.id == app.id }
        allGroups = normalizePagesAndOrders(allGroups)
        saveLayoutToCoreData()
        applyFilterAndSort()
    }

    public var totalPages: Int {
        max(1, (filteredGroups.map { $0.page }.max() ?? 0) + 1)
    }

    public func groups(forPage page: Int) -> [LaunchpadGroup] {
        filteredGroups
            .filter { $0.page == page }
            .sorted { $0.order < $1.order }
    }

    // MARK: - Interactive Operations (Move, Folder, Hide, Rename, Reorganize)

    public func moveGroup(draggedID: String, toTargetID targetID: String, mergeIntoFolder: Bool = false) {
        guard draggedID != targetID else { return }
        guard let sourceIdx = allGroups.firstIndex(where: { $0.id == draggedID }),
              let targetIdx = allGroups.firstIndex(where: { $0.id == targetID }) else { return }

        if mergeIntoFolder {
            let sourceGroup = allGroups[sourceIdx]
            var targetGroup = allGroups[targetIdx]
            let combinedApps = targetGroup.apps + sourceGroup.apps
            targetGroup.isFolder = true
            if !allGroups[targetIdx].isFolder {
                targetGroup.name = suggestFolderName(for: combinedApps)
            }
            targetGroup.apps = combinedApps
            allGroups[targetIdx] = targetGroup
            allGroups.remove(at: sourceIdx)
        } else {
            let targetPage = allGroups[targetIdx].page
            let targetOrder = allGroups[targetIdx].order
            var dragged = allGroups.remove(at: sourceIdx)
            dragged.page = targetPage
            dragged.order = targetOrder

            // Re-insert on targetPage at targetOrder
            var pageItems = allGroups.filter { $0.page == targetPage }.sorted { $0.order < $1.order }
            let insertAt = min(max(0, targetOrder), pageItems.count)
            pageItems.insert(dragged, at: insertAt)
            for (i, _) in pageItems.enumerated() {
                pageItems[i].order = i
            }
            allGroups.removeAll { $0.page == targetPage }
            allGroups.append(contentsOf: pageItems)
        }

        allGroups = normalizePagesAndOrders(allGroups)
        saveLayoutToCoreData()
        applyFilterAndSort()
    }

    public func createFolder(withGroupIDs ids: Set<String>, name: String? = nil) {
        let targets = allGroups.filter { ids.contains($0.id) }.sorted { ($0.page, $0.order) < ($1.page, $1.order) }
        guard let first = targets.first else { return }
        let apps = targets.flatMap { $0.apps }
        guard apps.count > 1 else { return }

        let folderName = name ?? suggestFolderName(for: apps)
        let newFolder = LaunchpadGroup(
            id: UUID().uuidString,
            name: folderName,
            isFolder: true,
            page: first.page,
            order: first.order,
            apps: apps
        )

        allGroups.removeAll { ids.contains($0.id) }
        allGroups.append(newFolder)
        allGroups = normalizePagesAndOrders(allGroups)
        selectedGroupIDs.removeAll()
        saveLayoutToCoreData()
        applyFilterAndSort()
    }

    public func ungroupFolder(groupID: String) {
        guard let idx = allGroups.firstIndex(where: { $0.id == groupID }) else { return }
        let folder = allGroups.remove(at: idx)
        let basePage = folder.page
        let maxOrderOnPage = allGroups.filter { $0.page == basePage }.map { $0.order }.max() ?? -1

        for (offset, app) in folder.apps.enumerated() {
            let single = LaunchpadGroup(
                id: UUID().uuidString,
                name: app.displayName,
                isFolder: false,
                page: basePage,
                order: maxOrderOnPage + 1 + offset,
                apps: [app]
            )
            allGroups.append(single)
        }

        if openedFolderID == groupID {
            openedFolderID = nil
        }
        allGroups = normalizePagesAndOrders(allGroups)
        saveLayoutToCoreData()
        applyFilterAndSort()
    }

    public func removeAppFromFolder(appID: String, folderID: String) {
        guard let idx = allGroups.firstIndex(where: { $0.id == folderID }) else { return }
        var folder = allGroups[idx]
        guard let appIdx = folder.apps.firstIndex(where: { $0.id == appID }) else { return }
        let removedApp = folder.apps.remove(at: appIdx)

        if folder.apps.isEmpty {
            allGroups.remove(at: idx)
            if openedFolderID == folderID { openedFolderID = nil }
        } else if folder.apps.count == 1 {
            folder.isFolder = false
            folder.name = folder.apps[0].displayName
            allGroups[idx] = folder
            if openedFolderID == folderID { openedFolderID = nil }
        } else {
            allGroups[idx] = folder
        }

        let maxOrder = allGroups.filter { $0.page == folder.page }.map { $0.order }.max() ?? -1
        allGroups.append(
            LaunchpadGroup(
                id: UUID().uuidString,
                name: removedApp.displayName,
                isFolder: false,
                page: folder.page,
                order: maxOrder + 1,
                apps: [removedApp]
            )
        )
        allGroups = normalizePagesAndOrders(allGroups)
        saveLayoutToCoreData()
        applyFilterAndSort()
    }

    public func renameGroup(groupID: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = allGroups.firstIndex(where: { $0.id == groupID }) else { return }
        allGroups[idx].name = trimmed
        if !allGroups[idx].isFolder, !allGroups[idx].apps.isEmpty {
            allGroups[idx].apps[0].alias = trimmed
        }
        saveLayoutToCoreData()
        applyFilterAndSort()
    }

    public func hideApp(_ app: LaunchpadApp) {
        for i in allGroups.indices.reversed() {
            allGroups[i].apps.removeAll { $0.id == app.id }
            if allGroups[i].apps.isEmpty {
                allGroups.remove(at: i)
            } else if allGroups[i].apps.count == 1 && allGroups[i].isFolder {
                allGroups[i].isFolder = false
                allGroups[i].name = allGroups[i].apps[0].displayName
            }
        }
        var hiddenCopy = app
        hiddenCopy.hidden = true
        if !hiddenApps.contains(where: { $0.id == app.id }) {
            hiddenApps.append(hiddenCopy)
        }
        AppState.shared.hiddenAppCount = hiddenApps.count
        allGroups = normalizePagesAndOrders(allGroups)
        saveLayoutToCoreData()
        applyFilterAndSort()
    }

    public func unhideApp(_ app: LaunchpadApp) {
        hiddenApps.removeAll { $0.id == app.id }
        var visible = app
        visible.hidden = false
        let lastPage = allGroups.map { $0.page }.max() ?? 0
        let lastOrder = (allGroups.filter { $0.page == lastPage }.map { $0.order }.max() ?? -1) + 1
        allGroups.append(
            LaunchpadGroup(
                id: UUID().uuidString,
                name: visible.displayName,
                isFolder: false,
                page: lastPage,
                order: lastOrder,
                apps: [visible]
            )
        )
        AppState.shared.hiddenAppCount = hiddenApps.count
        allGroups = normalizePagesAndOrders(allGroups)
        saveLayoutToCoreData()
        applyFilterAndSort()
    }

    public func moveGroupToPage(_ groupID: String, targetPage: Int) {
        guard let idx = allGroups.firstIndex(where: { $0.id == groupID }) else { return }
        var grp = allGroups.remove(at: idx)
        let maxOrder = (allGroups.filter { $0.page == targetPage }.map { $0.order }.max() ?? -1) + 1
        grp.page = targetPage
        grp.order = maxOrder
        allGroups.append(grp)
        allGroups = normalizePagesAndOrders(allGroups)
        saveLayoutToCoreData()
        applyFilterAndSort()
    }

    public func reorganizeLayout(with rules: ReorganizeRules) {
        let currentPage = AppState.shared.currentPage
        let targetScopeGroups: [LaunchpadGroup]
        let untouchedGroups: [LaunchpadGroup]

        if rules.pageScope == .currentPage {
            targetScopeGroups = allGroups.filter { $0.page == currentPage }
            untouchedGroups = allGroups.filter { $0.page != currentPage }
        } else {
            targetScopeGroups = allGroups
            untouchedGroups = []
        }

        var workingGroups: [LaunchpadGroup] = []
        if rules.removesAllFolders {
            for grp in targetScopeGroups {
                for app in grp.apps {
                    workingGroups.append(
                        LaunchpadGroup(
                            id: UUID().uuidString,
                            name: app.displayName,
                            isFolder: false,
                            page: grp.page,
                            order: grp.order,
                            apps: [app]
                        )
                    )
                }
            }
        } else {
            workingGroups = targetScopeGroups.map { var g = $0; if rules.sortsFolderContents && g.isFolder { g.apps = sortApps(g.apps, method: rules.sortMethod, direction: rules.sortDirection) }; return g }
        }

        workingGroups.sort { lhs, rhs in
            // 1. Folder placement rule
            if rules.folderPlacement != .keep && lhs.isFolder != rhs.isFolder {
                return rules.folderPlacement == .front ? lhs.isFolder : rhs.isFolder
            }
            // 2. Apple App placement rule
            let lApple = !lhs.isFolder && (lhs.primaryApp?.isAppleSystemApp ?? false)
            let rApple = !rhs.isFolder && (rhs.primaryApp?.isAppleSystemApp ?? false)
            if rules.appleAppPlacement != .keep && lApple != rApple {
                return rules.appleAppPlacement == .front ? lApple : rApple
            }
            // 3. Sort method
            return compareGroups(lhs, rhs, method: rules.sortMethod, direction: rules.sortDirection)
        }

        let cap = AppState.shared.pageCapacity
        if rules.pageScope == .currentPage {
            for i in workingGroups.indices {
                workingGroups[i].page = currentPage
                workingGroups[i].order = i
            }
            allGroups = normalizePagesAndOrders(untouchedGroups + workingGroups)
        } else {
            for i in workingGroups.indices {
                if rules.fillsEmptySlots {
                    workingGroups[i].page = i / cap
                    workingGroups[i].order = i % cap
                } else {
                    workingGroups[i].order = i
                }
            }
            allGroups = normalizePagesAndOrders(workingGroups)
        }

        AppState.shared.sortBy = .custom
        saveLayoutToCoreData()
        applyFilterAndSort()
    }

    private func sortApps(_ apps: [LaunchpadApp], method: ReorganizeSortMethod, direction: SortOrderOption) -> [LaunchpadApp] {
        let asc = direction == .ascending
        return apps.sorted { lhs, rhs in
            switch method {
            case .currentOrder:
                return lhs.order < rhs.order
            case .name:
                let cmp = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            case .dateAdded:
                return asc ? (lhs.addedDate < rhs.addedDate) : (lhs.addedDate > rhs.addedDate)
            case .lastUsed:
                return asc ? (lhs.lastOpenedDate < rhs.lastOpenedDate) : (lhs.lastOpenedDate > rhs.lastOpenedDate)
            case .iconColor:
                let lHue = AppIconRepository.shared.dominantHue(for: lhs)
                let rHue = AppIconRepository.shared.dominantHue(for: rhs)
                return asc ? (lHue < rHue) : (lHue > rHue)
            }
        }
    }

    private func compareGroups(_ lhs: LaunchpadGroup, _ rhs: LaunchpadGroup, method: ReorganizeSortMethod, direction: SortOrderOption) -> Bool {
        let asc = direction == .ascending
        switch method {
        case .currentOrder:
            return (lhs.page, lhs.order) < (rhs.page, rhs.order)
        case .name:
            let cmp = lhs.name.localizedStandardCompare(rhs.name)
            return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        case .dateAdded:
            let lDate = lhs.primaryApp?.addedDate ?? .distantPast
            let rDate = rhs.primaryApp?.addedDate ?? .distantPast
            return asc ? (lDate < rDate) : (lDate > rDate)
        case .lastUsed:
            let lDate = lhs.primaryApp?.lastOpenedDate ?? .distantPast
            let rDate = rhs.primaryApp?.lastOpenedDate ?? .distantPast
            return asc ? (lDate < rDate) : (lDate > rDate)
        case .iconColor:
            let lHue = lhs.primaryApp.map { AppIconRepository.shared.dominantHue(for: $0) } ?? 0
            let rHue = rhs.primaryApp.map { AppIconRepository.shared.dominantHue(for: $0) } ?? 0
            return asc ? (lHue < rHue) : (lHue > rHue)
        }
    }

    private func suggestFolderName(for apps: [LaunchpadApp]) -> String {
        guard let cat = apps.first?.category else { return "文件夹" }
        if cat.contains("developer") { return "开发者工具" }
        if cat.contains("productivity") { return "效率" }
        if cat.contains("graphics") { return "图形与设计" }
        if cat.contains("video") || cat.contains("music") || cat.contains("entertainment") { return "影音娱乐" }
        if cat.contains("social") { return "社交" }
        if cat.contains("games") { return "游戏" }
        if cat.contains("utilities") { return "实用工具" }
        return "文件夹"
    }

    // MARK: - Finder & Dock Actions (Observed AppleScript from __cstring)

    public func launchApp(_ app: LaunchpadApp) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    public func revealInFinder(_ app: LaunchpadApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    public func showFinderGetInfo(_ app: LaunchpadApp) {
        let scriptSource = """
        set appPath to POSIX file "\(app.url.path)" as alias
        tell application "Finder"
            activate
            open information window of appPath
        end tell
        """
        if let script = NSAppleScript(source: scriptSource) {
            var err: NSDictionary?
            script.executeAndReturnError(&err)
        } else {
            revealInFinder(app)
        }
    }

    public func addAppToDock(_ app: LaunchpadApp) {
        // Observed in LaunchOS __cstring: uses defaults write com.apple.dock persistent-apps or Finder Ctrl+Shift+Cmd+T
        let tileXml = "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>\(app.url.path)</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.dock", "persistent-apps", "-array-add", tileXml]
        try? task.run()
        task.waitUntilExit()

        let killDock = Process()
        killDock.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killDock.arguments = ["Dock"]
        try? killDock.run()
    }

    // MARK: - NativeDataManager (Import from System Launchpad DB or Original LaunchOS DB)

    @discardableResult
    public func importFromExistingLaunchOSDatabaseIfAvailable() -> Bool {
        let originalPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/LaunchOS/LaunchOS.sqlite")
        guard FileManager.default.fileExists(atPath: originalPath) else { return false }

        var db: OpaquePointer?
        guard sqlite3_open_v2(originalPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_close(db) }

        struct RawGroup {
            var pk: Int
            var id: String
            var name: String
            var isFolder: Bool
            var page: Int
            var order: Int
        }

        var rawGroups: [Int: RawGroup] = [:]
        var gStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT Z_PK, ZID, ZNAME, ZISFOLDER, ZPAGE, ZORDER FROM ZGROUPENTITY ORDER BY ZPAGE, ZORDER", -1, &gStmt, nil) == SQLITE_OK {
            while sqlite3_step(gStmt) == SQLITE_ROW {
                let pk = Int(sqlite3_column_int64(gStmt, 0))
                let zid = sqlite3_column_text(gStmt, 1).map { String(cString: $0) } ?? UUID().uuidString
                let zname = sqlite3_column_text(gStmt, 2).map { String(cString: $0) } ?? "Folder"
                let isFolder = sqlite3_column_int(gStmt, 3) != 0
                let page = Int(sqlite3_column_int64(gStmt, 4))
                let order = Int(sqlite3_column_int64(gStmt, 5))
                rawGroups[pk] = RawGroup(pk: pk, id: zid, name: zname, isFolder: isFolder, page: page, order: order)
            }
        }
        sqlite3_finalize(gStmt)

        guard !rawGroups.isEmpty else { return false }

        var appsByGroupPK: [Int: [LaunchpadApp]] = [:]
        var importedHidden: [LaunchpadApp] = []
        var aStmt: OpaquePointer?
        let appQuery = "SELECT ZID, ZNAME, ZBUNDLENAME, ZALIAS, ZBUNDLEID, ZURL, ZCATEGORY, ZVERSION, ZBUILD, ZORDER, ZHIDDEN, ZGROUP FROM ZAPPENTITY ORDER BY ZGROUP, Z_FOK_GROUP, ZORDER"
        if sqlite3_prepare_v2(db, appQuery, -1, &aStmt, nil) == SQLITE_OK {
            while sqlite3_step(aStmt) == SQLITE_ROW {
                let zid = sqlite3_column_text(aStmt, 0).map { String(cString: $0) } ?? UUID().uuidString
                let zname = sqlite3_column_text(aStmt, 1).map { String(cString: $0) } ?? ""
                let zbundleName = sqlite3_column_text(aStmt, 2).map { String(cString: $0) } ?? zname
                let zalias = sqlite3_column_text(aStmt, 3).map { String(cString: $0) }
                let zbundleId = sqlite3_column_text(aStmt, 4).map { String(cString: $0) } ?? ""
                let zurlStr = sqlite3_column_text(aStmt, 5).map { String(cString: $0) } ?? ""
                let zcat = sqlite3_column_text(aStmt, 6).map { String(cString: $0) } ?? ""
                let zver = sqlite3_column_text(aStmt, 7).map { String(cString: $0) } ?? ""
                let zbuild = sqlite3_column_text(aStmt, 8).map { String(cString: $0) } ?? ""
                let zorder = Int(sqlite3_column_int64(aStmt, 9))
                let zhidden = sqlite3_column_int(aStmt, 10) != 0
                let zgroup = Int(sqlite3_column_int64(aStmt, 11))

                let url = URL(string: zurlStr) ?? URL(fileURLWithPath: zurlStr)
                let app = LaunchpadApp(
                    id: zid,
                    name: zname,
                    defaultName: zbundleName,
                    alias: zalias,
                    bundleId: zbundleId,
                    bundleName: zbundleName,
                    url: url,
                    category: zcat,
                    version: zver,
                    build: zbuild,
                    order: zorder,
                    hidden: zhidden,
                    addedDate: .distantPast,
                    lastOpenedDate: .distantPast,
                    isSourceUnavailable: !FileManager.default.fileExists(atPath: url.path)
                )
                if zhidden {
                    importedHidden.append(app)
                } else {
                    appsByGroupPK[zgroup, default: []].append(app)
                }
            }
        }
        sqlite3_finalize(aStmt)

        var builtGroups: [LaunchpadGroup] = []
        for (_, rg) in rawGroups.sorted(by: { ($0.value.page, $0.value.order) < ($1.value.page, $1.value.order) }) {
            if let apps = appsByGroupPK[rg.pk], !apps.isEmpty {
                builtGroups.append(
                    LaunchpadGroup(
                        id: rg.id,
                        name: rg.name,
                        isFolder: rg.isFolder && apps.count > 1,
                        page: rg.page,
                        order: rg.order,
                        apps: apps
                    )
                )
            }
        }

        guard !builtGroups.isEmpty else { return false }
        self.allGroups = normalizePagesAndOrders(builtGroups)
        self.hiddenApps = importedHidden
        AppState.shared.hiddenAppCount = importedHidden.count
        saveLayoutToCoreData()
        applyFilterAndSort()
        return true
    }

    public func importSystemLaunchpadData() -> Result<(Int, Int), Error> {
        // First try system com.apple.dock.launchpad/db/db via /usr/bin/getconf DARWIN_USER_DIR
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        proc.arguments = ["DARWIN_USER_DIR"]
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        let userDir = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dockDBPath = (userDir as NSString).appendingPathComponent("com.apple.dock.launchpad/db/db")

        if FileManager.default.fileExists(atPath: dockDBPath),
           let counts = parseSystemDockLaunchpadSQLite(at: dockDBPath) {
            return .success(counts)
        }

        // Fallback to existing LaunchOS database if system Launchpad DB is unavailable (macOS 26+)
        if importFromExistingLaunchOSDatabaseIfAvailable() {
            let folderCount = allGroups.filter { $0.isFolder }.count
            let appCount = allGroups.reduce(0) { $0 + $1.apps.count }
            return .success((appCount, folderCount))
        }

        scanApplications()
        let folderCount = allGroups.filter { $0.isFolder }.count
        let appCount = allGroups.reduce(0) { $0 + $1.apps.count }
        return .success((appCount, folderCount))
    }

    private func parseSystemDockLaunchpadSQLite(at path: String) -> (Int, Int)? {
        // Exact queries observed in LaunchOS/NativeDataManager.swift (__cstring):
        // SELECT rowid, uuid, flags, type, parent_id, ordering FROM items ORDER BY parent_id, ordering
        // SELECT item_id, title FROM groups
        // SELECT item_id, title, bundleid, storeid FROM apps
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        var groupTitles: [Int: String] = [:]
        var gStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT item_id, title FROM groups", -1, &gStmt, nil) == SQLITE_OK {
            while sqlite3_step(gStmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(gStmt, 0))
                if let cstr = sqlite3_column_text(gStmt, 1) {
                    groupTitles[id] = String(cString: cstr)
                }
            }
        }
        sqlite3_finalize(gStmt)

        var appRecords: [Int: (title: String, bundleId: String)] = [:]
        var aStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT item_id, title, bundleid FROM apps", -1, &aStmt, nil) == SQLITE_OK {
            while sqlite3_step(aStmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(aStmt, 0))
                let title = sqlite3_column_text(aStmt, 1).map { String(cString: $0) } ?? ""
                let bid = sqlite3_column_text(aStmt, 2).map { String(cString: $0) } ?? ""
                appRecords[id] = (title, bid)
            }
        }
        sqlite3_finalize(aStmt)

        guard !appRecords.isEmpty else { return nil }
        scanApplications()
        return (allGroups.reduce(0) { $0 + $1.apps.count }, allGroups.filter { $0.isFolder }.count)
    }

    // MARK: - BackupManager (.launchos Import / Export)

    public func exportBackup(to url: URL) throws {
        let state = AppState.shared
        let setting = LaunchOSBackupDocument.Setting(
            columns: state.columnsPerPage,
            rows: state.rowsPerPage,
            browsingStyle: state.browsingStyle.rawValue
        )

        var groupRecords: [LaunchOSBackupDocument.GroupRecord] = []
        var appRecords: [LaunchOSBackupDocument.AppRecord] = []

        for grp in allGroups {
            groupRecords.append(
                LaunchOSBackupDocument.GroupRecord(
                    id: grp.id,
                    name: grp.name,
                    order: grp.order,
                    isFolder: grp.isFolder,
                    page: grp.page
                )
            )
            for (idx, app) in grp.apps.enumerated() {
                appRecords.append(
                    LaunchOSBackupDocument.AppRecord(
                        id: app.id,
                        groupId: grp.id,
                        bundleId: app.bundleId,
                        bundleName: app.bundleName,
                        version: app.version,
                        build: app.build,
                        name: app.name,
                        order: idx,
                        url: app.url.absoluteString,
                        alias: app.alias,
                        category: app.category,
                        hidden: false
                    )
                )
            }
        }

        for app in hiddenApps {
            appRecords.append(
                LaunchOSBackupDocument.AppRecord(
                    id: app.id,
                    groupId: "",
                    bundleId: app.bundleId,
                    bundleName: app.bundleName,
                    version: app.version,
                    build: app.build,
                    name: app.name,
                    order: 0,
                    url: app.url.absoluteString,
                    alias: app.alias,
                    category: app.category,
                    hidden: true
                )
            )
        }

        let sourceRecords = sources.map {
            LaunchOSBackupDocument.SourceRecord(id: $0.id, path: $0.path, type: $0.type.rawValue, enabled: $0.enabled)
        }

        let doc = LaunchOSBackupDocument(
            metadata: .init(version: "2.4.0", buildVersion: "485", exportDate: Date()),
            data: .init(setting: setting, apps: appRecords, groups: groupRecords, sources: sourceRecords)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(doc)
        try data.write(to: url, options: .atomic)
    }

    public func importBackup(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(LaunchOSBackupDocument.self, from: data)

        AppState.shared.columnsPerPage = doc.data.setting.columns
        AppState.shared.rowsPerPage = doc.data.setting.rows
        if let style = BrowsingStyle(rawValue: doc.data.setting.browsingStyle) {
            AppState.shared.browsingStyle = style
        }

        var appsByGroup: [String: [LaunchpadApp]] = [:]
        var newHidden: [LaunchpadApp] = []

        for rec in doc.data.apps {
            let resolvedURL = URL(string: rec.url) ?? URL(fileURLWithPath: rec.url)
            let app = LaunchpadApp(
                id: rec.id,
                name: rec.name,
                defaultName: rec.bundleName,
                alias: rec.alias,
                bundleId: rec.bundleId,
                bundleName: rec.bundleName,
                url: resolvedURL,
                category: rec.category,
                version: rec.version,
                build: rec.build,
                order: rec.order,
                hidden: rec.hidden,
                addedDate: .distantPast,
                lastOpenedDate: .distantPast,
                isSourceUnavailable: !FileManager.default.fileExists(atPath: resolvedURL.path)
            )
            if rec.hidden {
                newHidden.append(app)
            } else {
                appsByGroup[rec.groupId, default: []].append(app)
            }
        }

        var newGroups: [LaunchpadGroup] = []
        for gRec in doc.data.groups {
            let groupApps = (appsByGroup[gRec.id] ?? []).sorted { $0.order < $1.order }
            guard !groupApps.isEmpty else { continue }
            newGroups.append(
                LaunchpadGroup(
                    id: gRec.id,
                    name: gRec.name,
                    isFolder: gRec.isFolder && groupApps.count > 1,
                    page: gRec.page,
                    order: gRec.order,
                    apps: groupApps
                )
            )
        }

        self.allGroups = normalizePagesAndOrders(newGroups)
        self.hiddenApps = newHidden
        AppState.shared.hiddenAppCount = newHidden.count
        saveLayoutToCoreData()
        scanApplications()
    }
}
