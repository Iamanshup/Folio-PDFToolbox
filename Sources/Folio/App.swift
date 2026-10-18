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
        .commands { SidebarCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Folio"))
    }
}

struct ContentView: View {
    // FOLIO_TOOL / FOLIO_OPEN preload a tool and file (used for UI smoke tests).
    @Local private var selection: Tool? = ProcessInfo.processInfo.environment["FOLIO_TOOL"].flatMap(Tool.init(rawValue:))
    @Local private var search = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Button { selection = nil } label: { Label("All Tools", systemImage: "square.grid.3x3.fill") }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                ForEach(ToolCategory.allCases) { cat in
                    Section(cat.rawValue) {
                        ForEach(Tool.allCases.filter { $0.category == cat }) { tool in
                            Label { Text(tool.title) } icon: { Image(systemName: tool.symbol).foregroundStyle(tool.color) }
                                .tag(tool)
                        }
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
    }
}

struct HomeView: View {
    @Binding var search: String
    let open: (Tool) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every tool you need to work with PDFs").font(.system(size: 30, weight: .bold))
                    Text("All tools run locally on your Mac — your files never leave this computer.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                TextField("Search tools", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                ForEach(ToolCategory.allCases) { cat in
                    let tools = Tool.allCases.filter { $0.category == cat && matches($0) }
                    if !tools.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(cat.rawValue).font(.headline).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                                ForEach(tools) { ToolCard(tool: $0) { open($0) } }
                            }
                        }
                    }
                }
            }
            .padding(30)
        }
    }

    func matches(_ t: Tool) -> Bool {
        search.isEmpty || t.title.localizedCaseInsensitiveContains(search) || t.subtitle.localizedCaseInsensitiveContains(search)
    }
}

struct ToolCard: View {
    let tool: Tool
    let action: (Tool) -> Void
    @Local private var hover = false

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
        .onHover { hover = $0 }
    }
}
