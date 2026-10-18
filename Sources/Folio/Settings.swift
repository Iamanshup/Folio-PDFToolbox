import AppKit
import SwiftUI

enum SaveLocation: String, CaseIterable, Identifiable {
    case nextToOriginal, downloads, folder, ask
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nextToOriginal: return "Next to the original file"
        case .downloads: return "Downloads folder"
        case .folder: return "A folder I choose"
        case .ask: return "Ask each time"
        }
    }
}

enum Prefs {
    static let saveLocationKey = "saveLocation"
    static let saveFolderKey = "saveFolder"
    static let revealKey = "revealAfterSaving"

    static var saveLocation: SaveLocation {
        UserDefaults.standard.string(forKey: saveLocationKey).flatMap(SaveLocation.init) ?? .nextToOriginal
    }
    static var saveFolder: URL? {
        UserDefaults.standard.string(forKey: saveFolderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static var revealAfterSaving: Bool { UserDefaults.standard.bool(forKey: revealKey) }
    static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
}

struct SettingsView: View {
    @AppStorage(Prefs.saveLocationKey) private var location = SaveLocation.nextToOriginal.rawValue
    @AppStorage(Prefs.saveFolderKey) private var folder = ""
    @AppStorage(Prefs.revealKey) private var reveal = false

    var body: some View {
        Form {
            Picker("Save results to", selection: $location) {
                ForEach(SaveLocation.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.radioGroup)
            if location == SaveLocation.folder.rawValue {
                HStack {
                    Text(folder.isEmpty ? "No folder chosen" : (folder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(folder.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Text("Tools that create several files put them in their own folder. If a location can’t be written to, results go to Downloads.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Show results in Finder after saving", isOn: $reveal)
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose"
        if p.runModal() == .OK, let u = p.url { folder = u.path }
    }
}

extension ResultSaver {
    /// Moves finished outputs out of the temporary job folder to the location chosen in Settings.
    /// Returns nil when the user prefers to pick a location each time (files stay in the temp folder).
    @MainActor static func deliver(_ files: [URL], source: URL?, label: String) -> (files: [URL], folder: URL)? {
        guard !files.isEmpty else { return nil }
        let base: URL
        switch Prefs.saveLocation {
        case .ask: return nil
        case .nextToOriginal: base = source?.deletingLastPathComponent() ?? Prefs.downloads
        case .downloads: base = Prefs.downloads
        case .folder: base = Prefs.saveFolder ?? Prefs.downloads
        }
        for dir in [base, Prefs.downloads] {
            var target = dir
            if files.count > 3 {
                // Many outputs (split pages, images…) get their own folder so originals aren't buried.
                let name = [source?.baseName, label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – ")
                target = Workspace.uniqueURL(in: dir, name: name.isEmpty ? "Folio results" : name, ext: "")
                guard (try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)) != nil else { continue }
            }
            var moved: [URL] = []
            for f in files {
                let dest = Workspace.uniqueURL(in: target, name: f.baseName, ext: f.pathExtension)
                guard (try? FileManager.default.moveItem(at: f, to: dest)) != nil else { break }
                moved.append(dest)
            }
            if moved.count == files.count {
                if Prefs.revealAfterSaving { NSWorkspace.shared.activateFileViewerSelecting(files.count > 3 ? [target] : moved) }
                return (moved, target)
            }
            // Partial failure (e.g. read-only volume): put anything already moved back and try Downloads.
            for (m, f) in zip(moved, files) { try? FileManager.default.moveItem(at: m, to: f) }
            if files.count > 3 { try? FileManager.default.removeItem(at: target) }
        }
        return nil
    }
}
