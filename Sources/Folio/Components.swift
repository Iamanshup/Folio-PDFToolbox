import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Job plumbing

struct ToolResult {
    var files: [URL]
    var message: String? = nil
}

enum Workspace {
    static func newOutputDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Folio", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        var url = dir.appendingPathComponent(safe).appendingPathExtension(ext)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(safe)-\(i)").appendingPathExtension(ext)
            i += 1
        }
        return url
    }
}

extension URL {
    var baseName: String { deletingPathExtension().lastPathComponent }
}

extension UTType {
    static func ext(_ e: String) -> UTType { UTType(filenameExtension: e) ?? .data }
    static let wordTypes: [UTType] = ["doc", "docx", "rtf", "odt", "txt", "rtfd", "html"].map(ext)
    static let pptTypes: [UTType] = ["ppt", "pptx", "key", "odp"].map(ext)
    static let excelTypes: [UTType] = ["xls", "xlsx", "csv", "numbers", "ods"].map(ext)
    static let imageTypes: [UTType] = [.jpeg, .png, .heic, .tiff, .gif, .bmp, .webP, .image]
}

final class JobProgress: @unchecked Sendable {
    private weak var runner: Runner?
    init(_ runner: Runner) { self.runner = runner }
    func update(_ status: String, _ fraction: Double? = nil) {
        Task { @MainActor [weak runner] in
            runner?.status = status
            runner?.progress = fraction
        }
    }
}

typealias Job = (_ outDir: URL, _ progress: JobProgress) async throws -> ToolResult

@MainActor
final class Runner: ObservableObject {
    @Published var isRunning = false
    @Published var status = ""
    @Published var progress: Double?
    @Published var result: ToolResult?
    @Published var error: String?

    func run(_ job: @escaping Job) {
        isRunning = true
        error = nil
        result = nil
        status = "Working…"
        progress = nil
        let reporter = JobProgress(self)
        Task {
            do {
                let dir = try Workspace.newOutputDir()
                let r = try await Task.detached(priority: .userInitiated) { try await job(dir, reporter) }.value
                self.result = r
            } catch {
                self.error = error.localizedDescription
            }
            self.isRunning = false
        }
    }

    func reset() { result = nil; error = nil }
}

// MARK: - Layout

struct ToolHeader: View {
    let tool: Tool
    var body: some View {
        HStack(spacing: 14) {
            ToolIcon(tool: tool, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.largeTitle.weight(.bold))
                Text(tool.subtitle).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ToolIcon: View {
    let tool: Tool
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: tool.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26).fill(tool.color.gradient))
    }
}

struct ToolPage<Content: View>: View {
    let tool: Tool
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ToolHeader(tool: tool)
                content
            }
            .padding(28)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
    }
}

struct OptionsBox<Content: View>: View {
    var title = "Options"
    @ViewBuilder var content: Content
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } label: { Text(title).font(.headline) }
    }
}

// MARK: - File input

struct DropZone: View {
    let types: [UTType]
    var multiple = true
    var prompt = "Select PDF files"
    let onFiles: ([URL]) -> Void
    @Local private var targeted = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc.fill").font(.system(size: 42)).foregroundStyle(.tint)
            Text(prompt).font(.title3.weight(.semibold))
            Text(multiple ? "or drop files here" : "or drop a file here").foregroundStyle(.secondary)
            Button { pick() } label: {
                Label(multiple ? "Choose Files…" : "Choose File…", systemImage: "folder").padding(.horizontal, 16)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(RoundedRectangle(cornerRadius: 16).fill(targeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35)))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            FilePicker.load(providers, types: types) { urls in onFiles(multiple ? urls : Array(urls.prefix(1))) }
            return true
        }
    }

    func pick() { if let urls = FilePicker.open(types: types, multiple: multiple) { onFiles(urls) } }
}

enum FilePicker {
    @MainActor static func open(types: [UTType], multiple: Bool) -> [URL]? {
        let p = NSOpenPanel()
        p.allowedContentTypes = types
        p.allowsMultipleSelection = multiple
        p.canChooseDirectories = false
        return p.runModal() == .OK && !p.urls.isEmpty ? p.urls : nil
    }

    static func load(_ providers: [NSItemProvider], types: [UTType], completion: @escaping ([URL]) -> Void) {
        var found = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        let lock = NSLock()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                lock.lock(); found[i] = url; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ok = found.compactMap { $0 }.filter { url in
                let t = UTType(filenameExtension: url.pathExtension) ?? .data
                return types.contains { t.conforms(to: $0) }
            }
            if !ok.isEmpty { completion(ok) }
        }
    }
}

struct FileRow: View {
    let url: URL
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    var detail: String {
        var s = PDFCore.byteString(PDFCore.fileSize(url))
        if url.pathExtension.lowercased() == "pdf", let d = PDFDocument(url: url) {
            s += d.isLocked ? " · locked" : " · \(d.pageCount) page\(d.pageCount == 1 ? "" : "s")"
        }
        return s
    }
}

struct FileListView: View {
    @Binding var files: [URL]
    var types: [UTType]
    var multiple = true
    var reorderable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(files, id: \.self) { url in
                    HStack {
                        if reorderable { Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary) }
                        FileRow(url: url)
                        Spacer()
                        Button { files.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in if reorderable { files.move(fromOffsets: from, toOffset: to) } }
            }
            .frame(height: min(CGFloat(max(files.count, 1)) * 46 + 12, 280))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                if multiple {
                    Button { if let more = FilePicker.open(types: types, multiple: true) { files += more.filter { !files.contains($0) } } }
                    label: { Label("Add Files", systemImage: "plus") }
                }
                if reorderable && files.count > 1 {
                    Button { files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } }
                    label: { Label("Sort by Name", systemImage: "arrow.up.arrow.down") }
                    Text("Drag to reorder").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear", role: .destructive) { files = [] }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                FilePicker.load(providers, types: types) { urls in files = multiple ? files + urls.filter { !files.contains($0) } : [urls[0]] }
                return true
            }
        }
    }
}

// MARK: - Results

struct ResultPanel: View {
    @ObservedObject var runner: Runner
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if runner.isRunning {
                HStack(spacing: 12) {
                    if let p = runner.progress { ProgressView(value: p).frame(width: 200) } else { ProgressView().controlSize(.small) }
                    Text(runner.status).foregroundStyle(.secondary)
                }
            }
            if let e = runner.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            if let r = runner.result, !r.files.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Done!", systemImage: "checkmark.circle.fill").font(.title3.weight(.semibold)).foregroundStyle(.green)
                        if let m = r.message { Text(m).foregroundStyle(.secondary).textSelection(.enabled) }
                        ForEach(r.files, id: \.self) { url in
                            HStack {
                                FileRow(url: url)
                                Spacer()
                                Button("Open") { NSWorkspace.shared.open(url) }
                                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                                    .help("Show in Finder")
                            }
                        }
                        Divider()
                        HStack {
                            Button { ResultSaver.save(r.files) } label: { Label(r.files.count == 1 ? "Save…" : "Save All…", systemImage: "square.and.arrow.down") }
                                .buttonStyle(.borderedProminent)
                            Button { NSWorkspace.shared.activateFileViewerSelecting(r.files) } label: { Label("Show in Finder", systemImage: "folder") }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let r = runner.result, let m = r.message {
                Label(m, systemImage: "info.circle").foregroundStyle(.secondary)
            }
        }
    }
}

enum ResultSaver {
    @MainActor static func save(_ files: [URL]) {
        if files.count == 1, let f = files.first {
            let p = NSSavePanel()
            p.nameFieldStringValue = f.lastPathComponent
            if let t = UTType(filenameExtension: f.pathExtension) { p.allowedContentTypes = [t] }
            guard p.runModal() == .OK, let dest = p.url else { return }
            copy(f, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } else {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.canCreateDirectories = true
            p.prompt = "Save Here"
            guard p.runModal() == .OK, let dir = p.url else { return }
            var saved: [URL] = []
            for f in files {
                let dest = Workspace.uniqueURL(in: dir, name: f.baseName, ext: f.pathExtension)
                copy(f, to: dest)
                saved.append(dest)
            }
            NSWorkspace.shared.activateFileViewerSelecting(saved)
        }
    }

    private static func copy(_ src: URL, to dest: URL) {
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: src, to: dest) }
        catch { NSAlert(error: error).runModal() }
    }
}

// MARK: - Generic file tool

/// Drop files → options → run → results. `makeJob` is called on the main actor so it can snapshot
/// option state; the returned job runs in the background.
struct FileToolView<Options: View>: View {
    let tool: Tool
    var types: [UTType] = [.pdf]
    var multiple = true
    var reorderable = false
    var prompt: String? = nil
    var actionTitle: String
    var minFiles = 1
    @ViewBuilder var options: (_ files: [URL]) -> Options
    let makeJob: (_ files: [URL]) -> Job

    @Local private var files: [URL] = []
    @StateObject private var runner = Runner()

    var body: some View {
        ToolPage(tool: tool) {
            if files.isEmpty {
                DropZone(types: types, multiple: multiple, prompt: prompt ?? (multiple ? "Select files" : "Select a file")) { files = $0 }
            } else {
                FileListView(files: $files, types: types, multiple: multiple, reorderable: reorderable)
                let opts = options(files)
                if !(opts is EmptyView) { OptionsBox { opts } }
                HStack {
                    Spacer()
                    Button { runner.run(makeJob(files)) } label: {
                        Label(actionTitle, systemImage: "arrow.right.circle.fill").padding(.horizontal, 20).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(runner.isRunning || files.count < minFiles)
                    Spacer()
                }
                if files.count < minFiles { Text("Add at least \(minFiles) files.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                ResultPanel(runner: runner)
            }
        }
        .onChange(of: files) { runner.reset() }
    }
}

extension FileToolView where Options == EmptyView {
    init(tool: Tool, types: [UTType] = [.pdf], multiple: Bool = true, reorderable: Bool = false, prompt: String? = nil,
         actionTitle: String, minFiles: Int = 1, makeJob: @escaping ([URL]) -> Job) {
        self.init(tool: tool, types: types, multiple: multiple, reorderable: reorderable, prompt: prompt,
                  actionTitle: actionTitle, minFiles: minFiles, options: { _ in EmptyView() }, makeJob: makeJob)
    }
}

// MARK: - Misc controls

struct PositionGrid: View {
    @Binding var position: PDFOps.Position
    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3) { r in
                GridRow {
                    ForEach(0..<3) { c in
                        let p = PDFOps.Position.allCases[r * 3 + c]
                        Button { position = p } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(position == p ? Color.accentColor : Color.secondary.opacity(0.2))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain).help(p.rawValue)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
    }
}

struct FontPicker: View {
    @Binding var fontName: String
    static let fonts = ["Helvetica", "Helvetica-Bold", "Times-Roman", "Times-Bold", "Courier", "Courier-Bold",
                        "Georgia", "Arial", "Arial-BoldMT", "Avenir-Book", "Avenir-Heavy", "Menlo-Regular",
                        "Futura-Medium", "GillSans", "Baskerville", "Didot", "AmericanTypewriter",
                        "BradleyHandITCTT-Bold", "SnellRoundhand", "Noteworthy-Light", "MarkerFelt-Thin"]
    var body: some View {
        Picker("Font", selection: $fontName) {
            ForEach(Self.fonts, id: \.self) { f in Text(NSFont(name: f, size: 12)?.displayName ?? f).tag(f) }
        }
        .frame(maxWidth: 260)
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    var displayMode: PDFDisplayMode = .singlePageContinuous
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = displayMode
        v.document = document
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if v.document !== document { v.document = document }
    }
}

extension NSColor {
    var swiftUI: Color { Color(nsColor: self) }
}

extension Binding where Value == NSColor {
    var color: Binding<Color> {
        Binding<Color>(get: { Color(nsColor: wrappedValue) }, set: { wrappedValue = NSColor($0) })
    }
}
