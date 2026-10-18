import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

enum FieldKind: String, CaseIterable {
    case text = "Text field", multiline = "Multi-line text", checkbox = "Checkbox", dropdown = "Dropdown", list = "List box"
}

enum ItemKind: Equatable {
    case text, image, rect, ellipse, line, ink, highlight, whiteout, redact
    case field(FieldKind)
}

enum EditorTool: Hashable, Identifiable {
    case select, text, image, rect, ellipse, line, ink, highlight, whiteout, redact
    case field(FieldKind)
    var id: String { label }

    var label: String {
        switch self {
        case .select: return "Select"
        case .text: return "Text"
        case .image: return "Image"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .ink: return "Draw"
        case .highlight: return "Highlight"
        case .whiteout: return "Whiteout"
        case .redact: return "Redact area"
        case .field(let f): return f.rawValue
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .text: return "textformat"
        case .image: return "photo"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .ink: return "scribble.variable"
        case .highlight: return "highlighter"
        case .whiteout: return "eraser"
        case .redact: return "rectangle.fill"
        case .field(.text): return "character.cursor.ibeam"
        case .field(.multiline): return "text.alignleft"
        case .field(.checkbox): return "checkmark.square"
        case .field(.dropdown): return "chevron.down.square"
        case .field(.list): return "list.bullet.rectangle"
        }
    }

    /// Single-key shortcut on the canvas.
    var shortcut: Character? {
        switch self {
        case .select: return "v"
        case .text: return "t"
        case .image: return "i"
        case .rect: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .ink: return "d"
        case .highlight: return "h"
        case .whiteout: return "w"
        case .redact: return "x"
        case .field: return nil
        }
    }

    var kind: ItemKind? {
        switch self {
        case .select: return nil
        case .text: return .text
        case .image: return .image
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .line: return .line
        case .ink: return .ink
        case .highlight: return .highlight
        case .whiteout: return .whiteout
        case .redact: return .redact
        case .field(let f): return .field(f)
        }
    }
}

struct CanvasItem: Identifiable, Equatable {
    var id = UUID()
    var page: Int
    var kind: ItemKind
    /// Upright, top-left page coordinates in points.
    var rect: CGRect
    var text = ""
    var fontName = "Helvetica"
    var fontSize: CGFloat = 16
    var color: NSColor = .black
    var fill: NSColor?
    var lineWidth: CGFloat = 2
    var opacity: CGFloat = 1
    var image: NSImage?
    /// Normalized (0–1) points inside `rect`, for lines and drawings.
    var points: [CGPoint] = []
    var choices: [String] = ["Option 1", "Option 2", "Option 3"]
    var name = ""

    var font: NSFont { NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize) }
    var attributedText: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color.withAlphaComponent(opacity)])
    }
}

@MainActor
final class CanvasModel: ObservableObject {
    let doc: PDFDocument
    let url: URL
    @Published var items: [CanvasItem] = [] { didSet { recordUndo(from: oldValue) } }
    @Published var selection: UUID?
    /// 1 = page fits the canvas.
    @Published var zoom: CGFloat = 1
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var tool: EditorTool = .select
    @Published var page = 0
    @Published var pendingImage: NSImage?

    // Defaults for new items
    @Published var color: NSColor = .black
    @Published var fill: NSColor?
    @Published var fontName = "Helvetica"
    @Published var fontSize: CGFloat = 16
    @Published var lineWidth: CGFloat = 2

    private var cache: [Int: NSImage] = [:]
    private var fieldCounter = 0

    // Undo history: snapshots of `items`.
    private var undoStack: [[CanvasItem]] = []
    private var redoStack: [[CanvasItem]] = []
    private var restoring = false
    private var gestureSnapshot: [CanvasItem]?
    private var lastRecord = Date.distantPast
    private var lastChangedID: UUID?

    init(doc: PDFDocument, url: URL) {
        self.doc = doc
        self.url = url
    }

    var pageCount: Int { doc.pageCount }
    func pageSize(_ i: Int) -> CGSize { doc.page(at: i).map(PDFCore.uprightSize) ?? CGSize(width: 612, height: 792) }

    func image(_ i: Int) -> NSImage {
        if let c = cache[i] { return c }
        guard let p = doc.page(at: i) else { return NSImage() }
        let s = PDFCore.uprightSize(p)
        let k = min(2.5, 2400 / max(s.width, s.height))
        let img = p.thumbnail(of: CGSize(width: s.width * k, height: s.height * k), for: .cropBox)
        cache[i] = img
        return img
    }

    func invalidateImages() { cache = [:]; objectWillChange.send() }

    var selectedIndex: Int? { items.firstIndex { $0.id == selection } }

    func update(_ id: UUID, _ change: (inout CanvasItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    func add(_ item: CanvasItem) {
        items.append(item)
        selection = item.id
    }

    func deleteSelection() {
        items.removeAll { $0.id == selection }
        selection = nil
    }

    func duplicateSelection() {
        guard let i = selectedIndex else { return }
        var c = items[i]
        c.id = UUID()
        c.rect = c.rect.offsetBy(dx: 12, dy: 12)
        add(c)
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let id = selection else { return }
        update(id) { $0.rect = $0.rect.offsetBy(dx: dx, dy: dy) }
    }

    // MARK: Undo

    /// Called before a drag/resize/draw so the whole gesture becomes one undo step.
    func beginGesture() { gestureSnapshot = items }

    func endGesture() {
        guard let before = gestureSnapshot else { return }
        gestureSnapshot = nil
        if before != items { push(before); lastChangedID = nil }
    }

    private func recordUndo(from old: [CanvasItem]) {
        guard !restoring, gestureSnapshot == nil, old != items else { return }
        // Coalesce rapid edits to one item (typing in the inspector, steppers, arrow-key nudges).
        let changed = singleChangedID(old, items)
        if let changed, changed == lastChangedID, Date().timeIntervalSince(lastRecord) < 1 {
            lastRecord = Date()
            return
        }
        push(old)
        lastChangedID = changed
        lastRecord = Date()
    }

    private func singleChangedID(_ a: [CanvasItem], _ b: [CanvasItem]) -> UUID? {
        guard a.count == b.count else { return nil }
        let diffs = zip(a, b).filter { $0 != $1 }
        guard diffs.count == 1, diffs[0].0.id == diffs[0].1.id else { return nil }
        return diffs[0].0.id
    }

    private func push(_ snapshot: [CanvasItem]) {
        undoStack.append(snapshot)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
        updateUndoState()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(items)
        restore(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        restore(next)
    }

    private func restore(_ snapshot: [CanvasItem]) {
        restoring = true
        items = snapshot
        restoring = false
        lastChangedID = nil
        if let s = selection, !items.contains(where: { $0.id == s }) { selection = nil }
        updateUndoState()
    }

    private func updateUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Zoom

    func zoom(by factor: CGFloat) { zoom = min(8, max(0.5, zoom * factor)) }

    func hit(_ p: CGPoint, scale: CGFloat) -> CanvasItem? {
        let pad = 6 / scale
        return items.last { $0.page == page && $0.rect.insetBy(dx: -pad, dy: -pad).contains(p) }
    }

    func fitText(_ item: inout CanvasItem) {
        let maxW = max(40, pageSize(item.page).width - item.rect.minX - 4)
        let r = item.attributedText.boundingRect(with: CGSize(width: maxW, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        item.rect.size = CGSize(width: ceil(r.width) + 4, height: ceil(max(r.height, item.fontSize * 1.2)) + 2)
    }

    /// Creates an item for the current tool from a drag rectangle (or a tap when `tap` is true).
    func makeItem(_ r: CGRect, start: CGPoint, end: CGPoint, tap: Bool) -> CanvasItem? {
        guard let kind = tool.kind else { return nil }
        var item = CanvasItem(page: page, kind: kind, rect: r, fontName: fontName, fontSize: fontSize, color: color, fill: fill, lineWidth: lineWidth)
        switch kind {
        case .text:
            item.text = "Double-click to edit"
            item.rect.origin = start
            fitText(&item)
        case .image:
            guard let img = pendingImage else { return nil }
            item.image = img
            let aspect = img.size.height / max(img.size.width, 1)
            let w = tap ? min(180, pageSize(page).width / 3) : max(r.width, 20)
            item.rect = CGRect(x: tap ? start.x - w / 2 : r.minX, y: tap ? start.y - w * aspect / 2 : r.minY, width: w, height: w * aspect)
        case .line:
            if tap { return nil }
            let rr = CGRect(x: r.minX, y: r.minY, width: max(r.width, 1), height: max(r.height, 1))
            item.rect = rr
            item.points = [start, end].map { CGPoint(x: ($0.x - rr.minX) / rr.width, y: ($0.y - rr.minY) / rr.height) }
        case .rect, .ellipse, .highlight, .whiteout, .redact:
            if tap { item.rect = CGRect(x: start.x - 60, y: start.y - 20, width: 120, height: 40) }
            if kind == .highlight { item.fill = .systemYellow; item.opacity = 0.4 }
            if kind == .whiteout { item.fill = .white }
            if kind == .redact { item.fill = .black }
            if kind == .rect || kind == .ellipse { item.fill = fill }
        case .field(let f):
            fieldCounter += 1
            item.name = "\(f == .checkbox ? "Checkbox" : "Field")\(fieldCounter)"
            item.color = .black
            item.fontSize = 12
            if tap {
                let size: CGSize
                switch f {
                case .text: size = CGSize(width: 180, height: 22)
                case .multiline: size = CGSize(width: 240, height: 70)
                case .checkbox: size = CGSize(width: 14, height: 14)
                case .dropdown: size = CGSize(width: 150, height: 22)
                case .list: size = CGSize(width: 150, height: 66)
                }
                item.rect = CGRect(origin: start, size: size)
            }
        case .ink: return nil
        }
        return item
    }

    func inkItem(_ pts: [CGPoint]) -> CanvasItem? {
        guard pts.count > 1 else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let r = CGRect(x: xs.min()!, y: ys.min()!, width: max(xs.max()! - xs.min()!, 1), height: max(ys.max()! - ys.min()!, 1))
        return CanvasItem(page: page, kind: .ink, rect: r, color: color, lineWidth: lineWidth,
                          points: pts.map { CGPoint(x: ($0.x - r.minX) / r.width, y: ($0.y - r.minY) / r.height) })
    }
}

// MARK: - Drawing items into PDFs (upright, top-left, AppKit context installed)

enum ItemRenderer {
    static func draw(_ items: [CanvasItem], size: CGSize) {
        for item in items { draw(item) }
    }

    static func draw(_ item: CanvasItem) {
        let r = item.rect
        func strokeFill(_ path: NSBezierPath) {
            if let f = item.fill { f.withAlphaComponent(f.alphaComponent * item.opacity).setFill(); path.fill() }
            if item.lineWidth > 0 { item.color.withAlphaComponent(item.opacity).setStroke(); path.lineWidth = item.lineWidth; path.stroke() }
        }
        switch item.kind {
        case .text:
            item.attributedText.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading])
        case .image:
            item.image?.draw(in: r, from: .zero, operation: .sourceOver, fraction: item.opacity, respectFlipped: true, hints: nil)
        case .rect: strokeFill(NSBezierPath(rect: r))
        case .ellipse: strokeFill(NSBezierPath(ovalIn: r))
        case .line, .ink:
            let path = NSBezierPath()
            for (i, p) in item.points.enumerated() {
                let q = CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
                if i == 0 { path.move(to: q) } else { path.line(to: q) }
            }
            path.lineWidth = item.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            item.color.withAlphaComponent(item.opacity).setStroke()
            path.stroke()
        case .highlight:
            NSGraphicsContext.current?.compositingOperation = .multiply
            (item.fill ?? .systemYellow).withAlphaComponent(item.opacity).setFill()
            r.fill(using: .multiply)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        case .whiteout:
            NSColor.white.setFill(); r.fill()
        case .redact:
            NSColor.black.setFill(); r.fill()
        case .field: break
        }
    }
}

// MARK: - Canvas view

struct ItemView: View {
    let item: CanvasItem
    let scale: CGFloat
    let selected: Bool

    var body: some View {
        let r = item.rect
        content
            .frame(width: max(r.width * scale, 1), height: max(r.height * scale, 1), alignment: .topLeading)
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .padding(-3)
                        .overlay(alignment: .bottomTrailing) {
                            Circle().fill(Color.white).overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                                .frame(width: 11, height: 11).offset(x: 8, y: 8)
                        }
                }
            }
            .offset(x: r.minX * scale, y: r.minY * scale)
            .allowsHitTesting(false)
    }

    @ViewBuilder var content: some View {
        let stroke = Color(nsColor: item.color).opacity(item.opacity)
        let fill = item.fill.map { Color(nsColor: $0).opacity(item.opacity) } ?? .clear
        switch item.kind {
        case .text:
            Text(item.text)
                .font(Font(NSFont(name: item.fontName, size: item.fontSize * scale) ?? .systemFont(ofSize: item.fontSize * scale)))
                .foregroundStyle(stroke)
                .fixedSize(horizontal: false, vertical: true)
        case .image:
            if let img = item.image { Image(nsImage: img).resizable().opacity(item.opacity) }
        case .rect:
            Rectangle().fill(fill).overlay(Rectangle().stroke(stroke, lineWidth: item.lineWidth * scale))
        case .ellipse:
            Ellipse().fill(fill).overlay(Ellipse().stroke(stroke, lineWidth: item.lineWidth * scale))
        case .line, .ink:
            Path { path in
                let w = item.rect.width * scale, h = item.rect.height * scale
                for (i, p) in item.points.enumerated() {
                    let q = CGPoint(x: p.x * w, y: p.y * h)
                    if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
            }
            .stroke(stroke, style: StrokeStyle(lineWidth: item.lineWidth * scale, lineCap: .round, lineJoin: .round))
        case .highlight:
            Rectangle().fill(Color(nsColor: item.fill ?? .systemYellow).opacity(item.opacity)).blendMode(.multiply)
        case .whiteout:
            Rectangle().fill(Color.white).overlay(Rectangle().stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
        case .redact:
            Rectangle().fill(Color.black)
        case .field(let f):
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.blue.opacity(0.12)).overlay(Rectangle().stroke(Color.blue, lineWidth: 1))
                switch f {
                case .checkbox: EmptyView()
                case .dropdown: HStack { Spacer(); Image(systemName: "chevron.down").font(.system(size: 9 * max(scale, 0.6))).padding(.trailing, 3) }
                default: Text(item.name).font(.system(size: 9 * max(scale, 0.6))).foregroundStyle(.blue).padding(.leading, 3)
                }
            }
        }
    }
}

struct PageCanvasView: View {
    @ObservedObject var model: CanvasModel
    var tools: [EditorTool] = []
    var onDoubleClickText: ((UUID) -> Void)? = nil
    @FocusState private var focused: Bool
    @Local private var pinchBase: CGFloat?

    enum DragMode { case none, create(CGPoint), move(UUID, CGRect), resize(UUID, CGRect, CGFloat), ink([CGPoint]) }

    @Local private var drag: DragMode?
    @Local private var draft: CanvasItem?
    @Local private var lastTap = Date.distantPast

    var body: some View {
        GeometryReader { geo in
            let size = model.pageSize(model.page)
            let fit = max(0.05, min((geo.size.width - 48) / size.width, (geo.size.height - 48) / size.height))
            let scale = fit * model.zoom
            let disp = CGSize(width: size.width * scale, height: size.height * scale)
            ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: model.image(model.page)).resizable().frame(width: disp.width, height: disp.height)
                ForEach(model.items.filter { $0.page == model.page }) { item in
                    ItemView(item: item, scale: scale, selected: item.id == model.selection)
                }
                if let d = draft { ItemView(item: d, scale: scale, selected: false) }
            }
            .frame(width: disp.width, height: disp.height, alignment: .topLeading)
            .background(Color.white)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { changed($0, scale: scale, size: size) }
                .onEnded { ended($0, scale: scale) })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    if pinchBase == nil { pinchBase = model.zoom }
                    model.zoom = min(8, max(0.5, (pinchBase ?? 1) * v.magnification))
                }
                .onEnded { _ in pinchBase = nil })
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .padding(24)
            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { handleKey($0) }
        .onAppear { focused = true }
        .accessibilityLabel("Page \(model.page + 1) canvas")
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
        let hasSelection = model.selectedIndex != nil
        switch press.key {
        case .leftArrow:
            if hasSelection { model.nudgeSelection(dx: -step, dy: 0) } else { model.page = max(0, model.page - 1) }
        case .rightArrow:
            if hasSelection { model.nudgeSelection(dx: step, dy: 0) } else { model.page = min(model.pageCount - 1, model.page + 1) }
        case .upArrow:
            guard hasSelection else { return .ignored }
            model.nudgeSelection(dx: 0, dy: -step)
        case .downArrow:
            guard hasSelection else { return .ignored }
            model.nudgeSelection(dx: 0, dy: step)
        case .delete, .deleteForward:
            guard hasSelection else { return .ignored }
            model.deleteSelection()
        case .escape:
            model.selection = nil
            model.tool = .select
        default:
            guard press.modifiers.subtracting(.shift).isEmpty, let c = press.characters.lowercased().first,
                  let t = tools.first(where: { $0.shortcut == c }) else { return .ignored }
            model.tool = t
        }
        return .handled
    }

    private func pt(_ p: CGPoint, _ scale: CGFloat) -> CGPoint { CGPoint(x: p.x / scale, y: p.y / scale) }

    private func changed(_ v: DragGesture.Value, scale: CGFloat, size: CGSize) {
        let p = pt(v.location, scale), s = pt(v.startLocation, scale)
        if drag == nil {
            model.beginGesture()
            switch model.tool {
            case .select:
                if let i = model.selectedIndex, model.items[i].page == model.page {
                    let r = model.items[i].rect
                    let handle = CGRect(x: r.maxX - 4 / scale, y: r.maxY - 4 / scale, width: 16 / scale, height: 16 / scale)
                    if handle.contains(s) { drag = .resize(model.items[i].id, r, model.items[i].fontSize); break }
                }
                if let hit = model.hit(s, scale: scale) {
                    model.selection = hit.id
                    drag = .move(hit.id, hit.rect)
                } else {
                    model.selection = nil
                    drag = DragMode.none
                }
            case .ink: drag = .ink([s])
            default: drag = .create(s)
            }
        }
        switch drag {
        case .move(let id, let orig):
            model.update(id) {
                $0.rect.origin = CGPoint(x: min(max(orig.minX + p.x - s.x, -orig.width / 2), size.width - orig.width / 2),
                                         y: min(max(orig.minY + p.y - s.y, -orig.height / 2), size.height - orig.height / 2))
            }
        case .resize(let id, let orig, let font):
            model.update(id) { item in
                var w = max(6, orig.width + p.x - s.x), h = max(6, orig.height + p.y - s.y)
                switch item.kind {
                case .text:
                    item.fontSize = max(4, font * h / orig.height)
                    item.rect.size = CGSize(width: w, height: h)
                    return
                case .image, .field(.checkbox):
                    h = w * orig.height / orig.width
                default: break
                }
                if case .field(.checkbox) = item.kind { w = max(w, 8); h = w }
                item.rect.size = CGSize(width: w, height: h)
            }
        case .create(let start):
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            if r.width > 3 || r.height > 3 { draft = model.makeItem(r, start: start, end: p, tap: false) }
        case .ink(let pts):
            let next = pts + [p]
            drag = .ink(next)
            draft = model.inkItem(next)
        default: break
        }
    }

    private func ended(_ v: DragGesture.Value, scale: CGFloat) {
        let p = pt(v.location, scale), s = pt(v.startLocation, scale)
        switch drag {
        case .create(let start):
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            let tap = r.width <= 3 && r.height <= 3
            if let item = model.makeItem(r, start: start, end: p, tap: tap) {
                model.add(item)
                if item.kind == .text { model.tool = .select; onDoubleClickText?(item.id) }
            } else if model.tool == .image && model.pendingImage == nil {
                NSSound.beep()
            }
        case .ink(let pts):
            if let item = model.inkItem(pts) { model.items.append(item) }
        case .move(let id, _):
            // Double-click on text opens the editor.
            if hypot(p.x - s.x, p.y - s.y) < 2 {
                if Date().timeIntervalSince(lastTap) < 0.35, let item = model.items.first(where: { $0.id == id }), item.kind == .text {
                    onDoubleClickText?(id)
                }
                lastTap = Date()
            }
        default: break
        }
        drag = nil
        draft = nil
        model.endGesture()
        focused = true
    }
}

// MARK: - Editor chrome

struct PageThumbnails: View {
    @ObservedObject var model: CanvasModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<model.pageCount, id: \.self) { i in
                        VStack(spacing: 4) {
                            Image(nsImage: model.image(i)).resizable().scaledToFit()
                                .frame(maxWidth: 84, maxHeight: 108)
                                .overlay(Rectangle().strokeBorder(i == model.page ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: i == model.page ? 3 : 1))
                                .overlay(alignment: .topTrailing) {
                                    let n = model.items.filter { $0.page == i }.count
                                    if n > 0 { Text("\(n)").font(.caption2.bold()).padding(3).background(Circle().fill(Color.accentColor)).foregroundStyle(.white).offset(x: 4, y: -4) }
                                }
                            Text("\(i + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                        .id(i)
                        .onTapGesture { model.page = i; model.selection = nil }
                    }
                }
                .padding(12)
            }
            .onChange(of: model.page) { proxy.scrollTo(model.page) }
        }
        .frame(width: 112)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct ToolPalette: View {
    @ObservedObject var model: CanvasModel
    let tools: [EditorTool]
    var body: some View {
        // Labeled when there's room, icons only when tighter, scrolling as a last resort.
        ViewThatFits(in: .horizontal) {
            row(labels: true)
            row(labels: false)
            ScrollView(.horizontal, showsIndicators: false) { row(labels: false) }
        }
    }

    private func row(labels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(tools) { t in
                Button { select(t) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.symbol).font(.system(size: 15)).frame(height: 18)
                        if labels { Text(t.label).font(.system(size: 10)).fixedSize() }
                    }
                    .frame(minWidth: labels ? 58 : 32, minHeight: 30).padding(.vertical, labels ? 5 : 2)
                    .background(RoundedRectangle(cornerRadius: 7).fill(model.tool == t ? Color.accentColor.opacity(0.2) : .clear))
                    .foregroundStyle(model.tool == t ? Color.accentColor : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.shortcut.map { "\(t.label) (\(String($0).uppercased()))" } ?? t.label)
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(model.tool == t ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    /// Choosing the Image tool without an image (or choosing it again) asks for an image file.
    private func select(_ t: EditorTool) {
        if t == .image, model.pendingImage == nil || model.tool == .image {
            guard let u = FilePicker.open(types: UTType.imageTypes, multiple: false)?.first, let img = NSImage(contentsOf: u) else { return }
            model.pendingImage = img
        }
        model.tool = t
    }
}

/// Undo/redo, zoom and page navigation under the canvas.
struct EditorStatusBar: View {
    @ObservedObject var model: CanvasModel
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command).disabled(!model.canUndo).help("Undo (⌘Z)")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo).help("Redo (⇧⌘Z)")
            }
            Spacer()
            HStack(spacing: 4) {
                Button { model.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command).help("Zoom Out (⌘−)")
                Button { model.zoom = 1 } label: { Text(model.zoom == 1 ? "Fit" : "\(Int((model.zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 44) }
                    .keyboardShortcut("0", modifiers: .command).help("Zoom to Fit (⌘0)")
                Button { model.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command).help("Zoom In (⌘=)")
            }
            Spacer()
            PageNavigator(model: model)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}

struct PageNavigator: View {
    @ObservedObject var model: CanvasModel
    var body: some View {
        HStack(spacing: 6) {
            Button { model.page = max(0, model.page - 1) } label: { Image(systemName: "chevron.left") }.disabled(model.page == 0)
            Text("Page \(model.page + 1) of \(model.pageCount)").monospacedDigit()
            Button { model.page = min(model.pageCount - 1, model.page + 1) } label: { Image(systemName: "chevron.right") }.disabled(model.page >= model.pageCount - 1)
        }
    }
}

/// Inspector for the selected item, or defaults for new items.
struct ItemInspector: View {
    @ObservedObject var model: CanvasModel
    @FocusState private var textFocused: Bool
    var focusText: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let i = model.selectedIndex {
                let item = model.items[i]
                Text(title(item.kind)).font(.headline)
                switch item.kind {
                case .text:
                    TextEditor(text: binding(i, \.text, refit: true))
                        .font(.body).frame(height: 90).border(Color.secondary.opacity(0.3)).focused($textFocused)
                    FontPicker(fontName: binding(i, \.fontName, refit: true))
                    Stepper("Size \(Int(item.fontSize))", value: binding(i, \.fontSize, refit: true), in: 4...200)
                    ColorPicker("Color", selection: Binding(get: { Color(nsColor: model.items[i].color) }, set: { c in model.items[i].color = NSColor(c) }))
                case .image:
                    opacity(i)
                case .rect, .ellipse:
                    ColorPicker("Stroke", selection: Binding(get: { Color(nsColor: model.items[i].color) }, set: { model.items[i].color = NSColor($0) }))
                    Toggle("Fill", isOn: Binding(get: { model.items[i].fill != nil }, set: { model.items[i].fill = $0 ? .systemBlue.withAlphaComponent(0.3) : nil }))
                    if item.fill != nil {
                        ColorPicker("Fill color", selection: Binding(get: { Color(nsColor: model.items[i].fill ?? .clear) }, set: { model.items[i].fill = NSColor($0) }), supportsOpacity: true)
                    }
                    Stepper("Border \(Int(item.lineWidth)) pt", value: binding(i, \.lineWidth), in: 0...30)
                    opacity(i)
                case .line, .ink:
                    ColorPicker("Color", selection: Binding(get: { Color(nsColor: model.items[i].color) }, set: { model.items[i].color = NSColor($0) }))
                    Stepper("Width \(Int(item.lineWidth)) pt", value: binding(i, \.lineWidth), in: 1...40)
                    opacity(i)
                case .highlight:
                    ColorPicker("Color", selection: Binding(get: { Color(nsColor: model.items[i].fill ?? .yellow) }, set: { model.items[i].fill = NSColor($0) }))
                case .whiteout, .redact:
                    Text(item.kind == .redact ? "Content under this box is permanently removed when you save." : "Covers content with white.")
                        .font(.caption).foregroundStyle(.secondary)
                case .field(let f):
                    TextField("Field name", text: binding(i, \.name)).textFieldStyle(.roundedBorder)
                    if f == .dropdown || f == .list {
                        Text("Options (one per line)").font(.caption)
                        TextEditor(text: Binding(get: { model.items[i].choices.joined(separator: "\n") },
                                                 set: { model.items[i].choices = $0.components(separatedBy: "\n") }))
                            .frame(height: 80).border(Color.secondary.opacity(0.3))
                    }
                    if f == .text || f == .multiline || f == .dropdown {
                        Stepper("Font size \(Int(item.fontSize))", value: binding(i, \.fontSize), in: 0...36)
                        Text("Font size 0 = auto").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button { model.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        .keyboardShortcut("d", modifiers: .command)
                    Spacer()
                    Button(role: .destructive) { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                }
                if model.pageCount > 1 {
                    Button { copyToAllPages(item) } label: { Label("Copy to all pages", systemImage: "square.stack") }
                }
            } else {
                Text("New items").font(.headline)
                ColorPicker("Color", selection: Binding(get: { Color(nsColor: model.color) }, set: { model.color = NSColor($0) }))
                FontPicker(fontName: $model.fontName)
                Stepper("Text size \(Int(model.fontSize))", value: $model.fontSize, in: 4...200)
                Stepper("Line width \(Int(model.lineWidth))", value: $model.lineWidth, in: 1...30)
                Text("Pick a tool, then click or drag on the page. Select an item to move it, or drag its corner to resize.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if focusText { textFocused = true } }
    }

    private func title(_ k: ItemKind) -> String {
        switch k {
        case .text: return "Text"
        case .image: return "Image"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .ink: return "Drawing"
        case .highlight: return "Highlight"
        case .whiteout: return "Whiteout"
        case .redact: return "Redaction"
        case .field(let f): return f.rawValue
        }
    }

    private func opacity(_ i: Int) -> some View {
        HStack { Text("Opacity"); Slider(value: binding(i, \.opacity), in: 0.1...1) }
    }

    private func binding<T>(_ i: Int, _ kp: WritableKeyPath<CanvasItem, T>, refit: Bool = false) -> Binding<T> {
        let id = model.items[i].id
        return Binding(get: {
            model.items.first { $0.id == id }?[keyPath: kp] ?? model.items[min(i, model.items.count - 1)][keyPath: kp]
        }, set: { v in
            model.update(id) { item in
                item[keyPath: kp] = v
                if refit && item.kind == .text { model.fitText(&item) }
            }
        })
    }

    private func copyToAllPages(_ item: CanvasItem) {
        for p in 0..<model.pageCount where p != item.page {
            var c = item
            c.id = UUID()
            c.page = p
            model.items.append(c)
        }
    }
}

/// Standard editor layout: thumbnails | toolbar + canvas | inspector.
struct CanvasEditor<Extra: View, Side: View>: View {
    @ObservedObject var model: CanvasModel
    let tools: [EditorTool]
    @ViewBuilder var toolbarExtra: Extra
    @ViewBuilder var sidebarExtra: Side
    @Local private var editingText: UUID?

    var body: some View {
        HStack(spacing: 0) {
            PageThumbnails(model: model)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    ToolPalette(model: model, tools: tools)
                    toolbarExtra
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                PageCanvasView(model: model, tools: tools, onDoubleClickText: { id in model.selection = id; editingText = id })
                Divider()
                EditorStatusBar(model: model)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sidebarExtra
                    ItemInspector(model: model, focusText: editingText != nil && editingText == model.selection)
                        .id(model.selection)
                }
                .padding(14)
            }
            .frame(width: 248)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

// MARK: - Editor host (file loading, unlocking, saving)

struct EditorHost<Editor: View>: View {
    let tool: Tool
    let actionTitle: String
    @ViewBuilder var editor: (CanvasModel) -> Editor
    let makeJob: (CanvasModel) -> Job?

    @Local private var model: CanvasModel?
    @Local private var lockedURL: URL?
    @Local private var password = ""
    @StateObject private var runner = Runner()

    var body: some View {
        Group {
            if let model {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ToolIcon(tool: tool, size: 28)
                        Text(tool.title).font(.title3.bold())
                        Text(model.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Close File") { self.model = nil; runner.reset() }
                        Button { if let job = makeJob(model) { runner.run(job, source: model.url, label: tool.title) } } label: {
                            Label(actionTitle, systemImage: "square.and.arrow.down.fill").padding(.horizontal, 8)
                        }
                        .buttonStyle(.borderedProminent).disabled(runner.isRunning)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider()
                    editor(model)
                }
                .overlay(alignment: .bottom) {
                    if runner.isRunning {
                        HStack { ProgressView().controlSize(.small); Text(runner.status) }
                            .padding(10).background(.regularMaterial, in: Capsule()).padding()
                    }
                }
                .sheet(isPresented: Binding(get: { runner.result != nil || runner.error != nil }, set: { if !$0 { runner.reset() } })) {
                    VStack(alignment: .leading) {
                        ResultPanel(runner: runner)
                        HStack { Spacer(); Button("Done") { runner.reset() }.keyboardShortcut(.defaultAction) }
                    }
                    .padding(20).frame(width: 520)
                }
            } else {
                ToolPage(tool: tool) {
                    if let lockedURL {
                        OptionsBox(title: "“\(lockedURL.lastPathComponent)” is password protected") {
                            HStack {
                                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(maxWidth: 280).onSubmit(unlock)
                                Button("Open", action: unlock).buttonStyle(.borderedProminent)
                                Button("Cancel") { self.lockedURL = nil }
                            }
                        }
                    } else {
                        DropZone(types: [.pdf], multiple: false, prompt: "Select a PDF file") { load($0[0]) }
                    }
                    if let e = runner.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                .onAppear { if let f = FileInbox.shared.take([.pdf]).first { load(f) } }
            }
        }
    }

    private func load(_ url: URL) {
        guard let doc = PDFDocument(url: url) else { runner.error = ToolError.open(url.lastPathComponent).localizedDescription; return }
        if doc.isLocked { lockedURL = url; return }
        runner.error = nil
        model = CanvasModel(doc: doc, url: url)
    }

    private func unlock() {
        guard let url = lockedURL, let doc = PDFDocument(url: url) else { return }
        if doc.unlock(withPassword: password) {
            model = CanvasModel(doc: doc, url: url)
            lockedURL = nil
            password = ""
            runner.error = nil
        } else {
            runner.error = "Incorrect password."
        }
    }
}
