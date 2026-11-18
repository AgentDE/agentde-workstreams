import Foundation

/// How the panel's Files and Artifacts lists sort (the menu beside their filter).
enum ListSort: String, CaseIterable {
    case mix, created, recent, lastOpened, opened, used, biggest, name

    /// "Recently edited" is the agents' last read or edit of a file. An artifact's appearing is its creation, so
    /// artifacts sort by `created` instead (a saved `recent` reads as that).
    /// "Most used" for files (the agents' reads and edits), "Most mentioned" for artifacts (how often linked).
    /// Mix: most opened by you, then most used or mentioned, then most recent.
    func label(files: Bool) -> String {
        switch self {
        case .mix: "Mix"
        case .created: "Recently created"
        case .recent: files ? "Recently edited" : "Recently created"
        case .lastOpened: "Recently opened"
        case .opened: "Most opened"
        case .used: files ? "Most used" : "Most mentioned"
        case .biggest: "Biggest"
        case .name: "Name"
        }
    }

    /// The choices in the menu: artifacts have no edits of their own.
    static func options(files: Bool) -> [ListSort] { files ? allCases : allCases.filter { $0 != .recent } }

    /// A saved choice, as this list reads it.
    static func saved(_ raw: String, files: Bool) -> ListSort {
        let sort = ListSort(rawValue: raw) ?? (files ? .recent : .created)
        return !files && sort == .recent ? .created : sort
    }
}

/// One row to order: a file path or an artifact link.
struct ListItem: Equatable {
    var key: String
    var name: String
    var date: Date?
    var count: Int
    var size: Int64?
    /// How often you opened it in a viewer.
    var opened = 0
    /// When it was created: a file's creation on disk, an artifact's first appearance.
    var created: Date?
    /// When you last opened it in a viewer.
    var lastOpened: Date?
    /// Hidden from the list until a filter matches it.
    var hidden = false
}

enum ListOrder {
    /// `items` matching every word of `filter` (in the name or the path or link, so `.pptx` filters by type),
    /// in `sort` order; ties go newest first, then by name. Hidden items show only when a filter matches them.
    static func arrange(_ items: [ListItem], sort: ListSort, filter: String) -> [ListItem] {
        let words = filter.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = words.isEmpty ? items.filter { !$0.hidden } : items.filter { item in
            let haystack = (item.name + " " + item.key).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        /// Newest `key` first; items without one go last, newest `date` first.
        func later(_ key: (ListItem) -> Date?, _ a: ListItem, _ b: ListItem) -> Bool {
            let (x, y) = (key(a) ?? .distantPast, key(b) ?? .distantPast)
            return x != y ? x > y : newer(a, b)
        }
        func newer(_ a: ListItem, _ b: ListItem) -> Bool {
            let (x, y) = (a.date ?? .distantPast, b.date ?? .distantPast)
            return x != y ? x > y : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return kept.sorted { a, b in
            switch sort {
            case .recent: return newer(a, b)
            case .created: return later(\.created, a, b)
            case .lastOpened: return later(\.lastOpened, a, b)
            case .opened: return a.opened != b.opened ? a.opened > b.opened : newer(a, b)
            case .mix:
                if a.opened != b.opened { return a.opened > b.opened }
                return a.count != b.count ? a.count > b.count : newer(a, b)
            case .used: return a.count != b.count ? a.count > b.count : newer(a, b)
            case .biggest: return (a.size ?? -1) != (b.size ?? -1) ? (a.size ?? -1) > (b.size ?? -1) : newer(a, b)
            case .name:
                let order = a.name.localizedStandardCompare(b.name)
                return order != .orderedSame ? order == .orderedAscending : newer(a, b)
            }
        }
    }

    /// A local file's creation date; nil for links and missing files.
    static func created(_ path: String) -> Date? {
        guard path.hasPrefix("/") else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate]) as? Date
    }

    /// A local file's size; nil for links and missing files.
    static func size(of path: String) -> Int64? {
        guard path.hasPrefix("/") else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }
}
