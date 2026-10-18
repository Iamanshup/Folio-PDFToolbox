import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Edit PDF

struct EditTool: View {
    var body: some View {
        EditorHost(tool: .edit, actionTitle: "Save PDF", editor: { model in
            CanvasEditor(model: model, tools: [.select, .text, .image, .rect, .ellipse, .line, .ink, .highlight, .whiteout], toolbarExtra: {
                Button { pickImage(model) } label: { Label("Insert Image…", systemImage: "photo.badge.plus") }
            }, sidebarExtra: { EmptyView() })
        }, makeJob: { model in
            let (items, doc, url) = (model.items, model.doc, model.url)
            return { dir, p in
                let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_edited", ext: "pdf")
                try PDFCore.render(doc, to: dest, over: { i, _, _, size in ItemRenderer.draw(items.filter { $0.page == i }, size: size) }, progress: p)
                return ToolResult(files: [dest])
            }
        })
    }

    @MainActor func pickImage(_ model: CanvasModel) {
        guard let u = FilePicker.open(types: UTType.imageTypes, multiple: false)?.first, let img = NSImage(contentsOf: u) else { return }
        model.pendingImage = img
        model.tool = .image
    }
}

// MARK: - Sign PDF

@MainActor
final class SignatureStore: ObservableObject {
    static let shared = SignatureStore()
    @Published var signatures: [NSImage] = []
    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio/Signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        signatures = files.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap(NSImage.init(contentsOf:))
    }

    func add(_ img: NSImage) {
        signatures.append(img)
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).png"))
        }
    }

    func remove(at i: Int) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if i < files.count { try? FileManager.default.removeItem(at: files[i]) }
        signatures.remove(at: i)
    }
}

struct SignTool: View {
    @ObservedObject private var store = SignatureStore.shared
    @Local private var showPad = false

    var body: some View {
        EditorHost(tool: .sign, actionTitle: "Sign & Save", editor: { model in
            CanvasEditor(model: model, tools: [.select, .image, .text, .ink], toolbarExtra: { EmptyView() }, sidebarExtra: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Signatures").font(.headline)
                    ForEach(Array(store.signatures.enumerated()), id: \.offset) { i, sig in
                        HStack {
                            Button { model.pendingImage = sig; model.tool = .image } label: {
                                Image(nsImage: sig).resizable().scaledToFit().frame(height: 44).frame(maxWidth: .infinity)
                                    .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.pendingImage === sig && model.tool == .image ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            Button { store.remove(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                    Button { showPad = true } label: { Label("Create Signature or Initials…", systemImage: "signature") }
                    if model.tool == .image && model.pendingImage != nil {
                        Text("Click on the page to place it. Drag the corner to resize.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Button { addText(model, DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)) } label: { Label("Add Date", systemImage: "calendar") }
                    Button { addText(model, NSFullUserName()) } label: { Label("Add Name", systemImage: "person") }
                    Divider()
                }
                .sheet(isPresented: $showPad) {
                    SignaturePad { img in
                        store.add(img)
                        model.pendingImage = img
                        model.tool = .image
                    }
                }
            })
        }, makeJob: { model in
            let (items, doc, url) = (model.items, model.doc, model.url)
            return { dir, p in
                guard !items.isEmpty else { throw ToolError.message("Place a signature on the document first.") }
                let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_signed", ext: "pdf")
                try PDFCore.render(doc, to: dest, over: { i, _, _, size in ItemRenderer.draw(items.filter { $0.page == i }, size: size) }, progress: p)
                return ToolResult(files: [dest], message: "Signed \(Set(items.map(\.page)).count) page(s).")
            }
        })
    }

    @MainActor func addText(_ model: CanvasModel, _ text: String) {
        let size = model.pageSize(model.page)
        var item = CanvasItem(page: model.page, kind: .text, rect: CGRect(x: size.width / 2 - 60, y: size.height - 120, width: 120, height: 20),
                              text: text, fontName: model.fontName, fontSize: 14, color: model.color)
        model.fitText(&item)
        model.add(item)
        model.tool = .select
    }
}

struct SignaturePad: View {
    let onDone: (NSImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @Local private var mode = 0
    @Local private var strokes: [[CGPoint]] = []
    @Local private var current: [CGPoint] = []
    @Local private var name = NSFullUserName()
    @Local private var font = "SnellRoundhand-Bold"
    @Local private var color: Color = Color(red: 0.05, green: 0.1, blue: 0.45)
    @Local private var uploaded: NSImage?
    @Local private var removeBackground = true

    static let scriptFonts = ["SnellRoundhand-Bold", "Zapfino", "BradleyHandITCTT-Bold", "Noteworthy-Bold", "Baskerville-SemiBoldItalic", "SavoyeLetPlain", "Apple-Chancery"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create signature").font(.title2.bold())
            Picker("", selection: $mode) { Text("Draw").tag(0); Text("Type").tag(1); Text("Upload").tag(2) }.pickerStyle(.segmented).labelsHidden()
            Group {
                switch mode {
                case 0:
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color.white)
                        Path { p in for s in strokes + [current] { addStroke(s, to: &p) } }
                            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        if strokes.isEmpty && current.isEmpty { Text("Sign here").foregroundStyle(.gray) }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { current.append($0.location) }
                        .onEnded { _ in strokes.append(current); current = [] })
                case 1:
                    VStack(alignment: .leading) {
                        TextField("Your name", text: $name).textFieldStyle(.roundedBorder)
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(Self.scriptFonts, id: \.self) { f in
                                    if NSFont(name: f, size: 30) != nil {
                                        Button { font = f } label: {
                                            Text(name.isEmpty ? "Signature" : name).font(.custom(f, size: 30)).foregroundStyle(color)
                                                .frame(maxWidth: .infinity, minHeight: 56)
                                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(font == f ? Color.accentColor : .clear, lineWidth: 2))
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                default:
                    VStack {
                        if let uploaded { Image(nsImage: uploaded).resizable().scaledToFit().frame(maxHeight: 160) }
                        Button("Choose Image…") { if let u = FilePicker.open(types: UTType.imageTypes, multiple: false)?.first { uploaded = NSImage(contentsOf: u) } }
                        Toggle("Remove white background", isOn: $removeBackground)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 220)
            HStack {
                if mode != 2 {
                    ForEach([Color.black, Color(red: 0.05, green: 0.1, blue: 0.45), Color(red: 0.7, green: 0.05, blue: 0.1)], id: \.self) { c in
                        Button { color = c } label: { Circle().fill(c).frame(width: 22, height: 22).overlay(Circle().strokeBorder(color == c ? Color.accentColor : .clear, lineWidth: 3)) }
                            .buttonStyle(.plain)
                    }
                }
                if mode == 0 { Button("Clear") { strokes = []; current = [] } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Signature") { if let img = makeImage() { onDone(img); dismiss() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func addStroke(_ s: [CGPoint], to p: inout Path) {
        guard let f = s.first else { return }
        p.move(to: f)
        for q in s.dropFirst() { p.addLine(to: q) }
    }

    private func makeImage() -> NSImage? {
        let ns = NSColor(color)
        switch mode {
        case 0:
            let pts = strokes.flatMap { $0 }
            guard pts.count > 1 else { return nil }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let bounds = CGRect(x: xs.min()! - 4, y: ys.min()! - 4, width: xs.max()! - xs.min()! + 8, height: ys.max()! - ys.min()! + 8)
            let k: CGFloat = 3
            return NSImage(size: CGSize(width: bounds.width * k, height: bounds.height * k), flipped: true) { _ in
                let path = NSBezierPath()
                for s in strokes {
                    guard let f = s.first else { continue }
                    path.move(to: CGPoint(x: (f.x - bounds.minX) * k, y: (f.y - bounds.minY) * k))
                    for q in s.dropFirst() { path.line(to: CGPoint(x: (q.x - bounds.minX) * k, y: (q.y - bounds.minY) * k)) }
                }
                path.lineWidth = 3 * k
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                ns.setStroke()
                path.stroke()
                return true
            }.rasterized()
        case 1:
            guard !name.isEmpty else { return nil }
            let s = NSAttributedString(string: name, attributes: [.font: NSFont(name: font, size: 120) ?? .systemFont(ofSize: 120), .foregroundColor: ns])
            let size = s.size()
            return NSImage(size: CGSize(width: ceil(size.width) + 20, height: ceil(size.height) + 10), flipped: false) { _ in
                s.draw(at: CGPoint(x: 10, y: 5)); return true
            }.rasterized()
        default:
            guard let u = uploaded else { return nil }
            return removeBackground ? u.removingWhiteBackground() ?? u : u
        }
    }
}

extension NSImage {
    /// Bakes a drawing-handler image into a bitmap so it can be saved and drawn off the main thread.
    func rasterized() -> NSImage {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let img = NSImage(cgImage: cg, size: size)
        return img
    }

    func removingWhiteBackground() -> NSImage? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<(w * h) {
            let p = buf + i * 4
            let lum = (Int(p[0]) * 299 + Int(p[1]) * 587 + Int(p[2]) * 114) / 1000
            let alpha = max(0, min(255, (255 - lum) * 3))
            // Re-premultiply with the new alpha.
            p[0] = UInt8(Int(p[0]) * alpha / 255); p[1] = UInt8(Int(p[1]) * alpha / 255); p[2] = UInt8(Int(p[2]) * alpha / 255); p[3] = UInt8(alpha)
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: size)
    }
}

// MARK: - Redact PDF

struct RedactTool: View {
    @Local private var query = ""
    @Local private var ocr = true
    @Local private var stripMetadata = true
    @Local private var found: String?

    var body: some View {
        EditorHost(tool: .redact, actionTitle: "Redact & Save", editor: { model in
            CanvasEditor(model: model, tools: [.select, .redact], toolbarExtra: { EmptyView() }, sidebarExtra: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Find & redact").font(.headline)
                    HStack {
                        TextField("Word or phrase", text: $query).textFieldStyle(.roundedBorder).onSubmit { search(model, .text(query)) }
                        Button("Mark") { search(model, .text(query)) }.disabled(query.isEmpty)
                    }
                    Text("Common patterns").font(.subheadline)
                    HStack {
                        Button("Emails") { search(model, .regex("[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}")) }
                        Button("Phones") { search(model, .detector(.phoneNumber)) }
                    }
                    HStack {
                        Button("Card numbers") { search(model, .regex("\\b(?:\\d[ -]?){13,19}\\b")) }
                        Button("ID numbers") { search(model, .regex("\\b\\d{3}-\\d{2}-\\d{4}\\b|\\b[A-Z]{2}\\d{6,9}\\b")) }
                    }
                    HStack {
                        Button("Dates") { search(model, .detector(.date)) }
                        Button("Links") { search(model, .detector(.link)) }
                        Button("Addresses") { search(model, .detector(.address)) }
                    }
                    if let found { Text(found).font(.caption).foregroundStyle(.secondary) }
                    let n = model.items.filter { $0.kind == .redact }.count
                    HStack {
                        Text("\(n) area\(n == 1 ? "" : "s") marked").font(.caption)
                        Spacer()
                        Button("Clear All") { model.items.removeAll { $0.kind == .redact } }.disabled(n == 0)
                    }
                    Divider()
                    Toggle("Keep remaining text searchable (OCR)", isOn: $ocr)
                    Toggle("Remove document metadata", isOn: $stripMetadata)
                    Text("Redacted pages are flattened to images so the hidden content can’t be recovered.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                }
            })
        }, makeJob: { model in
            let (items, doc, url, o, strip) = (model.items.filter { $0.kind == .redact }, model.doc, model.url, ocr, stripMetadata)
            return { dir, p in
                guard !items.isEmpty else { throw ToolError.message("Mark at least one area to redact.") }
                let pages = Set(items.map(\.page))
                let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_redacted", ext: "pdf")
                let tmp = o ? try Workspace.newOutputDir().appendingPathComponent("r.pdf") : dest
                try PDFCore.render(doc, to: tmp, keepInfo: !strip,
                                   over: { i, _, _, size in ItemRenderer.draw(items.filter { $0.page == i }, size: size) },
                                   rasterizeDPI: { pages.contains($0) ? 200 : nil }, progress: p)
                if o {
                    let r = try OCR.makeSearchable([tmp], languages: nil, skipTextPages: true, out: tmp.deletingLastPathComponent(), progress: p)
                    try FileManager.default.moveItem(at: r.files[0], to: dest)
                }
                return ToolResult(files: [dest], message: "Permanently redacted \(items.count) area\(items.count == 1 ? "" : "s") on \(pages.count) page\(pages.count == 1 ? "" : "s").")
            }
        })
    }

    enum Pattern { case text(String), regex(String), detector(NSTextCheckingResult.CheckingType) }

    @MainActor func search(_ model: CanvasModel, _ pattern: Pattern) {
        var added = 0
        let regex: NSRegularExpression?
        switch pattern {
        case .text(let t): regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: t), options: [.caseInsensitive])
        case .regex(let r): regex = try? NSRegularExpression(pattern: r, options: [.caseInsensitive])
        case .detector(let type): regex = try? NSDataDetector(types: type.rawValue)
        }
        guard let regex else { return }
        for i in 0..<model.pageCount {
            guard let page = model.doc.page(at: i), let s = page.string else { continue }
            for m in regex.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
                guard let sel = page.selection(for: m.range) else { continue }
                for line in sel.selectionsByLine() {
                    let r = PDFCore.pageToUpright(line.bounds(for: page), page: page).insetBy(dx: -1.5, dy: -1.5)
                    guard r.width > 1, !model.items.contains(where: { $0.page == i && $0.kind == .redact && $0.rect.intersects(r) && $0.rect.intersection(r).width > r.width * 0.8 }) else { continue }
                    model.items.append(CanvasItem(page: i, kind: .redact, rect: r, fill: .black))
                    added += 1
                }
            }
        }
        found = added == 0 ? "No matches found." : "Marked \(added) match\(added == 1 ? "" : "es")."
    }
}

// MARK: - PDF Forms

struct FormsTool: View {
    @Local private var create = false
    @Local private var flatten = false
    @Local private var detected: String?

    var body: some View {
        EditorHost(tool: .forms, actionTitle: "Save Form", editor: { model in
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $create) { Text("Fill form").tag(false); Text("Create fields").tag(true) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    if !create { Toggle("Flatten when saving (fields become regular content)", isOn: $flatten) }
                    Spacer()
                }
                .padding(8)
                Divider()
                if create {
                    CanvasEditor(model: model, tools: [.select, .field(.text), .field(.multiline), .field(.checkbox), .field(.dropdown), .field(.list)],
                                 toolbarExtra: { EmptyView() }, sidebarExtra: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Fields").font(.headline)
                            Button { detect(model) } label: { Label("Detect Fields Automatically", systemImage: "wand.and.stars") }
                            Text("Finds blank lines (____) and checkboxes (☐, [ ]) and turns them into fields.").font(.caption).foregroundStyle(.secondary)
                            if let detected { Text(detected).font(.caption) }
                            Divider()
                        }
                    })
                } else {
                    PDFKitView(document: model.doc)
                }
            }
        }, makeJob: { model in
            let (doc, url, items, isCreate, flat) = (model.doc, model.url, model.items, create, flatten)
            if isCreate {
                for item in items {
                    guard case .field(let f) = item.kind, let page = doc.page(at: item.page) else { continue }
                    let w = PDFAnnotation(bounds: PDFCore.uprightToPage(item.rect, page: page), forType: .widget, withProperties: nil)
                    w.fieldName = item.name.isEmpty ? UUID().uuidString : item.name
                    w.backgroundColor = NSColor(calibratedRed: 0.86, green: 0.91, blue: 1, alpha: 0.6)
                    let border = PDFBorder(); border.lineWidth = 0.75
                    w.border = border
                    w.color = .systemBlue
                    if item.fontSize > 0 { w.font = NSFont(name: "Helvetica", size: item.fontSize) }
                    switch f {
                    case .text: w.widgetFieldType = .text
                    case .multiline: w.widgetFieldType = .text; w.isMultiline = true
                    case .checkbox: w.widgetFieldType = .button; w.widgetControlType = .checkBoxControl; w.buttonWidgetStateString = "Yes"
                    case .dropdown, .list:
                        w.widgetFieldType = .choice
                        w.isListChoice = f == .list
                        w.choices = item.choices.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                    page.addAnnotation(w)
                }
                model.items.removeAll { if case .field = $0.kind { return true }; return false }
                model.invalidateImages()
            }
            return { dir, _ in
                let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_form", ext: "pdf")
                try PDFCore.write(doc, to: dest, options: !isCreate && flat ? [.burnInAnnotationsOption: true] : nil)
                return ToolResult(files: [dest], message: isCreate ? "Added \(items.count) fillable field\(items.count == 1 ? "" : "s")." : nil)
            }
        })
    }

    @MainActor func detect(_ model: CanvasModel) {
        var n = 0
        let blanks = try! NSRegularExpression(pattern: "_{4,}")
        let boxes = try! NSRegularExpression(pattern: "[☐□❑▢◻]|\\[ ?\\]")
        for i in 0..<model.pageCount {
            guard let page = model.doc.page(at: i), let s = page.string else { continue }
            let range = NSRange(location: 0, length: (s as NSString).length)
            for m in blanks.matches(in: s, range: range) {
                guard let sel = page.selection(for: m.range) else { continue }
                let r = PDFCore.pageToUpright(sel.bounds(for: page), page: page)
                model.items.append(CanvasItem(page: i, kind: .field(.text), rect: CGRect(x: r.minX, y: r.maxY - 16, width: max(r.width, 40), height: 16),
                                              fontSize: 0, name: "Field\(i + 1)_\(n + 1)"))
                n += 1
            }
            for m in boxes.matches(in: s, range: range) {
                guard let sel = page.selection(for: m.range) else { continue }
                let r = PDFCore.pageToUpright(sel.bounds(for: page), page: page)
                let side = max(8, min(r.width, r.height))
                model.items.append(CanvasItem(page: i, kind: .field(.checkbox), rect: CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side),
                                              name: "Check\(i + 1)_\(n + 1)"))
                n += 1
            }
        }
        detected = n == 0 ? "No fields detected." : "Detected \(n) field\(n == 1 ? "" : "s")."
    }
}

// MARK: - Crop PDF

struct CropTool: View {
    @Local private var url: URL?
    @Local private var doc: PDFDocument?
    @Local private var page = 0
    @Local private var crop: CGRect?
    @Local private var allPages = true
    @Local private var dragStart: CGPoint?
    @StateObject private var runner = Runner()

    var body: some View {
        if let doc, let url, let p = doc.page(at: page) {
            let size = PDFCore.uprightSize(p)
            let rect = crop ?? CGRect(origin: .zero, size: size)
            VStack(spacing: 0) {
                HStack {
                    ToolIcon(tool: .crop, size: 28); Text("Crop PDF").font(.title3.bold())
                    Text(url.lastPathComponent).foregroundStyle(.secondary)
                    Spacer()
                    Button("Close File") { self.doc = nil; self.url = nil; crop = nil }
                    Button { apply(doc, url, rect, size) } label: { Label("Crop PDF", systemImage: "crop") }.buttonStyle(.borderedProminent).disabled(runner.isRunning)
                }
                .padding(10)
                Divider()
                HStack(spacing: 0) {
                    GeometryReader { geo in
                        let scale = min((geo.size.width - 40) / size.width, (geo.size.height - 40) / size.height)
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: p.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .cropBox)).resizable()
                            Path { path in
                                path.addRect(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
                                path.addRect(CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))
                            }
                            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                            Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                                .frame(width: rect.width * scale, height: rect.height * scale).offset(x: rect.minX * scale, y: rect.minY * scale)
                        }
                        .frame(width: size.width * scale, height: size.height * scale)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                            let a = CGPoint(x: v.startLocation.x / scale, y: v.startLocation.y / scale)
                            let b = CGPoint(x: min(max(v.location.x / scale, 0), size.width), y: min(max(v.location.y / scale, 0), size.height))
                            crop = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                        })
                        .shadow(radius: 4)
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .background(Color(nsColor: .underPageBackgroundColor))
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Drag on the page to select the area to keep, or set margins.").font(.callout).foregroundStyle(.secondary)
                        margin("Top", rect.minY) { crop = CGRect(x: rect.minX, y: $0, width: rect.width, height: rect.maxY - $0) }
                        margin("Bottom", size.height - rect.maxY) { crop = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: size.height - $0 - rect.minY) }
                        margin("Left", rect.minX) { crop = CGRect(x: $0, y: rect.minY, width: rect.maxX - $0, height: rect.height) }
                        margin("Right", size.width - rect.maxX) { crop = CGRect(x: rect.minX, y: rect.minY, width: size.width - $0 - rect.minX, height: rect.height) }
                        Button { crop = PDFCore.contentBounds(p) } label: { Label("Auto-detect Content", systemImage: "wand.and.rays") }
                        Button("Reset") { crop = nil }
                        Divider()
                        Picker("Apply to", selection: $allPages) { Text("All pages").tag(true); Text("This page only").tag(false) }.pickerStyle(.radioGroup)
                        HStack {
                            Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                            Text("Page \(page + 1) of \(doc.pageCount)").monospacedDigit()
                            Button { page = min(doc.pageCount - 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= doc.pageCount - 1)
                        }
                        Text("\(Int(rect.width)) × \(Int(rect.height)) pt").font(.caption).foregroundStyle(.secondary)
                        ResultPanel(runner: runner)
                        Spacer()
                    }
                    .padding(14).frame(width: 280)
                }
            }
        } else {
            ToolPage(tool: .crop) {
                DropZone(types: [.pdf], multiple: false, prompt: "Select a PDF to crop") { urls in
                    if let d = PDFDocument(url: urls[0]), !d.isLocked { doc = d; url = urls[0]; page = 0; crop = nil }
                    else { runner.error = "Couldn’t open that PDF (it may be locked — unlock it first)." }
                }
                ResultPanel(runner: runner)
            }
        }
    }

    private func margin(_ label: String, _ value: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 56, alignment: .leading)
            TextField("", value: Binding(get: { Double(value.rounded()) }, set: { set(max(0, CGFloat($0))) }), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 70)
            Stepper("", value: Binding(get: { Double(value) }, set: { set(max(0, CGFloat($0))) }), step: 4).labelsHidden()
            Text("pt").foregroundStyle(.secondary)
        }
    }

    private func apply(_ doc: PDFDocument, _ url: URL, _ rect: CGRect, _ size: CGSize) {
        let insets = NSEdgeInsets(top: rect.minY, left: rect.minX, bottom: size.height - rect.maxY, right: size.width - rect.maxX)
        let (all, current) = (allPages, page)
        let source = url
        runner.run { dir, _ in
            try PDFOps.crop(source, out: dir) { i, s in
                guard all || i == current else { return nil }
                return CGRect(x: insets.left, y: insets.top, width: s.width - insets.left - insets.right, height: s.height - insets.top - insets.bottom)
            }
        }
    }
}

// MARK: - Organize PDF

struct OrgPage: Identifiable, Equatable {
    let id = UUID()
    var source: Int
    var index: Int
    var rotation = 0
    var blank: CGSize?
}

@MainActor
final class OrganizeModel: ObservableObject {
    @Published var docs: [PDFDocument] = []
    @Published var names: [String] = []
    @Published var pages: [OrgPage] = []
    @Published var selected: Set<UUID> = []
    private var thumbs: [String: NSImage] = [:]

    func add(_ urls: [URL]) -> String? {
        for u in urls {
            guard let d = PDFDocument(url: u) else { return "Couldn’t open \(u.lastPathComponent)." }
            if d.isLocked { return "“\(u.lastPathComponent)” is locked. Unlock it first." }
            docs.append(d); names.append(u.lastPathComponent)
            pages += (0..<d.pageCount).map { OrgPage(source: docs.count - 1, index: $0) }
        }
        return nil
    }

    func thumbnail(_ p: OrgPage) -> NSImage {
        if p.blank != nil { return NSImage(size: CGSize(width: 1, height: 1.414), flipped: false) { r in NSColor.white.setFill(); r.fill(); return true } }
        let key = "\(p.source)-\(p.index)"
        if let t = thumbs[key] { return t }
        let t = docs[p.source].page(at: p.index)?.thumbnail(of: CGSize(width: 300, height: 300), for: .cropBox) ?? NSImage()
        thumbs[key] = t
        return t
    }

    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = pages.firstIndex(where: { $0.id == id }),
              let original = pages.firstIndex(where: { $0.id == target }) else { return }
        let item = pages.remove(at: from)
        var to = pages.firstIndex { $0.id == target }!
        if from < original { to += 1 } // dragging forward lands after the target
        pages.insert(item, at: to)
    }

    func rotate(_ ids: Set<UUID>, _ deg: Int) { for i in pages.indices where ids.contains(pages[i].id) { pages[i].rotation = PDFCore.normalizedRotation(pages[i].rotation + deg) } }
    func delete(_ ids: Set<UUID>) { pages.removeAll { ids.contains($0.id) }; selected.subtract(ids) }
    func duplicate(_ ids: Set<UUID>) {
        var out: [OrgPage] = []
        for p in pages { out.append(p); if ids.contains(p.id) { out.append(OrgPage(source: p.source, index: p.index, rotation: p.rotation, blank: p.blank)) } }
        pages = out
    }
    func insertBlank() {
        let ref = pages.last { selected.contains($0.id) } ?? pages.last
        let size = ref.flatMap { r in r.blank ?? docs[r.source].page(at: r.index).map(PDFCore.uprightSize) } ?? CGSize(width: 595, height: 842)
        let blank = OrgPage(source: 0, index: 0, blank: size)
        if let ref, let i = pages.firstIndex(of: ref) { pages.insert(blank, at: i + 1) } else { pages.append(blank) }
    }

    func build() -> PDFDocument {
        let out = PDFDocument()
        for p in pages {
            let page: PDFPage
            if let size = p.blank {
                page = PDFPage()
                page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
            } else {
                guard let c = docs[p.source].page(at: p.index)?.copy() as? PDFPage else { continue }
                page = c
            }
            page.rotation = PDFCore.normalizedRotation(page.rotation + p.rotation)
            out.insert(page, at: out.pageCount)
        }
        return out
    }
}

struct OrganizeTool: View {
    @StateObject private var model = OrganizeModel()
    @StateObject private var runner = Runner()
    @Local private var error: String?

    var body: some View {
        if model.pages.isEmpty && model.docs.isEmpty {
            ToolPage(tool: .organize) {
                DropZone(types: [.pdf], prompt: "Select PDF files") { error = model.add($0) }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ToolIcon(tool: .organize, size: 28); Text("Organize PDF").font(.title3.bold())
                    Spacer()
                    Button { if let u = FilePicker.open(types: [.pdf], multiple: true) { error = model.add(u) } } label: { Label("Add PDF", systemImage: "doc.badge.plus") }
                    Button { model.insertBlank() } label: { Label("Blank Page", systemImage: "doc") }
                    Divider().frame(height: 20)
                    let sel = model.selected
                    Button { model.rotate(sel, -90) } label: { Image(systemName: "rotate.left") }.help("Rotate left").disabled(sel.isEmpty)
                    Button { model.rotate(sel, 90) } label: { Image(systemName: "rotate.right") }.help("Rotate right").disabled(sel.isEmpty)
                    Button { model.duplicate(sel) } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate").disabled(sel.isEmpty)
                    Button { model.delete(sel) } label: { Image(systemName: "trash") }.help("Delete").disabled(sel.isEmpty)
                    Menu {
                        Button("Select All") { model.selected = Set(model.pages.map(\.id)) }
                        Button("Select Odd Pages") { model.selected = Set(model.pages.enumerated().filter { $0.offset % 2 == 0 }.map(\.element.id)) }
                        Button("Select Even Pages") { model.selected = Set(model.pages.enumerated().filter { $0.offset % 2 == 1 }.map(\.element.id)) }
                        Button("Deselect All") { model.selected = [] }
                        Divider()
                        Button("Reverse Order") { model.pages.reverse() }
                        Button("Start Over", role: .destructive) { model.pages = []; model.docs = []; model.names = []; model.selected = [] }
                    } label: { Image(systemName: "ellipsis.circle") }.fixedSize()
                    Divider().frame(height: 20)
                    Button { save() } label: { Label("Save PDF", systemImage: "square.and.arrow.down.fill") }.buttonStyle(.borderedProminent).disabled(model.pages.isEmpty || runner.isRunning)
                }
                .padding(10)
                Divider()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 18) {
                        ForEach(Array(model.pages.enumerated()), id: \.element.id) { i, p in
                            OrgPageCell(model: model, page: p, number: i + 1)
                        }
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(6) }
                Text("\(model.pages.count) pages · Drag pages to reorder · ⌘-click to select several").font(.caption).foregroundStyle(.secondary).padding(6)
            }
            .sheet(isPresented: Binding(get: { runner.result != nil || runner.error != nil }, set: { if !$0 { runner.reset() } })) {
                VStack(alignment: .leading) {
                    ResultPanel(runner: runner)
                    HStack { Spacer(); Button("Done") { runner.reset() }.keyboardShortcut(.defaultAction) }
                }.padding(20).frame(width: 520)
            }
        }
    }

    func save() {
        let doc = model.build()
        let name = (model.names.first.map { URL(fileURLWithPath: $0).baseName } ?? "document") + "_organized"
        runner.run { dir, _ in
            let dest = Workspace.uniqueURL(in: dir, name: name, ext: "pdf")
            try PDFCore.write(doc, to: dest)
            return ToolResult(files: [dest], message: "Saved \(doc.pageCount) pages.")
        }
    }
}

struct OrgPageCell: View {
    @ObservedObject var model: OrganizeModel
    let page: OrgPage
    let number: Int
    @Local private var hover = false
    @Local private var targeted = false

    var body: some View {
        let selected = model.selected.contains(page.id)
        VStack(spacing: 6) {
            Image(nsImage: model.thumbnail(page)).resizable().scaledToFit()
                .frame(width: 120, height: 150)
                .rotationEffect(.degrees(Double(page.rotation)))
                .frame(width: 150, height: 160)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : (targeted ? Color.orange : Color.clear), lineWidth: 3))
                .overlay(alignment: .top) {
                    if hover {
                        HStack(spacing: 4) {
                            cellButton("rotate.left") { model.rotate([page.id], -90) }
                            cellButton("rotate.right") { model.rotate([page.id], 90) }
                            cellButton("trash") { model.delete([page.id]) }
                        }
                        .padding(5)
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            Text(page.blank != nil ? "\(number) · blank" : model.docs.count > 1 ? "\(number) · \(model.names[page.source])" : "\(number)")
                .font(.caption).lineLimit(1).foregroundStyle(.secondary).frame(width: 150)
        }
        .onHover { hover = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                if selected { model.selected.remove(page.id) } else { model.selected.insert(page.id) }
            } else { model.selected = selected && model.selected.count == 1 ? [] : [page.id] }
        }
        .draggable(page.id.uuidString) {
            Image(nsImage: model.thumbnail(page)).resizable().scaledToFit().frame(width: 80, height: 100)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            withAnimation { model.move(id, before: page.id) }
            return true
        } isTargeted: { targeted = $0 }
    }

    private func cellButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }
}

// MARK: - Compare PDF

struct DiffRow: Identifiable {
    let id: Int
    let left: String?
    let right: String?
    var changed: Bool { left != right }
}

struct CompareTool: View {
    @Local private var a: URL?
    @Local private var b: URL?
    @Local private var visual = false
    @Local private var rows: [DiffRow] = []
    @Local private var onlyChanges = false
    @Local private var page = 0
    @Local private var summary = ""
    @Local private var busy = false

    var body: some View {
        ToolPage(tool: .compare) {
            HStack(alignment: .top, spacing: 16) {
                picker("Original", $a)
                picker("Modified", $b)
            }
            if let a, let b, let da = PDFDocument(url: a), let db = PDFDocument(url: b) {
                HStack {
                    Picker("", selection: $visual) { Text("Text comparison").tag(false); Text("Visual overlay").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                    Spacer()
                    if !visual {
                        Toggle("Only show changes", isOn: $onlyChanges)
                        Button("Compare") { compare(da, db) }.buttonStyle(.borderedProminent).disabled(busy)
                        if !rows.isEmpty { Button("Export Report…") { export() } }
                    } else {
                        let n = max(da.pageCount, db.pageCount)
                        Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                        Text("Page \(page + 1) of \(n)").monospacedDigit()
                        Button { page = min(n - 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= n - 1)
                    }
                }
                if visual { visualView(da, db) } else { textView }
            }
        }
        .onChange(of: a) { rows = []; page = 0 }
        .onChange(of: b) { rows = []; page = 0 }
    }

    private func picker(_ title: String, _ url: Binding<URL?>) -> some View {
        GroupBox {
            VStack {
                if let u = url.wrappedValue {
                    HStack { FileRow(url: u); Spacer(); Button("Change") { url.wrappedValue = FilePicker.open(types: [.pdf], multiple: false)?.first ?? u } }
                } else {
                    DropZone(types: [.pdf], multiple: false, prompt: title) { url.wrappedValue = $0[0] }.frame(height: 200)
                }
            }.padding(4)
        } label: { Text(title).font(.headline) }
    }

    private var textView: some View {
        VStack(alignment: .leading) {
            if busy { ProgressView("Comparing…") }
            if !summary.isEmpty { Text(summary).foregroundStyle(.secondary) }
            if !rows.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(rows.filter { !onlyChanges || $0.changed }) { r in
                        HStack(alignment: .top, spacing: 0) {
                            cell(r.left, color: r.changed && r.left != nil ? .red : nil)
                            Divider()
                            cell(r.right, color: r.changed && r.right != nil ? .green : nil)
                        }
                        Divider().opacity(0.4)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            }
        }
    }

    private func cell(_ text: String?, color: Color?) -> some View {
        Text(text ?? "")
            .font(.system(.callout, design: .default)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.map { $0.opacity(0.16) } ?? Color.clear)
    }

    private func visualView(_ da: PDFDocument, _ db: PDFDocument) -> some View {
        let ia = da.page(at: page).map { $0.thumbnail(of: CGSize(width: 900, height: 1200), for: .cropBox) }
        let ib = db.page(at: page).map { $0.thumbnail(of: CGSize(width: 900, height: 1200), for: .cropBox) }
        return HStack(alignment: .top, spacing: 12) {
            pane("Original", ia.map { Image(nsImage: $0).resizable().scaledToFit() })
            pane("Modified", ib.map { Image(nsImage: $0).resizable().scaledToFit() })
            pane("Differences", ia.flatMap { a in ib.map { b in
                ZStack { Image(nsImage: a).resizable().scaledToFit(); Image(nsImage: b).resizable().scaledToFit().blendMode(.difference) }
                    .compositingGroup().colorInvert()
            } })
        }
    }

    private func pane<V: View>(_ title: String, _ content: V?) -> some View {
        VStack {
            Text(title).font(.headline)
            if let content { content.background(Color.white).shadow(radius: 2) } else { Text("No page").foregroundStyle(.secondary).frame(height: 200) }
        }.frame(maxWidth: .infinity)
    }

    private func compare(_ da: PDFDocument, _ db: PDFDocument) {
        busy = true
        func lines(_ d: PDFDocument) -> [String] {
            (0..<d.pageCount).flatMap { (d.page(at: $0)?.string ?? "").components(separatedBy: .newlines) }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let (la, lb) = (lines(da), lines(db))
        Task.detached {
            let diff = lb.difference(from: la)
            var removed = Set<Int>(), inserted = Set<Int>()
            for c in diff { switch c { case .remove(let o, _, _): removed.insert(o); case .insert(let o, _, _): inserted.insert(o) } }
            var out: [DiffRow] = []
            var i = 0, j = 0
            while i < la.count || j < lb.count {
                if i < la.count, removed.contains(i), j < lb.count, inserted.contains(j) { out.append(DiffRow(id: out.count, left: la[i], right: lb[j])); i += 1; j += 1 }
                else if i < la.count, removed.contains(i) { out.append(DiffRow(id: out.count, left: la[i], right: nil)); i += 1 }
                else if j < lb.count, inserted.contains(j) { out.append(DiffRow(id: out.count, left: nil, right: lb[j])); j += 1 }
                else { out.append(DiffRow(id: out.count, left: i < la.count ? la[i] : nil, right: j < lb.count ? lb[j] : nil)); i += 1; j += 1 }
            }
            let changes = out.filter(\.changed).count
            let (result, nRemoved, nInserted) = (out, removed.count, inserted.count)
            await MainActor.run {
                rows = result
                summary = changes == 0 ? "No text differences found." : "\(changes) changed line\(changes == 1 ? "" : "s"): \(nRemoved) removed, \(nInserted) added."
                busy = false
            }
        }
    }

    private func export() {
        var html = "<html><head><meta charset='utf-8'><style>body{font-family:-apple-system;font-size:10pt}table{width:100%;border-collapse:collapse}td{width:50%;vertical-align:top;padding:2px 6px;border-bottom:1px solid #eee}.d{background:#fde2e2}.a{background:#ddf5dd}</style></head><body>"
        html += "<h2>Comparison: \((a?.lastPathComponent ?? "").xmlEscaped) vs \((b?.lastPathComponent ?? "").xmlEscaped)</h2><p>\(summary.xmlEscaped)</p><table>"
        for r in rows where !onlyChanges || r.changed {
            html += "<tr><td class='\(r.changed && r.left != nil ? "d" : "")'>\((r.left ?? "").xmlEscaped)</td><td class='\(r.changed && r.right != nil ? "a" : "")'>\((r.right ?? "").xmlEscaped)</td></tr>"
        }
        html += "</table></body></html>"
        let p = NSSavePanel()
        p.nameFieldStringValue = "comparison.pdf"
        p.allowedContentTypes = [.pdf]
        guard p.runModal() == .OK, let dest = p.url else { return }
        Task { try? await WebPDF.render(html: html, baseURL: nil, out: dest, landscape: true); NSWorkspace.shared.open(dest) }
    }
}

// MARK: - Scan to PDF

struct ScanPage: Identifiable { let id = UUID(); var image: CGImage }

struct ScanTool: View {
    @Local private var pages: [ScanPage] = []
    @Local private var straighten = true
    @Local private var filter = ScanProcessing.Filter.color
    @Local private var ocr = true
    @Local private var showScanner = false
    @StateObject private var runner = Runner()

    var body: some View {
        ToolPage(tool: .scan) {
            HStack(spacing: 14) {
                SourceCard(title: "iPhone or iPad", detail: "Scan with Continuity Camera", symbol: "iphone") {
                    ContinuityCameraButton { addImages($0) }
                }
                SourceCard(title: "Scanner", detail: "Use a connected or network scanner", symbol: "scanner") {
                    Button("Open Scanner…") { showScanner = true }
                }
                SourceCard(title: "Photos", detail: "Import photos of documents", symbol: "photo.on.rectangle") {
                    Button("Choose Images…") { if let u = FilePicker.open(types: UTType.imageTypes + [.pdf], multiple: true) { importFiles(u) } }
                }
            }
            if !pages.isEmpty {
                OptionsBox(title: "\(pages.count) scanned page\(pages.count == 1 ? "" : "s")") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(Array(pages.enumerated()), id: \.element.id) { i, p in
                                VStack {
                                    Image(decorative: p.image, scale: 1).resizable().scaledToFit().frame(height: 150).shadow(radius: 2)
                                    HStack(spacing: 6) {
                                        Button { if i > 0 { pages.swapAt(i, i - 1) } } label: { Image(systemName: "chevron.left") }.disabled(i == 0)
                                        Text("\(i + 1)").font(.caption)
                                        Button { if i < pages.count - 1 { pages.swapAt(i, i + 1) } } label: { Image(systemName: "chevron.right") }.disabled(i == pages.count - 1)
                                        Button { pages.remove(at: i) } label: { Image(systemName: "trash") }
                                    }.buttonStyle(.borderless)
                                }
                            }
                        }.padding(4)
                    }
                    Picker("Filter", selection: $filter) { ForEach(ScanProcessing.Filter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 440)
                    Toggle("Detect document edges and straighten new photos", isOn: $straighten)
                    Toggle("Make text searchable (OCR)", isOn: $ocr)
                }
                HStack {
                    Spacer()
                    Button { create() } label: { Label("Create PDF", systemImage: "doc.fill").padding(.horizontal, 20).padding(.vertical, 4) }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(runner.isRunning)
                    Button("Clear") { pages = [] }
                    Spacer()
                }
            }
            ResultPanel(runner: runner)
        }
        .sheet(isPresented: $showScanner) {
            VStack(spacing: 0) {
                ScannerView { url in importFiles([url]) }.frame(width: 760, height: 560)
                HStack { Spacer(); Button("Done") { showScanner = false }.keyboardShortcut(.defaultAction) }.padding(12)
            }
        }
    }

    private func addImages(_ images: [CGImage]) {
        let s = straighten
        pages += images.map { ScanPage(image: s ? ScanProcessing.straighten($0) : $0) }
    }

    private func importFiles(_ urls: [URL]) {
        var imgs: [CGImage] = []
        for u in urls {
            if u.pathExtension.lowercased() == "pdf", let d = PDFDocument(url: u) {
                imgs += (0..<d.pageCount).compactMap { d.page(at: $0).flatMap { PDFCore.image(of: $0, scale: 2.5) } }
            } else { imgs += ImageConvert.loadImages(u) }
        }
        addImages(imgs)
    }

    private func create() {
        let (imgs, f, o) = (pages.map(\.image), filter, ocr)
        runner.run { dir, p in
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm"
            let dest = Workspace.uniqueURL(in: dir, name: "Scan \(df.string(from: Date()))", ext: "pdf")
            try ScanProcessing.makePDF(imgs, filter: f, ocr: o, to: dest, progress: p)
            return ToolResult(files: [dest])
        }
    }
}

struct SourceCard<Content: View>: View {
    let title: String, detail: String, symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            content
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 170)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.15)))
    }
}
