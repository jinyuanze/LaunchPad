import Foundation
import CoreData
import AppKit

// MARK: - Core Data Managed Objects (Matching LaunchOS.mom ev_12acf033...)

@objc(AppEntity)
public class AppEntity: NSManagedObject {
    @NSManaged public var id: String?
    @NSManaged public var name: String?
    @NSManaged public var bundleId: String?
    @NSManaged public var bundleName: String?
    @NSManaged public var url: URL?
    @NSManaged public var alias: String?
    @NSManaged public var category: String?
    @NSManaged public var version: String?
    @NSManaged public var build: String?
    @NSManaged public var order: Int64
    @NSManaged public var hidden: Bool
    @NSManaged public var group: GroupEntity?
}

@objc(GroupEntity)
public class GroupEntity: NSManagedObject {
    @NSManaged public var id: String?
    @NSManaged public var name: String?
    @NSManaged public var isFolder: Bool
    @NSManaged public var page: Int64
    @NSManaged public var order: Int64
    @NSManaged public var apps: NSOrderedSet?
}

@objc(SourceEntity)
public class SourceEntity: NSManagedObject {
    @NSManaged public var id: UUID?
    @NSManaged public var path: String?
    @NSManaged public var enabled: Bool
    @NSManaged public var type: Int64
}

// MARK: - PersistenceController (Programmatic Core Data Model matching LaunchOS.mom)

public final class PersistenceController {
    public static let shared = PersistenceController()

    public let container: NSPersistentContainer

    public var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    public static func buildManagedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // 1. AppEntity
        let appEntity = NSEntityDescription()
        appEntity.name = "AppEntity"
        appEntity.managedObjectClassName = NSStringFromClass(AppEntity.self)

        func makeAttr(_ name: String, _ type: NSAttributeType, optional: Bool = true, defaultValue: Any? = nil) -> NSAttributeDescription {
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.isOptional = optional
            attr.defaultValue = defaultValue
            return attr
        }

        // 2. GroupEntity
        let groupEntity = NSEntityDescription()
        groupEntity.name = "GroupEntity"
        groupEntity.managedObjectClassName = NSStringFromClass(GroupEntity.self)

        // 3. SourceEntity
        let sourceEntity = NSEntityDescription()
        sourceEntity.name = "SourceEntity"
        sourceEntity.managedObjectClassName = NSStringFromClass(SourceEntity.self)

        // Relationships between AppEntity and GroupEntity
        let appToGroup = NSRelationshipDescription()
        appToGroup.name = "group"
        appToGroup.destinationEntity = groupEntity
        appToGroup.minCount = 0
        appToGroup.maxCount = 1
        appToGroup.isOptional = true
        appToGroup.deleteRule = .nullifyDeleteRule

        let groupToApps = NSRelationshipDescription()
        groupToApps.name = "apps"
        groupToApps.destinationEntity = appEntity
        groupToApps.minCount = 0
        groupToApps.maxCount = 0 // to-many
        groupToApps.isOptional = true
        groupToApps.isOrdered = true
        groupToApps.deleteRule = .nullifyDeleteRule

        appToGroup.inverseRelationship = groupToApps
        groupToApps.inverseRelationship = appToGroup

        appEntity.properties = [
            makeAttr("id", .stringAttributeType, optional: false, defaultValue: ""),
            makeAttr("name", .stringAttributeType, optional: false, defaultValue: ""),
            makeAttr("bundleId", .stringAttributeType, optional: false, defaultValue: ""),
            makeAttr("bundleName", .stringAttributeType, optional: false, defaultValue: ""),
            makeAttr("url", .URIAttributeType, optional: true),
            makeAttr("alias", .stringAttributeType, optional: true),
            makeAttr("category", .stringAttributeType, optional: false, defaultValue: ""),
            makeAttr("version", .stringAttributeType, optional: false, defaultValue: ""),
            makeAttr("build", .stringAttributeType, optional: false, defaultValue: ""),
            makeAttr("order", .integer64AttributeType, optional: true, defaultValue: 0),
            makeAttr("hidden", .booleanAttributeType, optional: true, defaultValue: false),
            appToGroup
        ]

        groupEntity.properties = [
            makeAttr("id", .stringAttributeType, optional: false, defaultValue: ""),
            makeAttr("name", .stringAttributeType, optional: true),
            makeAttr("isFolder", .booleanAttributeType, optional: false, defaultValue: false),
            makeAttr("page", .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttr("order", .integer64AttributeType, optional: false, defaultValue: 0),
            groupToApps
        ]

        sourceEntity.properties = [
            makeAttr("id", .UUIDAttributeType, optional: true),
            makeAttr("path", .stringAttributeType, optional: true),
            makeAttr("enabled", .booleanAttributeType, optional: false, defaultValue: true),
            makeAttr("type", .integer64AttributeType, optional: true, defaultValue: 0)
        ]

        model.entities = [appEntity, groupEntity, sourceEntity]
        return model
    }

    private init() {
        let model = Self.buildManagedObjectModel()
        container = NSPersistentContainer(name: "LaunchOS", managedObjectModel: model)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("LaunchOSReplica", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let storeURL = dbDir.appendingPathComponent("LaunchOS.sqlite")

        let desc = NSPersistentStoreDescription(url: storeURL)
        desc.shouldMigrateStoreAutomatically = true
        desc.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [desc]

        container.loadPersistentStores { _, error in
            if let error = error {
                NSLog("[LaunchOS] CoreData load error: \(error.localizedDescription)")
            }
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    public func save() {
        let context = container.viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            NSLog("[LaunchOS] Failed to save CoreData context: \(error.localizedDescription)")
        }
    }
}

// MARK: - In-Memory Domain Models (LaunchpadApp & LaunchpadGroup)

public struct LaunchpadApp: Identifiable, Hashable, Codable {
    public var id: String
    public var name: String
    public var defaultName: String
    public var alias: String?
    public var bundleId: String
    public var bundleName: String
    public var url: URL
    public var category: String
    public var version: String
    public var build: String
    public var order: Int
    public var hidden: Bool
    public var addedDate: Date
    public var lastOpenedDate: Date
    public var isSourceUnavailable: Bool

    public var displayName: String {
        if let alias = alias, !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return alias
        }
        return name
    }

    public var isAppleSystemApp: Bool {
        bundleId.hasPrefix("com.apple.") || url.path.hasPrefix("/System/")
    }

    public func searchScore(for query: String) -> Int {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return 0 }
        let nameLower = displayName.lowercased()
        let defLower = defaultName.lowercased()

        if nameLower == q || defLower == q { return 1000 }
        if nameLower.hasPrefix(q) || defLower.hasPrefix(q) { return 800 }

        let words = nameLower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if words.contains(where: { $0.hasPrefix(q) }) { return 700 }

        let initials = words.compactMap { $0.first.map(String.init) }.joined()
        if initials == q { return 650 }
        if initials.hasPrefix(q) { return 600 }

        let camelInitials = displayName.filter { $0.isUppercase }.lowercased()
        if camelInitials == q { return 550 }
        if camelInitials.hasPrefix(q) { return 500 }

        let mutable = NSMutableString(string: displayName) as CFMutableString
        if CFStringTransform(mutable, nil, kCFStringTransformToLatin, false),
           CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false) {
            let latin = (mutable as String).lowercased()
            let compactLatin = latin.replacingOccurrences(of: " ", with: "")
            if compactLatin == q { return 450 }
            if compactLatin.hasPrefix(q) { return 400 }

            let pinyinInitials = latin.split(separator: " ").compactMap { $0.first.map(String.init) }.joined()
            if pinyinInitials == q { return 350 }
            if pinyinInitials.hasPrefix(q) { return 300 }
            if compactLatin.contains(q) { return 250 }
            if pinyinInitials.contains(q) { return 200 }
        }

        if nameLower.contains(q) || defLower.contains(q) { return 150 }
        if bundleName.lowercased().contains(q) { return 100 }
        if bundleId.lowercased().contains(q) { return 50 }

        return 0
    }

    public func matchesSearch(_ query: String) -> Bool {
        searchScore(for: query) > 0
    }
}

public struct LaunchpadGroup: Identifiable, Hashable, Codable {
    public var id: String
    public var name: String
    public var isFolder: Bool
    public var page: Int
    public var order: Int
    public var apps: [LaunchpadApp]

    public var primaryApp: LaunchpadApp? {
        apps.first
    }
}

public enum AppSourceType: Int, Codable, CaseIterable {
    case system = 0
    case userHome = 1
    case external = 2

    public var title: String {
        switch self {
        case .system: return "系统默认目录"
        case .userHome: return "用户目录"
        case .external: return "自定义来源"
        }
    }
}

public struct AppSourceItem: Identifiable, Hashable, Codable {
    public var id: UUID
    public var path: String
    public var enabled: Bool
    public var type: AppSourceType
    public var isCustom: Bool { type == .external }
}

// MARK: - .launchos Backup Format (Matching refl[230..270] in BackupManager.swift)

public struct LaunchOSBackupDocument: Codable {
    public struct Metadata: Codable {
        public var version: String
        public var buildVersion: String
        public var exportDate: Date
    }

    public struct Setting: Codable {
        public var columns: Int
        public var rows: Int
        public var browsingStyle: String
    }

    public struct SourceRecord: Codable {
        public var id: UUID
        public var path: String
        public var type: Int
        public var enabled: Bool
    }

    public struct GroupRecord: Codable {
        public var id: String
        public var name: String
        public var order: Int
        public var isFolder: Bool
        public var page: Int
    }

    public struct AppRecord: Codable {
        public var id: String
        public var groupId: String
        public var bundleId: String
        public var bundleName: String
        public var version: String
        public var build: String
        public var name: String
        public var order: Int
        public var url: String
        public var alias: String?
        public var category: String
        public var hidden: Bool
    }

    public struct Payload: Codable {
        public var setting: Setting
        public var apps: [AppRecord]
        public var groups: [GroupRecord]
        public var sources: [SourceRecord]
    }

    public var metadata: Metadata
    public var data: Payload
}
