import SwiftUI

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Folio") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("Open…") { FileInbox.shared.showOpenPanel() }.keyboardShortcut("o")
            }
        }
        Settings { SettingsView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // FOLIO_OPEN preloads a file before the window exists (used for UI smoke tests).
        if let path = ProcessInfo.processInfo.environment["FOLIO_OPEN"] { FileInbox.shared.receive([URL(fileURLWithPath: path)]) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let dir = CommandLine.arguments.count > i + 1 ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : FileManager.default.temporaryDirectory
            Task { @MainActor in exit(await SelfTest.run(in: dir) ? 0 : 1) }
            return
        }
        NSApp.setActivationPolicy(.regular)
        // The automatic title bar separator is drawn at the wrong height in the sidebar (through the
        // window buttons) once the sidebar list scrolls, so turn it off for every window.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow)?.titlebarSeparatorStyle = .none
        }
        UITestHook.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Files dropped on the Dock icon or opened with "Open With › Folio".
    func application(_ application: NSApplication, open urls: [URL]) {
        FileInbox.shared.receive(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Folio"))
    }
}

struct ContentView: View {
    // FOLIO_TOOL preselects a tool (used for UI smoke tests).
    @Local private var selection: Tool? = ProcessInfo.processInfo.environment["FOLIO_TOOL"].flatMap(Tool.init(rawValue:))
    @Local private var search = ""
    @ObservedObject private var prefs = ToolPrefs.shared
    @ObservedObject private var inbox = FileInbox.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Button { selection = nil } label: { Label("All Tools", systemImage: "square.grid.3x3.fill") }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                if !prefs.favorites.isEmpty {
                    Section("Favorites") { ForEach(prefs.favorites) { row($0) } }
                }
                // No "Recent" section here: it reorders on every click, which moved rows under the
                // pointer so the next click hit the wrong tool. Recent tools live on the home screen.
                ForEach(ToolCategory.allCases) { cat in
                    // A plain section with a clickable header: the system's collapsible sections only
                    // expand via a hover-only arrow, so clicking the category name did nothing.
                    let open = prefs.expanded.contains(cat.rawValue)
                    Section {
                        if open { ForEach(Tool.allCases.filter { $0.category == cat }) { row($0) } }
                    } header: {
                        Button { withAnimation(.easeInOut(duration: 0.15)) { prefs.toggleExpanded(cat) } } label: {
                            HStack {
                                Text(cat.rawValue)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(open ? 90 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(cat.rawValue), \(open ? "expanded" : "collapsed")")
                        .accessibilityHint(open ? "Collapses this category" : "Shows the tools in this category")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            if let tool = selection {
                tool.view.id(tool)
            } else {
                HomeView(search: $search) { selection = $0 }
            }
        }
        .onChange(of: selection) {
            if let t = selection {
                prefs.used(t)
                prefs.expanded.insert(t.category.rawValue) // keep the selected tool visible in the sidebar
            }
        }
        .onChange(of: inbox.files) {
            // Opened files show the "choose a tool" banner on the home screen.
            if !inbox.files.isEmpty { selection = nil }
        }
    }

    private func row(_ tool: Tool) -> some View {
        Label { Text(tool.title) } icon: { Image(systemName: tool.symbol).foregroundStyle(tool.color) }
            .tag(tool)
            .contextMenu { FavoriteButton(tool: tool) }
    }
}

struct FavoriteButton: View {
    let tool: Tool
    @ObservedObject private var prefs = ToolPrefs.shared
    var body: some View {
        Button(prefs.isFavorite(tool) ? "Remove from Favorites" : "Add to Favorites") { prefs.toggleFavorite(tool) }
    }
}

struct HomeView: View {
    @Binding var search: String
    let open: (Tool) -> Void
    @ObservedObject private var prefs = ToolPrefs.shared
    @ObservedObject private var inbox = FileInbox.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if !inbox.files.isEmpty { InboxBanner(files: inbox.files, open: open) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every tool you need to work with PDFs").font(.system(size: 30, weight: .bold))
                    Text("All tools run locally on your Mac — your files never leave this computer.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                TextField("Search tools", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                if search.isEmpty {
                    if !prefs.favorites.isEmpty { section("Favorites", prefs.favorites) }
                    let recent = prefs.recents.filter { !prefs.isFavorite($0) }.prefix(3)
                    if !recent.isEmpty { section("Recently Used", Array(recent)) }
                }
                ForEach(ToolCategory.allCases) { cat in
                    let tools = Tool.allCases.filter { $0.category == cat && matches($0) }
                    if !tools.isEmpty { section(cat.rawValue, tools) }
                }
            }
            .padding(30)
        }
    }

    private func section(_ title: String, _ tools: [Tool]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                ForEach(tools) { ToolCard(tool: $0) { open($0) } }
            }
        }
    }

    func matches(_ t: Tool) -> Bool {
        search.isEmpty || t.title.localizedCaseInsensitiveContains(search) || t.subtitle.localizedCaseInsensitiveContains(search)
    }
}

/// Shown after files are opened from Finder or the Dock: suggests the tools that accept them.
struct InboxBanner: View {
    let files: [URL]
    let open: (Tool) -> Void

    var body: some View {
        let tools = Tool.allCases.filter { $0.accepts(files) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PageThumb(url: files[0], maxSize: 120).frame(width: 34, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files opened").font(.headline)
                    Text(tools.isEmpty ? "None of the tools accept these files together." : "Choose what to do with \(files.count == 1 ? "it" : "them"):")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Dismiss") { FileInbox.shared.clear() }
            }
            if !tools.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(tools) { t in
                        Button { open(t) } label: {
                            HStack(spacing: 8) {
                                ToolIcon(tool: t, size: 24)
                                Text(t.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.4)))
    }
}

struct ToolCard: View {
    let tool: Tool
    let action: (Tool) -> Void
    @Local private var hover = false
    @ObservedObject private var prefs = ToolPrefs.shared

    var body: some View {
        Button { action(tool) } label: {
            VStack(alignment: .leading, spacing: 10) {
                ToolIcon(tool: tool, size: 40)
                Text(tool.title).font(.headline).foregroundStyle(.primary)
                Text(tool.subtitle).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true).multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover ? tool.color.opacity(0.7) : Color.secondary.opacity(0.15), lineWidth: hover ? 2 : 1))
            .shadow(color: .black.opacity(hover ? 0.12 : 0.04), radius: hover ? 8 : 3, y: 2)
            .scaleEffect(hover ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hover || prefs.isFavorite(tool) {
                Button { prefs.toggleFavorite(tool) } label: {
                    Image(systemName: prefs.isFavorite(tool) ? "star.fill" : "star")
                        .foregroundStyle(prefs.isFavorite(tool) ? Color.yellow : Color.secondary)
                        .padding(10)
                }
                .buttonStyle(.plain)
                .help(prefs.isFavorite(tool) ? "Remove from Favorites" : "Add to Favorites")
                .accessibilityLabel(prefs.isFavorite(tool) ? "Remove \(tool.title) from Favorites" : "Add \(tool.title) to Favorites")
            }
        }
        .contextMenu { FavoriteButton(tool: tool) }
        .onHover { hover = $0 }
    }
}
