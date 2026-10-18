import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files opened from Finder, the Dock or File › Open…, waiting for the user to pick a tool.
@MainActor
final class FileInbox: ObservableObject {
    static let shared = FileInbox()
    @Published private(set) var files: [URL] = []

    func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        files = urls
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hands the waiting files that match `types` to a tool and empties the inbox.
    func take(_ types: [UTType]) -> [URL] {
        let ok = files.filter { Tool.conforms($0, to: types) }
        if !ok.isEmpty { files = [] }
        return ok
    }

    func clear() { files = [] }

    static let openableTypes: [UTType] = [.pdf, .html] + UTType.imageTypes + UTType.wordTypes + UTType.pptTypes + UTType.excelTypes

    func showOpenPanel() {
        if let urls = FilePicker.open(types: Self.openableTypes, multiple: true) { receive(urls) }
    }
}

/// Favorite and recently used tools, persisted in user defaults.
@MainActor
final class ToolPrefs: ObservableObject {
    static let shared = ToolPrefs()
    @Published var favorites: [Tool] { didSet { save(favorites, "favoriteTools") } }
    @Published var recents: [Tool] { didSet { save(recents, "recentTools") } }
    @Published var expanded: Set<String> { didSet { UserDefaults.standard.set(Array(expanded), forKey: "expandedCategories") } }

    init() {
        func load(_ key: String) -> [Tool] { (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(Tool.init(rawValue:)) }
        favorites = load("favoriteTools")
        recents = load("recentTools")
        expanded = Set(UserDefaults.standard.stringArray(forKey: "expandedCategories") ?? [])
    }

    private func save(_ tools: [Tool], _ key: String) { UserDefaults.standard.set(tools.map(\.rawValue), forKey: key) }

    func isFavorite(_ t: Tool) -> Bool { favorites.contains(t) }
    func toggleFavorite(_ t: Tool) { if isFavorite(t) { favorites.removeAll { $0 == t } } else { favorites.append(t) } }
    func used(_ t: Tool) { recents = Array(([t] + recents.filter { $0 != t }).prefix(6)) }

    func isExpanded(_ c: ToolCategory) -> Binding<Bool> {
        Binding(get: { self.expanded.contains(c.rawValue) },
                set: { if $0 { self.expanded.insert(c.rawValue) } else { self.expanded.remove(c.rawValue) } })
    }
}
