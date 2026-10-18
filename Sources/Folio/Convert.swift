import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Images ⇄ PDF

enum ImageConvert {
    enum PageSize: String, CaseIterable, Identifiable {
        case fit = "Fit image", a4 = "A4", letter = "US Letter"
        var id: String { rawValue }
        var size: CGSize? { switch self { case .fit: return nil; case .a4: return CGSize(width: 595, height: 842); case .letter: return CGSize(width: 612, height: 792) } }
    }
    enum Orientation: String, CaseIterable, Identifiable { case auto = "Auto", portrait = "Portrait", landscape = "Landscape"; var id: String { rawValue } }
    enum Margin: String, CaseIterable, Identifiable {
        case none = "No margin", small = "Small", big = "Big"
        var id: String { rawValue }
        var points: CGFloat { switch self { case .none: return 0; case .small: return 20; case .big: return 50 } }
    }

    /// Loads all frames of an image file, applying EXIF orientation.
    static func loadImages(_ url: URL) -> [CGImage] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        var out: [CGImage] = []
        for i in 0..<CGImageSourceGetCount(src) {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            if orientation == 1, let img = CGImageSourceCreateImageAtIndex(src, i, nil) { out.append(img); continue }
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 4000, h = props[kCGImagePropertyPixelHeight] as? Int ?? 4000
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) { out.append(img) }
        }
        return out
    }

    static func imagesToPDF(_ urls: [URL], pageSize: PageSize, orientation: Orientation, margin: Margin,
                            merge: Bool, out dir: URL) throws -> ToolResult {
        var files: [URL] = []
        var ctx: CGContext?
        func newContext(_ name: String) throws -> CGContext {
            let dest = Workspace.uniqueURL(in: dir, name: name, ext: "pdf")
            guard let c = CGContext(dest as CFURL, mediaBox: nil, [kCGPDFContextCreator: "Folio"] as CFDictionary) else {
                throw ToolError.message("Couldn’t create PDF.")
            }
            files.append(dest)
            return c
        }
        if merge { ctx = try newContext(urls.count == 1 ? urls[0].baseName : "images") }
        var pages = 0
        for url in urls {
            let images = loadImages(url)
            if images.isEmpty { throw ToolError.message("Couldn’t read image “\(url.lastPathComponent)”.") }
            if !merge { ctx = try newContext(url.baseName) }
            for img in images {
                let iw = CGFloat(img.width), ih = CGFloat(img.height)
                var page: CGSize
                if let s = pageSize.size {
                    let landscape = orientation == .landscape || (orientation == .auto && iw > ih)
                    page = landscape ? CGSize(width: s.height, height: s.width) : s
                } else {
                    // Fit: image size at 72 dpi, capped to a sensible physical size.
                    let scale = min(1, 1190 / max(iw, ih))
                    page = CGSize(width: iw * scale + margin.points * 2, height: ih * scale + margin.points * 2)
                }
                var box = CGRect(origin: .zero, size: page)
                ctx!.beginPage(mediaBox: &box)
                let area = box.insetBy(dx: margin.points, dy: margin.points)
                let s = min(area.width / iw, area.height / ih)
                let r = CGRect(x: area.midX - iw * s / 2, y: area.midY - ih * s / 2, width: iw * s, height: ih * s)
                ctx!.interpolationQuality = .high
                ctx!.draw(img, in: r)
                ctx!.endPage()
                pages += 1
            }
            if !merge { ctx!.closePDF() }
        }
        if merge { ctx?.closePDF() }
        return ToolResult(files: files, message: "Created \(files.count) PDF\(files.count == 1 ? "" : "s") with \(pages) page\(pages == 1 ? "" : "s").")
    }

    enum ImageFormat: String, CaseIterable, Identifiable {
        case jpg = "JPG", png = "PNG", tiff = "TIFF"
        var id: String { rawValue }
        var ext: String { switch self { case .jpg: return "jpg"; case .png: return "png"; case .tiff: return "tiff" } }
        var uti: UTType { switch self { case .jpg: return .jpeg; case .png: return .png; case .tiff: return .tiff } }
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ToolError.message("Couldn’t write \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw ToolError.message("Couldn’t write \(url.lastPathComponent).") }
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func pdfToImages(_ urls: [URL], format: ImageFormat, dpi: CGFloat, quality: Double,
                            out dir: URL, progress: JobProgress) throws -> ToolResult {
        var files: [URL] = []
        for url in urls {
            let doc = try PDFCore.open(url)
            let pad = String(doc.pageCount).count
            for i in 0..<doc.pageCount {
                progress.update("Rendering \(url.lastPathComponent) page \(i + 1)/\(doc.pageCount)…", Double(i) / Double(doc.pageCount))
                guard let page = doc.page(at: i), let img = PDFCore.image(of: page, scale: dpi / 72, maxPixels: 12000) else { continue }
                let n = String(i + 1).leftPad(pad)
                let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_page-\(n)", ext: format.ext)
                try write(img, to: dest, type: format.uti, quality: quality)
                files.append(dest)
            }
        }
        return ToolResult(files: files, message: "Converted \(files.count) page\(files.count == 1 ? "" : "s").")
    }

    /// Extracts the image XObjects embedded in the PDFs (JPEG and JPEG 2000 are copied byte for byte).
    static func extractImages(_ urls: [URL], out dir: URL) throws -> ToolResult {
        var files: [URL] = []
        for url in urls {
            guard let doc = CGPDFDocument(url as CFURL) else { throw ToolError.open(url.lastPathComponent) }
            if doc.isEncrypted && !doc.isUnlocked && !doc.unlockWithPassword("") { throw ToolError.locked(url.lastPathComponent) }
            var seen = Set<Int>()
            var count = 0
            func walk(_ resources: CGPDFDictionaryRef) {
                var xobjects: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
                CGPDFDictionaryApplyBlock(xobjects, { _, value, _ in
                    var stream: CGPDFStreamRef?
                    guard CGPDFObjectGetValue(value, .stream, &stream), let stream else { return true }
                    let key = Int(bitPattern: stream.rawValue)
                    guard seen.insert(key).inserted else { return true }
                    guard let dict = CGPDFStreamGetDictionary(stream) else { return true }
                    var subtype: UnsafePointer<CChar>?
                    CGPDFDictionaryGetName(dict, "Subtype", &subtype)
                    let kind = subtype.map { String(cString: $0) } ?? ""
                    if kind == "Form" {
                        var inner: CGPDFDictionaryRef?
                        if CGPDFDictionaryGetDictionary(dict, "Resources", &inner), let inner { walk(inner) }
                    } else if kind == "Image" {
                        count += 1
                        if let file = saveImage(stream, dict, name: "\(url.baseName)_image-\(String(count).leftPad(3))", dir: dir) { files.append(file) }
                    }
                    return true
                }, nil)
            }
            for p in 1...max(doc.numberOfPages, 1) {
                guard let page = doc.page(at: p), let pd = page.dictionary else { continue }
                var res: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(pd, "Resources", &res), let res { walk(res) }
            }
        }
        if files.isEmpty { throw ToolError.message("No embedded images were found. Try “Page to JPG” instead.") }
        return ToolResult(files: files, message: "Extracted \(files.count) image\(files.count == 1 ? "" : "s").")
    }

    private static func saveImage(_ stream: CGPDFStreamRef, _ dict: CGPDFDictionaryRef, name: String, dir: URL) -> URL? {
        var format = CGPDFDataFormat.raw
        guard let cf = CGPDFStreamCopyData(stream, &format) else { return nil }
        let data = cf as Data
        var w = 0, h = 0, bpc = 8
        CGPDFDictionaryGetInteger(dict, "Width", &w)
        CGPDFDictionaryGetInteger(dict, "Height", &h)
        CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc)
        guard w >= 8, h >= 8 else { return nil }
        switch format {
        case .jpegEncoded:
            let dest = Workspace.uniqueURL(in: dir, name: name, ext: "jpg")
            return (try? data.write(to: dest)) != nil ? dest : nil
        case .JPEG2000:
            let dest = Workspace.uniqueURL(in: dir, name: name, ext: "jp2")
            return (try? data.write(to: dest)) != nil ? dest : nil
        default:
            let pixels = w * h
            let comps: Int
            if (bpc == 8 || bpc == 16) && pixels > 0 { comps = data.count / (pixels * bpc / 8) } else if bpc == 1 { comps = 1 } else { return nil }
            let space: CGColorSpace
            switch comps {
            case 1: space = CGColorSpaceCreateDeviceGray()
            case 3: space = CGColorSpace(name: CGColorSpace.sRGB)!
            case 4: space = CGColorSpaceCreateDeviceCMYK()
            default: return nil
            }
            let bytesPerRow = bpc == 1 ? (w + 7) / 8 : w * comps * bpc / 8
            // PDF stores 16-bit samples big-endian.
            let info = CGImageAlphaInfo.none.rawValue | (bpc == 16 ? CGImageByteOrderInfo.order16Big.rawValue : 0)
            guard data.count >= bytesPerRow * h, let provider = CGDataProvider(data: data as CFData),
                  let img = CGImage(width: w, height: h, bitsPerComponent: bpc, bitsPerPixel: bpc * comps, bytesPerRow: bytesPerRow,
                                    space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { return nil }
            let dest = Workspace.uniqueURL(in: dir, name: name, ext: "png")
            return (try? write(img, to: dest, type: .png)) != nil ? dest : nil
        }
    }
}

extension String {
    func leftPad(_ n: Int, with c: Character = "0") -> String { count >= n ? self : String(repeating: c, count: n - count) + self }
}

// MARK: - Office → PDF

enum OfficeConvert {
    enum Kind { case word, powerpoint, excel }

    static let pagesID = "com.apple.Pages", keynoteID = "com.apple.Keynote", numbersID = "com.apple.Numbers"

    static func appInstalled(_ id: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }

    static func convert(_ url: URL, kind: Kind, useIWork: Bool, out dir: URL) async throws -> URL {
        let dest = Workspace.uniqueURL(in: dir, name: url.baseName, ext: "pdf")
        let ext = url.pathExtension.lowercased()
        switch kind {
        case .word:
            if useIWork && appInstalled(pagesID) { try iWorkExport(appID: pagesID, input: url, output: dest) }
            else { try await textDocumentToPDF(url, out: dest) }
        case .powerpoint:
            if useIWork && appInstalled(keynoteID) { try iWorkExport(appID: keynoteID, input: url, output: dest) }
            else if ext == "pptx" { try await WebPDF.render(html: try OOXMLReader.pptxToHTML(url), baseURL: nil, out: dest, landscape: true) }
            else { throw ToolError.message("Converting .\(ext) needs Keynote. Install Keynote or use a .pptx file.") }
        case .excel:
            if useIWork && appInstalled(numbersID) { try iWorkExport(appID: numbersID, input: url, output: dest) }
            else if ext == "xlsx" { try await WebPDF.render(html: try OOXMLReader.xlsxToHTML(url), baseURL: nil, out: dest, landscape: true) }
            else if ext == "csv" { try await WebPDF.render(html: OOXMLReader.csvToHTML(url), baseURL: nil, out: dest, landscape: true) }
            else { throw ToolError.message("Converting .\(ext) needs Numbers. Install Numbers or use .xlsx/.csv.") }
        }
        guard PDFDocument(url: dest) != nil else { throw ToolError.message("Conversion of “\(url.lastPathComponent)” failed.") }
        return dest
    }

    /// Lays out a rich text document (DOCX, DOC, RTF, ODT, TXT, HTML) into paginated PDF using TextKit.
    static func textDocumentToPDF(_ url: URL, out: URL) async throws {
        let (text, attrs): (NSAttributedString, [NSAttributedString.DocumentAttributeKey: Any]) = try await MainActor.run {
            var a: NSDictionary? = nil
            let s = try NSAttributedString(url: url, options: [:], documentAttributes: &a)
            return (s, a as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:])
        }
        let paper = (attrs[.paperSize] as? NSValue)?.sizeValue ?? CGSize(width: 612, height: 792)
        let pageSize = paper.width > 100 && paper.height > 100 ? paper : CGSize(width: 612, height: 792)
        func margin(_ k: NSAttributedString.DocumentAttributeKey) -> CGFloat { (attrs[k] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 72 }
        try paginate(text, pageSize: pageSize, margins: NSEdgeInsets(top: margin(.topMargin), left: margin(.leftMargin),
                                                                     bottom: margin(.bottomMargin), right: margin(.rightMargin)), out: out)
    }

    static func paginate(_ text: NSAttributedString, pageSize: CGSize, margins: NSEdgeInsets, out: URL) throws {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let textSize = CGSize(width: pageSize.width - margins.left - margins.right, height: pageSize.height - margins.top - margins.bottom)
        var containers: [NSTextContainer] = []
        while containers.count < 5000 {
            let tc = NSTextContainer(size: textSize)
            tc.lineFragmentPadding = 0
            layout.addTextContainer(tc)
            containers.append(tc)
            let range = layout.glyphRange(for: tc)
            if range.length == 0 && layout.numberOfGlyphs > 0 { break }
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
        }
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, [kCGPDFContextCreator: "Folio"] as CFDictionary) else {
            throw ToolError.message("Couldn’t create PDF.")
        }
        for tc in containers {
            var box = CGRect(origin: .zero, size: pageSize)
            ctx.beginPage(mediaBox: &box)
            PDFCore.topLeft(ctx, pageSize) {
                let range = layout.glyphRange(for: tc)
                let origin = CGPoint(x: margins.left, y: margins.top)
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
            }
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// Opens the document in Pages/Keynote/Numbers and exports it as PDF via Apple Events.
    static func iWorkExport(appID: String, input: URL, output: URL) throws {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = """
        set inFile to POSIX file "\(esc(input.path))"
        set outFile to POSIX file "\(esc(output.path))"
        tell application id "\(appID)"
            set theDoc to open inFile
            export theDoc to outFile as PDF
            close theDoc saving no
        end tell
        """
        let (status, err) = Shell.run("/usr/bin/osascript", ["-e", script])
        if status != 0 {
            if err.contains("-1743") || err.contains("Not authorized") {
                throw ToolError.message("Folio isn’t allowed to control that app. Enable it in System Settings › Privacy & Security › Automation.")
            }
            throw ToolError.message("Export failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String], cwd: URL? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: err, as: UTF8.self))
    }
}

// MARK: - HTML → PDF

@MainActor
final class WebPDF: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private let webView: WKWebView
    private let window: NSWindow
    private var printDone: CheckedContinuation<Bool, Never>?

    private init(width: CGFloat) {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1200), configuration: config)
        window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: width, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    enum Paper: String, CaseIterable, Identifiable {
        case a4 = "A4", letter = "US Letter"
        var id: String { rawValue }
        var size: CGSize { self == .a4 ? CGSize(width: 595, height: 842) : CGSize(width: 612, height: 792) }
    }

    static func render(url: URL? = nil, html: String? = nil, baseURL: URL?, out: URL, paper: Paper = .a4,
                       landscape: Bool = false, margin: CGFloat = 36, screenWidth: CGFloat = 1280) async throws {
        let r = WebPDF(width: screenWidth)
        try await r.load(url: url, html: html, baseURL: baseURL)
        try await r.print(to: out, paper: landscape ? CGSize(width: paper.size.height, height: paper.size.width) : paper.size, margin: margin)
    }

    private func load(url: URL?, html: String?, baseURL: URL?) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            if let url {
                if url.isFileURL { webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
                else { webView.load(URLRequest(url: url, timeoutInterval: 45)) }
            } else { webView.loadHTMLString(html ?? "", baseURL: baseURL) }
        }
        try await Task.sleep(for: .milliseconds(800)) // let late scripts and web fonts settle
    }

    private func print(to out: URL, paper: CGSize, margin: CGFloat) async throws {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: out])
        info.jobDisposition = .save
        info.paperSize = paper
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = webView.bounds
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            printDone = c
            op.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        if !ok || PDFDocument(url: out)?.pageCount ?? 0 == 0 { try await fallbackPDF(to: out, paper: paper) }
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printDone?.resume(returning: success)
        printDone = nil
    }

    /// Fallback: snapshot the whole page as one tall PDF and slice it into paper-sized pages.
    private func fallbackPDF(to out: URL, paper: CGSize) async throws {
        let data = try await webView.pdf()
        guard let src = PDFDocument(data: data), let page = src.page(at: 0) else { throw ToolError.message("The page couldn’t be rendered.") }
        let full = page.bounds(for: .mediaBox)
        let scale = paper.width / full.width
        let sliceH = paper.height / scale
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw ToolError.message("Couldn’t create PDF.") }
        var top = full.maxY
        while top > full.minY {
            var box = CGRect(origin: .zero, size: paper)
            ctx.beginPage(mediaBox: &box)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -full.minX, y: -(top - sliceH))
            page.draw(with: .mediaBox, to: ctx)
            ctx.endPage()
            top -= sliceH
        }
        ctx.closePDF()
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.continuation?.resume(); self.continuation = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.continuation?.resume(throwing: error); self.continuation = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.continuation?.resume(throwing: error); self.continuation = nil }
    }
}

extension WKWebView {
    func pdf() async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            createPDF(configuration: WKPDFConfiguration()) { c.resume(with: $0) }
        }
    }
}

// MARK: - Reading OOXML without Office (fallback renderers)

enum OOXMLReader {
    static func unzip(_ url: URL) throws -> URL {
        let dir = try Workspace.newOutputDir()
        let (status, err) = Shell.run("/usr/bin/unzip", ["-qq", "-o", url.path, "-d", dir.path])
        if status > 1 { throw ToolError.message("Couldn’t read “\(url.lastPathComponent)”: \(err)") }
        return dir
    }

    static func xml(_ url: URL) -> XMLDocument? { try? XMLDocument(contentsOf: url, options: []) }

    /// All descendant elements with a given local name.
    static func elements(_ node: XMLNode, _ name: String) -> [XMLElement] {
        var out: [XMLElement] = []
        func walk(_ n: XMLNode) {
            if let e = n as? XMLElement, e.localName == name { out.append(e) }
            n.children?.forEach(walk)
        }
        walk(node)
        return out
    }

    /// Attribute by exact name; for "id" prefers the relationship id (r:id) over a plain id.
    static func attr(_ e: XMLElement, _ name: String) -> String? {
        let attrs = e.attributes ?? []
        if name == "id", let r = attrs.first(where: { $0.name?.hasSuffix(":id") == true }) { return r.stringValue }
        if name == "embed", let r = attrs.first(where: { $0.name?.hasSuffix(":embed") == true }) { return r.stringValue }
        return (attrs.first { $0.name == name } ?? attrs.first { $0.localName == name })?.stringValue
    }

    static func rels(_ url: URL) -> [String: String] {
        guard let doc = xml(url) else { return [:] }
        var map: [String: String] = [:]
        for r in elements(doc, "Relationship") { if let id = attr(r, "Id"), let t = attr(r, "Target") { map[id] = t } }
        return map
    }

    static let tableCSS = """
    <style>body{font-family:-apple-system,Helvetica;font-size:10pt;color:#111}h2{font-size:13pt;margin:18px 0 8px}
    table{border-collapse:collapse;margin-bottom:24px}td{border:1px solid #bbb;padding:3px 6px;white-space:nowrap;vertical-align:top}
    td.n{text-align:right}tr:nth-child(even) td{background:#f6f6f6}.sheet{page-break-after:always}</style>
    """

    static func xlsxToHTML(_ url: URL) throws -> String {
        let root = try unzip(url)
        var shared: [String] = []
        if let ss = xml(root.appendingPathComponent("xl/sharedStrings.xml")) {
            shared = elements(ss, "si").map { si in elements(si, "t").compactMap(\.stringValue).joined() }
        }
        let wbRels = rels(root.appendingPathComponent("xl/_rels/workbook.xml.rels"))
        guard let wb = xml(root.appendingPathComponent("xl/workbook.xml")) else { throw ToolError.message("Not a valid .xlsx file.") }
        var html = "<html><head><meta charset='utf-8'>\(tableCSS)</head><body>"
        for sheet in elements(wb, "sheet") {
            let name = attr(sheet, "name") ?? "Sheet"
            guard let rid = attr(sheet, "id"), let target = wbRels[rid] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let sx = xml(root.appendingPathComponent(path)) else { continue }
            var grid: [[String]] = []
            var numeric: Set<String> = []
            for row in elements(sx, "row") {
                var cells: [String] = []
                for c in elements(row, "c") {
                    let ref = attr(c, "r") ?? ""
                    let col = columnIndex(ref) ?? cells.count
                    while cells.count < col { cells.append("") }
                    let type = attr(c, "t")
                    var value = elements(c, "v").first?.stringValue ?? ""
                    if type == "s", let i = Int(value), i < shared.count { value = shared[i] }
                    else if type == "inlineStr" { value = elements(c, "t").compactMap(\.stringValue).joined() }
                    else if type == "b" { value = value == "1" ? "TRUE" : "FALSE" }
                    else if type == nil || type == "n", Double(value) != nil { numeric.insert("\(grid.count):\(cells.count)") }
                    cells.append(value)
                }
                grid.append(cells)
            }
            while let last = grid.last, last.allSatisfy({ $0.isEmpty }) { grid.removeLast() }
            html += "<div class='sheet'><h2>\(name.xmlEscaped)</h2><table>"
            for (r, row) in grid.enumerated() {
                html += "<tr>" + row.enumerated().map { c, v in "<td\(numeric.contains("\(r):\(c)") ? " class='n'" : "")>\(v.xmlEscaped)</td>" }.joined() + "</tr>"
            }
            html += "</table></div>"
        }
        try? FileManager.default.removeItem(at: root)
        return html + "</body></html>"
    }

    static func csvToHTML(_ url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        var html = "<html><head><meta charset='utf-8'>\(tableCSS)</head><body><table>"
        for row in CSV.parse(text) { html += "<tr>" + row.map { "<td>\($0.xmlEscaped)</td>" }.joined() + "</tr>" }
        return html + "</table></body></html>"
    }

    static func columnIndex(_ ref: String) -> Int? {
        var n = 0
        var any = false
        for ch in ref.uppercased().unicodeScalars {
            guard ch.value >= 65 && ch.value <= 90 else { break }
            n = n * 26 + Int(ch.value - 64)
            any = true
        }
        return any ? n - 1 : nil
    }

    static func pptxToHTML(_ url: URL) throws -> String {
        let root = try unzip(url)
        guard let pres = xml(root.appendingPathComponent("ppt/presentation.xml")) else { throw ToolError.message("Not a valid .pptx file.") }
        let presRels = rels(root.appendingPathComponent("ppt/_rels/presentation.xml.rels"))
        var html = """
        <html><head><meta charset='utf-8'><style>body{margin:0;font-family:-apple-system,Helvetica}
        .slide{page-break-after:always;padding:40px 56px;min-height:420px}.slide h1{font-size:26pt;margin:0 0 18px}
        .slide p{font-size:15pt;margin:6px 0}.slide img{max-width:46%;max-height:300px;margin:8px}</style></head><body>
        """
        for sid in elements(pres, "sldId") {
            guard let rid = attr(sid, "id"), let target = presRels[rid] else { continue }
            let slideURL = root.appendingPathComponent("ppt").appendingPathComponent(target).standardizedFileURL
            guard let slide = xml(slideURL) else { continue }
            let slideRels = rels(slideURL.deletingLastPathComponent().appendingPathComponent("_rels/\(slideURL.lastPathComponent).rels"))
            html += "<div class='slide'>"
            var first = true
            for para in elements(slide, "p") where para.localName == "p" && para.uri?.contains("drawingml") == true {
                let text = elements(para, "t").compactMap(\.stringValue).joined()
                if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                html += first ? "<h1>\(text.xmlEscaped)</h1>" : "<p>\(text.xmlEscaped)</p>"
                first = false
            }
            for blip in elements(slide, "blip") {
                guard let embed = attr(blip, "embed"), let t = slideRels[embed] else { continue }
                let img = slideURL.deletingLastPathComponent().appendingPathComponent(t).standardizedFileURL
                if let data = try? Data(contentsOf: img) {
                    let mime = img.pathExtension.lowercased() == "png" ? "png" : "jpeg"
                    html += "<img src='data:image/\(mime);base64,\(data.base64EncodedString())'>"
                }
            }
            html += "</div>"
        }
        try? FileManager.default.removeItem(at: root)
        return html + "</body></html>"
    }
}

enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? it.next() {
            pending = nil
            if quoted {
                if ch == "\"" { if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false } }
                else { field.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == "," { row.append(field); field = "" }
            else if ch == "\n" || ch == "\r\n" || ch == "\r" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(ch) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func write(_ rows: [[String]]) -> String {
        rows.map { $0.map { f in f.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"\(f.replacingOccurrences(of: "\"", with: "\"\""))\"" : f }.joined(separator: ",") }
            .joined(separator: "\n")
    }
}

// MARK: - PDF → text formats

enum TextExtract {
    /// Text for a page, OCR-ing it when it has no text layer.
    static func pageText(_ page: PDFPage, ocrIfEmpty: Bool) -> String {
        let s = page.string ?? ""
        if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ocrIfEmpty { return s }
        guard let img = PDFCore.image(of: page, scale: 2.5) else { return "" }
        return ((try? OCR.recognize(img)) ?? []).sorted { $0.box.maxY > $1.box.maxY }.map(\.text).joined(separator: "\n")
    }

    /// Joins hard-wrapped lines back into paragraphs.
    static func reflow(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out = ""
        for (i, line) in lines.enumerated() {
            out += line
            guard i < lines.count - 1 else { break }
            let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let joins = !trimmed.isEmpty && !next.isEmpty && !".:;!?".contains(trimmed.last!) && next.first!.isLowercase
            out += joins ? (trimmed.hasSuffix("-") ? "" : " ") : "\n"
        }
        return out
    }

    enum WordFormat: String, CaseIterable, Identifiable {
        case docx = "Word (.docx)", doc = "Word 97 (.doc)", rtf = "Rich Text (.rtf)", odt = "OpenDocument (.odt)", txt = "Plain text (.txt)"
        var id: String { rawValue }
        var ext: String { ["docx", "doc", "rtf", "odt", "txt"][Self.allCases.firstIndex(of: self)!] }
        var type: NSAttributedString.DocumentType {
            switch self { case .docx: return .officeOpenXML; case .doc: return .docFormat; case .rtf: return .rtf; case .odt: return .openDocument; case .txt: return .plain }
        }
    }

    static func pdfToWord(_ urls: [URL], format: WordFormat, ocr: Bool, reflowText: Bool, out dir: URL, progress: JobProgress) throws -> ToolResult {
        var files: [URL] = []
        for url in urls {
            let doc = try PDFCore.open(url)
            let result = NSMutableAttributedString()
            for i in 0..<doc.pageCount {
                progress.update("Converting \(url.lastPathComponent) page \(i + 1)/\(doc.pageCount)…", Double(i) / Double(doc.pageCount))
                guard let page = doc.page(at: i) else { continue }
                var part: NSAttributedString
                if let a = page.attributedString, a.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 { part = a }
                else { part = NSAttributedString(string: pageText(page, ocrIfEmpty: ocr), attributes: [.font: NSFont(name: "Helvetica", size: 12)!]) }
                if reflowText { part = reflowAttributed(part) }
                result.append(part)
                if i < doc.pageCount - 1 { result.append(NSAttributedString(string: "\n\u{0C}")) }
            }
            let dest = Workspace.uniqueURL(in: dir, name: url.baseName, ext: format.ext)
            let data = try result.data(from: NSRange(location: 0, length: result.length), documentAttributes: [.documentType: format.type])
            try data.write(to: dest)
            files.append(dest)
        }
        return ToolResult(files: files)
    }

    static func reflowAttributed(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        let ns = m.string as NSString
        var replace: [NSRange] = []
        for i in 0..<ns.length where ns.character(at: i) == 10 {
            guard i > 0, i + 1 < ns.length else { continue }
            let prev = Character(UnicodeScalar(ns.character(at: i - 1)) ?? " ")
            let next = Character(UnicodeScalar(ns.character(at: i + 1)) ?? " ")
            if !".:;!?\n ".contains(prev) && next.isLowercase { replace.append(NSRange(location: i, length: 1)) }
        }
        for r in replace.reversed() { m.replaceCharacters(in: r, with: " ") }
        return m
    }

    // MARK: Markdown

    static func pdfToMarkdown(_ url: URL, ocr: Bool) throws -> String {
        let doc = try PDFCore.open(url)
        struct Line { let text: String; let size: CGFloat; let bold: Bool; let top: CGFloat; let height: CGFloat }
        var pages: [[Line]] = []
        var sizes: [Int: Int] = [:]
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var lines: [Line] = []
            let selections = page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []
            for sel in selections {
                let text = (sel.string ?? "").trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                let font = sel.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                let size = (font?.pointSize ?? 12).rounded()
                let bold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
                let r = PDFCore.pageToUpright(sel.bounds(for: page), page: page)
                lines.append(Line(text: text, size: size, bold: bold, top: r.minY, height: r.height))
                sizes[Int(size), default: 0] += text.count
            }
            if lines.isEmpty, ocr {
                lines = pageText(page, ocrIfEmpty: true).components(separatedBy: "\n").enumerated()
                    .map { Line(text: $1, size: 12, bold: false, top: CGFloat($0) * 14, height: 12) }
            }
            pages.append(lines)
        }
        let body = CGFloat(sizes.max { $0.value < $1.value }?.key ?? 12)
        let headingSizes = Array(Set(pages.flatMap { $0 }.map(\.size).filter { $0 > body + 1 })).sorted(by: >)
        var md = ""
        var paragraph = ""
        func flush() { if !paragraph.isEmpty { md += paragraph + "\n\n"; paragraph = "" } }
        let bullet = try NSRegularExpression(pattern: "^[•●◦▪■–\\-*]\\s*")
        let numbered = try NSRegularExpression(pattern: "^\\(?\\d{1,3}[.)]\\s+")
        for (p, lines) in pages.enumerated() {
            var prevBottom: CGFloat?
            for line in lines {
                let t = line.text
                let range = NSRange(t.startIndex..., in: t)
                let gap = prevBottom.map { line.top - $0 } ?? 0
                prevBottom = line.top + line.height
                if line.size > body + 1, t.count < 120 {
                    flush()
                    let level = min((headingSizes.firstIndex(of: line.size) ?? 2) + 1, 4)
                    md += String(repeating: "#", count: level) + " " + t + "\n\n"
                } else if let m = bullet.firstMatch(in: t, range: range) {
                    flush(); md += "- " + (t as NSString).substring(from: m.range.upperBound) + "\n"
                } else if numbered.firstMatch(in: t, range: range) != nil {
                    flush(); md += t + "\n"
                } else if line.bold && t.count < 80 && paragraph.isEmpty {
                    md += "**\(t)**\n\n"
                } else {
                    if gap > line.height * 0.9 { flush() }
                    if paragraph.isEmpty { paragraph = t }
                    else if paragraph.hasSuffix("-") { paragraph = String(paragraph.dropLast()) + t }
                    else { paragraph += " " + t }
                }
            }
            flush()
            if p < pages.count - 1 { md += "---\n\n" }
        }
        return md
    }

    // MARK: Tables

    struct Cell { var x: CGFloat; var text: String }

    /// Reconstructs rows/cells from glyph positions on a page.
    static func tableRows(_ page: PDFPage) -> [[Cell]] {
        // characterBounds(at:) skips the synthetic line breaks in page.string, so take each
        // glyph's text and bounds from single-character selections, which share one index space.
        struct Glyph { let ch: String; let r: CGRect }
        var glyphs: [Glyph] = []
        for i in 0..<page.numberOfCharacters {
            guard let sel = page.selection(for: NSRange(location: i, length: 1)), let ch = sel.string,
                  !ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let r = PDFCore.pageToUpright(sel.bounds(for: page), page: page)
            if r.width <= 0 || r.height <= 0 { continue }
            glyphs.append(Glyph(ch: ch, r: r))
        }
        // Cluster into lines by vertical center.
        glyphs.sort { $0.r.midY < $1.r.midY }
        var lines: [[Glyph]] = []
        for g in glyphs {
            if let last = lines.last?.last, abs(last.r.midY - g.r.midY) < max(2, min(last.r.height, g.r.height) * 0.45) { lines[lines.count - 1].append(g) }
            else { lines.append([g]) }
        }
        return lines.map { line in
            let sorted = line.sorted { $0.r.minX < $1.r.minX }
            var cells: [Cell] = []
            var prev: Glyph?
            for g in sorted {
                if let p = prev {
                    let gap = g.r.minX - p.r.maxX
                    let h = max(p.r.height, g.r.height)
                    if gap > h * 1.1 { cells.append(Cell(x: g.r.minX, text: g.ch)) }
                    else { cells[cells.count - 1].text += (gap > h * 0.18 ? " " : "") + g.ch }
                } else { cells.append(Cell(x: g.r.minX, text: g.ch)) }
                prev = g
            }
            return cells
        }
    }

    /// Aligns cells into a grid by clustering their left edges into columns.
    static func grid(_ rows: [[Cell]]) -> [[String]] {
        let xs = rows.filter { $0.count > 1 }.flatMap { $0.map(\.x) }.sorted()
        var anchors: [CGFloat] = []
        for x in xs { if let a = anchors.last, x - a < 12 { continue }; anchors.append(x) }
        if anchors.isEmpty { return rows.map { [$0.map(\.text).joined(separator: " ")] } }
        return rows.map { row in
            var out = [String](repeating: "", count: anchors.count)
            for c in row {
                let idx = anchors.lastIndex { $0 <= c.x + 6 } ?? 0
                out[idx] = out[idx].isEmpty ? c.text : out[idx] + " " + c.text
            }
            while out.count > 1, out.last == "" { out.removeLast() }
            return out
        }
    }

    static func pdfToExcel(_ urls: [URL], oneSheet: Bool, csv: Bool, out dir: URL, progress: JobProgress) throws -> ToolResult {
        var files: [URL] = []
        for url in urls {
            let doc = try PDFCore.open(url)
            var sheets: [(String, [[String]])] = []
            for i in 0..<doc.pageCount {
                progress.update("Reading tables on page \(i + 1)/\(doc.pageCount)…", Double(i) / Double(doc.pageCount))
                guard let page = doc.page(at: i) else { continue }
                var rows = grid(tableRows(page))
                if rows.isEmpty, let img = PDFCore.image(of: page, scale: 2.5) {
                    // Scanned page: rebuild rows from OCR boxes.
                    let lines = (try? OCR.recognize(img)) ?? []
                    let size = PDFCore.uprightSize(page)
                    let cells = lines.map { (Cell(x: $0.box.minX * size.width, text: $0.text), (1 - $0.box.midY) * size.height, $0.box.height * size.height) }
                    var grouped: [[Cell]] = []
                    var lastY: CGFloat = -1000
                    for c in cells.sorted(by: { $0.1 < $1.1 }) {
                        if abs(c.1 - lastY) < c.2 * 0.5, !grouped.isEmpty { grouped[grouped.count - 1].append(c.0) } else { grouped.append([c.0]) }
                        lastY = c.1
                    }
                    rows = grid(grouped.map { $0.sorted { $0.x < $1.x } })
                }
                if oneSheet || csv {
                    if sheets.isEmpty { sheets.append(("Sheet1", [])) }
                    if !sheets[0].1.isEmpty { sheets[0].1.append([]) }
                    sheets[0].1 += rows
                } else { sheets.append(("Page \(i + 1)", rows)) }
            }
            if csv {
                let dest = Workspace.uniqueURL(in: dir, name: url.baseName, ext: "csv")
                try CSV.write(sheets.first?.1 ?? []).write(to: dest, atomically: true, encoding: .utf8)
                files.append(dest)
            } else {
                let dest = Workspace.uniqueURL(in: dir, name: url.baseName, ext: "xlsx")
                try OOXMLWriter.xlsx(sheets: sheets, to: dest)
                files.append(dest)
            }
        }
        return ToolResult(files: files)
    }
}

// MARK: - OOXML writers

enum OOXMLWriter {
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static func zip(_ root: URL, entries: [String], to dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        let (status, err) = Shell.run("/usr/bin/zip", ["-X", "-r", "-q", dest.path] + entries, cwd: root)
        if status != 0 { throw ToolError.message("Couldn’t package \(dest.lastPathComponent): \(err)") }
    }

    static func put(_ root: URL, _ path: String, _ content: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (header + content).write(to: url, atomically: true, encoding: .utf8)
    }

    static func columnName(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    static func xlsx(sheets input: [(String, [[String]])], to dest: URL) throws {
        let sheets = input.isEmpty ? [("Sheet1", [[String]]())] : input
        let root = try Workspace.newOutputDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        try put(root, "[Content_Types].xml", """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())\
        </Types>
        """)
        try put(root, "_rels/.rels", """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        var usedNames = Set<String>()
        let names: [String] = sheets.map { s in
            var n = String(s.0.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            if n.isEmpty { n = "Sheet" }
            var candidate = n, i = 2
            while usedNames.contains(candidate.lowercased()) { candidate = String(n.prefix(28)) + " \(i)"; i += 1 }
            usedNames.insert(candidate.lowercased())
            return candidate
        }
        try put(root, "xl/workbook.xml", """
        <workbook xmlns="\(ns)" xmlns:r="\(rel)"><sheets>\
        \(names.enumerated().map { "<sheet name=\"\($1.xmlEscaped)\" sheetId=\"\($0 + 1)\" r:id=\"rId\($0 + 1)\"/>" }.joined())\
        </sheets></workbook>
        """)
        try put(root, "xl/_rels/workbook.xml.rels", """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined())\
        <Relationship Id="rId\(sheets.count + 1)" Type="\(rel)/styles" Target="styles.xml"/></Relationships>
        """)
        try put(root, "xl/styles.xml", """
        <styleSheet xmlns="\(ns)"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>
        """)
        for (i, sheet) in sheets.enumerated() {
            var xml = "<worksheet xmlns=\"\(ns)\"><sheetData>"
            for (r, row) in sheet.1.enumerated() {
                xml += "<row r=\"\(r + 1)\">"
                for (c, v) in row.enumerated() where !v.isEmpty {
                    let ref = "\(columnName(c))\(r + 1)"
                    let numeric = v.replacingOccurrences(of: ",", with: "")
                    if let d = Double(numeric), numeric.count < 16, !numeric.hasPrefix("0") || numeric == "0" || numeric.hasPrefix("0."), d.isFinite {
                        xml += "<c r=\"\(ref)\"><v>\(numeric)</v></c>"
                    } else {
                        xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(v.xmlEscaped)</t></is></c>"
                    }
                }
                xml += "</row>"
            }
            try put(root, "xl/worksheets/sheet\(i + 1).xml", xml + "</sheetData></worksheet>")
        }
        try zip(root, entries: ["[Content_Types].xml", "_rels", "xl"], to: dest)
    }

    /// Builds a PPTX where every PDF page becomes a full-bleed slide image.
    static func pptx(_ doc: PDFDocument, to dest: URL, dpi: CGFloat, progress: JobProgress) throws {
        let root = try Workspace.newOutputDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
        let nsAttrs = "xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)\""
        let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
        let emu: CGFloat = 12700
        guard let first = doc.page(at: 0) else { throw ToolError.message("The PDF has no pages.") }
        let slide = PDFCore.uprightSize(first)
        let cx = Int(slide.width * emu), cy = Int(slide.height * emu)
        let n = doc.pageCount
        let emptyTree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"

        try put(root, "[Content_Types].xml", """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
        \((1...n).map { "<Override PartName=\"/ppt/slides/slide\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" }.joined())\
        </Types>
        """)
        try put(root, "_rels/.rels", "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"rId1\" Type=\"\(r)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
        try put(root, "ppt/presentation.xml", """
        <p:presentation \(nsAttrs)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
        <p:sldIdLst>\((1...n).map { "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0 + 2)\"/>" }.joined())</p:sldIdLst>\
        <p:sldSz cx="\(cx)" cy="\(cy)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """)
        try put(root, "ppt/_rels/presentation.xml.rels", """
        <Relationships xmlns="\(relNS)"><Relationship Id="rId1" Type="\(r)/slideMaster" Target="slideMasters/slideMaster1.xml"/>\
        <Relationship Id="rId2" Type="\(r)/theme" Target="theme/theme1.xml"/>\
        \((1...n).map { "<Relationship Id=\"rId\($0 + 2)\" Type=\"\(r)/slide\" Target=\"slides/slide\($0).xml\"/>" }.joined())</Relationships>
        """)
        try put(root, "ppt/slideMasters/slideMaster1.xml", """
        <p:sldMaster \(nsAttrs)><p:cSld><p:spTree>\(emptyTree)</p:spTree></p:cSld>\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
        """)
        try put(root, "ppt/slideMasters/_rels/slideMaster1.xml.rels", """
        <Relationships xmlns="\(relNS)"><Relationship Id="rId1" Type="\(r)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        <Relationship Id="rId2" Type="\(r)/theme" Target="../theme/theme1.xml"/></Relationships>
        """)
        try put(root, "ppt/slideLayouts/slideLayout1.xml", """
        <p:sldLayout \(nsAttrs) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\(emptyTree)</p:spTree></p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """)
        try put(root, "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
                "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"rId1\" Type=\"\(r)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>")
        try put(root, "ppt/theme/theme1.xml", theme(a))

        for i in 0..<n {
            progress.update("Creating slide \(i + 1) of \(n)…", Double(i) / Double(n))
            guard let page = doc.page(at: i), let img = PDFCore.image(of: page, scale: dpi / 72),
                  let jpg = ImageConvert.jpegData(img, quality: 0.88) else { continue }
            let mediaURL = root.appendingPathComponent("ppt/media/image\(i + 1).jpeg")
            try FileManager.default.createDirectory(at: mediaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpg.write(to: mediaURL)
            let size = PDFCore.uprightSize(page)
            let s = min(slide.width / size.width, slide.height / size.height)
            let w = size.width * s, h = size.height * s
            let x = Int((slide.width - w) / 2 * emu), y = Int((slide.height - h) / 2 * emu)
            try put(root, "ppt/slides/slide\(i + 1).xml", """
            <p:sld \(nsAttrs)><p:cSld><p:spTree>\(emptyTree)\
            <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(i + 1)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
            <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
            <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(Int(w * emu))" cy="\(Int(h * emu))"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>\
            </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """)
            try put(root, "ppt/slides/_rels/slide\(i + 1).xml.rels", """
            <Relationships xmlns="\(relNS)"><Relationship Id="rId1" Type="\(r)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
            <Relationship Id="rId2" Type="\(r)/image" Target="../media/image\(i + 1).jpeg"/></Relationships>
            """)
        }
        try zip(root, entries: ["[Content_Types].xml", "_rels", "ppt"], to: dest)
    }

    private static func theme(_ a: String) -> String {
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "1F497D"), ("lt2", "EEECE1"), ("accent1", "4F81BD"), ("accent2", "C0504D"),
                      ("accent3", "9BBB59"), ("accent4", "8064A2"), ("accent5", "4BACC6"), ("accent6", "F79646"), ("hlink", "0000FF"), ("folHlink", "800080")]
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>"
        return """
        <a:theme xmlns:a="\(a)" name="Office Theme"><a:themeElements>\
        <a:clrScheme name="Office">\(colors.map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined())</a:clrScheme>\
        <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
        <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
        <a:fmtScheme name="Office"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>\
        <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
        <a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
        """
    }
}
